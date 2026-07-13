# Design: Claude Code Hook Integration

## Problem

When Claude Code runs in auto-accept mode, it writes files directly to disk. The
MCP-based `openDiff` flow in claudecode.nvim is bypassed entirely — Neovim has no
awareness that anything happened until `fs_event` fires and the full
debounce/stability pipeline runs (~200ms+).

In manual-accept mode, claudecode.nvim handles everything via MCP (`openDiff` blocks
until user accepts). But in auto-accept mode, agentwatch's filesystem watcher is the
only thing keeping buffers in sync.

## Insight

Claude Code's **hook system** fires regardless of permission mode. `PostToolUse`
fires after every Edit/Write/MultiEdit, even when auto-accepted. Hooks receive
structured JSON on stdin with the tool name, file path, and content.

This means agentwatch can be **told exactly what to reload** instead of watching
the entire filesystem and filtering noise.

## Proposed Design

Add an optional Claude hook connection as a secondary event source. When active, it
becomes the primary reload trigger for Claude-initiated changes. The existing
fs_event watcher remains as a fallback for everything else.

```
agentwatch
├── event sources
│   ├── fs_event watcher (always active, fallback)
│   └── claude hooks (optional, primary when connected)
│
└── shared pipeline
    ├── reload buffer
    ├── notify LSP
    └── fire callbacks
```

### How it works

1. agentwatch registers PreToolUse/PostToolUse hooks in `.claude/settings.local.json`
   (similar to how claude-preview.nvim does it)
2. Hook shell scripts receive JSON on stdin with tool_name and file path
3. Scripts notify Neovim via `nvim --server $SOCKET --remote-send` (using Neovim's
   built-in RPC server)
4. agentwatch receives the file path and does a targeted buffer reload — no debounce,
   no stability check needed (the write is already complete when PostToolUse fires)

### What this eliminates (for Claude-initiated changes)

- Recursive directory watching and ignore pattern matching
- Debouncing rapid events
- Stability checks (mtime comparison after delay)
- Content comparison to avoid redundant reloads
- Self-write tracking to prevent loops

### What stays the same

- fs_event watcher still runs for non-Claude changes (other tools, manual edits,
  git operations, formatters, etc.)
- LSP notification path is shared
- Buffer reload logic is shared
- Pause/resume API still works
- All existing config options remain valid

### Hook scripts needed

Two shell scripts, installed alongside the plugin:

**PostToolUse hook** (the main one):
- Receives JSON on stdin: `{ "tool_name": "Edit", "tool_input": { "file_path": "..." } }`
- Extracts file path with `jq`
- Finds Neovim socket (scan known paths or use $NVIM_LISTEN_ADDRESS)
- Sends: `nvim --server $SOCKET --remote-send ":lua require('agentwatch').sync_buffer_by_path('$FILE')<CR>"`

**PreToolUse hook** (optional, for future use):
- Could be used to pause the watcher for the specific file being edited
- Could show a notification "Claude is editing foo.lua"
- Returns empty JSON (no permission override — let Claude's own settings handle that)

### Discovery: finding the Neovim socket

claude-preview.nvim's approach works well:
- Scan `/var/folders/` (macOS) or `/tmp/nvim.*/` (Linux) for socket files
- Validate with `kill -0` on the PID
- Prefer sockets whose Neovim instance has a matching cwd
- Alternatively: use `$NVIM_LISTEN_ADDRESS` if set

### Configuration

```lua
require("agentwatch").setup({
  claude = {
    enabled = false,       -- opt-in, don't assume Claude Code is present
    install_hooks = true,  -- auto-install hook entries in settings.local.json
    tools = { "Edit", "Write", "MultiEdit" },  -- which tools to watch
  },
})
```

### Open questions

1. **Hook installation**: Should agentwatch manage `.claude/settings.local.json`
   directly (like claude-preview does), or should the user configure hooks manually?
   Auto-install is better UX but touches another tool's config.

2. **Coexistence with claudecode.nvim**: When both plugins are active, claudecode.nvim
   handles diffs in manual mode, agentwatch handles reloads in auto-accept mode. Need
   to avoid double-reloading. Could check if claudecode.nvim is loaded and defer to it
   for files it's actively diffing.

3. **Bash tool**: Claude's Bash tool can also modify files (e.g., `sed`, `cat >`,
   subprocesses). PostToolUse fires for Bash too, but the JSON doesn't specify which
   files were modified. For Bash, fall back to fs_event watching.

4. **Multiple Neovim instances**: If multiple instances are open, the hook script needs
   to find the right one. Matching by cwd is the best heuristic.

## References

- claude-preview.nvim hook implementation: https://github.com/Cannon07/claude-preview.nvim
  - `bin/claude-preview-diff.sh` — PreToolUse hook receiving JSON stdin
  - `bin/nvim-socket.sh` — Neovim socket discovery
  - `bin/nvim-send.sh` — RPC via `nvim --server`
  - `lua/claude-preview/hooks.lua` — hook installation in settings.local.json

- Claude Code hooks documentation:
  - Hooks fire shell scripts on PreToolUse/PostToolUse
  - JSON on stdin with tool_name, tool_input, cwd
  - Return JSON can override permission decisions

- coder/claudecode.nvim MCP approach: https://github.com/coder/claudecode.nvim
  - WebSocket server inside Neovim (MCP over JSON-RPC 2.0)
  - `openDiff` tool blocks until user accepts/rejects
  - Works great for manual accept, bypassed in auto-accept
