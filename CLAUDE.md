# agentwatch.nvim

A Neovim plugin for synchronizing external file changes with buffers and LSP.

## Project Context

This plugin solves the problem of external tools (Claude Code, Aider, git,
formatters) modifying files while Neovim has them open.

**The Problem:**
- Neovim's built-in `workspace/didChangeWatchedFiles` is disabled on Linux
- Even when enabled, it only notifies LSP - doesn't reload buffers
- External tools writing files can conflict with Neovim's state
- File watchers can interfere with writes (reading mid-write, atime updates)

**Neovim's Built-in LSP File Watching (context):**
- Added in Neovim 0.9, enabled by default on macOS/Windows in 0.10+
- **Disabled on Linux by default** because:
  - inotify doesn't support recursive watching
  - libuv can't structure inotify handles efficiently for recursion
  - Fallback polling causes 30-40% CPU on large projects
  - See: https://github.com/neovim/neovim/issues/23291
- Can be manually enabled with `dynamicRegistration = true` but has performance issues
- Even when working: only notifies LSP, no buffer reload, no conflict detection

**This Plugin Provides:**
- Cross-platform file watching (vim.uv.fs_event)
- Buffer reloading with undo preservation
- LSP workspace notifications
- Conflict detection when buffer has unsaved changes
- Pause/resume API for external tool integration

## Architecture

```
agentwatch.nvim/
├── lua/
│   └── agentwatch/
│       ├── init.lua          -- Public API, setup(), state machine
│       ├── watcher.lua       -- Cross-platform file watching (vim.uv)
│       ├── buffer.lua        -- Buffer reload, undo preservation, conflict detection
│       ├── lsp.lua           -- LSP notifications (workspace/didChangeWatchedFiles)
│       ├── config.lua        -- Configuration schema and defaults
│       ├── health.lua        -- :checkhealth agentwatch
│       └── util.lua          -- Path utilities, logging
├── spec/
│   ├── helpers/
│   │   └── setup.lua         -- Minimal vim mock for pure function tests
│   ├── util_spec.lua         -- Tests for path utilities
│   ├── lsp_spec.lua          -- Tests for glob pattern conversion
│   └── config_spec.lua       -- Tests for gitignore matching
├── scripts/
│   ├── run_specs.lua         -- Busted-compatible spec runner (no busted needed)
│   └── functional_test.lua   -- End-to-end suite in headless nvim (both backends)
├── doc/
│   └── agentwatch.txt        -- Vim help documentation
└── README.md                 -- GitHub landing page
```

## Key Design Decisions

### 1. Stability Check (CRITICAL)
Don't read files mid-write. After fs_event fires, wait and verify mtime
hasn't changed before processing. This prevents:
- Reading partial/corrupted file content
- Interfering with external tool's write operations
- The bug where the old claudecode.nvim watcher broke Claude Code writes

```lua
-- Wait for file to be "stable" before processing
local function is_file_stable(filepath, callback)
  local stat1 = vim.uv.fs_stat(filepath)
  vim.defer_fn(function()
    local stat2 = vim.uv.fs_stat(filepath)
    -- File is stable if mtime unchanged after delay
    callback(stat1 and stat2 and
             stat1.mtime.sec == stat2.mtime.sec and
             stat1.mtime.nsec == stat2.mtime.nsec)
  end, 50)
end
```

### 2. Debouncing
Batch rapid changes (150ms default). External tools often write multiple
times in quick succession.

### 3. Conflict Handling
When buffer has unsaved changes AND file changes externally:
- Skip automatic reload
- Defer to Neovim's built-in W12 warning when user interacts with buffer
- Optionally show notification via `buffer.notify_on_conflict`

### 4. LSP Integration Modes
- `complement`: Notify clients that dynamically registered for file watching,
  alongside Neovim's built-in watcher (default). On macOS/Windows registered
  servers may get the same change twice (built-in + agentwatch) — harmless.
- `replace`: Record `workspace/didChangeWatchedFiles` registrations but do NOT
  forward them, so Neovim's built-in watcher never starts. Registered clients
  are notified by pattern match; unregistered ones by filetype heuristic.
- `off`: Don't send LSP notifications

Linux: Neovim advertises `didChangeWatchedFiles.dynamicRegistration = false`,
so servers never register. Users must advertise the capability themselves and
use `replace` (prevents Neovim's polling fallback). Documented in the help doc.

Note: `didChangeWatchedFiles` is a CLIENT capability — it never appears in
`server_capabilities`; the only signal a server wants file events is dynamic
registration.

### 5. Pause/Resume API
External tools can signal "I'm writing" to prevent interference:
```lua
require("agentwatch").pause()   -- Stop processing, queue events
require("agentwatch").resume()  -- Process queue with fresh state
```

pause() also disables buffer-local 'autoread' on watched buffers (restored by
resume). Without this, Vim's own checktime would reload unmodified buffers
mid-write — `FileChangedShell` is BYPASSED entirely when 'autoread' applies,
so an autocmd alone cannot intercept it.

## State Machine

Plugin-level state is just IDLE ⇄ PAUSED (events queue while paused, dedup on
resume). Debouncing and the stability check happen per-file inside watcher.lua
(one debounce timer per path, closed after firing); they are not a plugin-level
state.

A "changed" event whose file no longer exists at stability-check time is
reported as a deletion — never re-debounced (that used to loop forever).

## Implementation Phases

### Phase 1: Core Watcher ✓
- [x] watcher.lua with vim.uv.fs_event
- [x] Debouncing logic
- [x] Stability check
- [x] Ignore patterns
- [x] config.lua with defaults
- [x] Basic init.lua with setup()

### Phase 2: Buffer Management ✓
- [x] buffer.lua reload logic
- [x] Conflict detection (delegates to Neovim's W12 for modified buffers)
- [x] Undo preservation (edit! for current, nvim_buf_set_lines for non-current)
- [x] Cursor/view restoration
- [x] Content comparison to skip unnecessary reloads
- [x] Self-write detection (skip events triggered by Neovim's own saves)

### Phase 3: LSP Integration ✓
- [x] lsp.lua notification logic (workspace/didChangeWatchedFiles)
- [x] Capability tracking (client/registerCapability)
- [x] Integration mode switching (complement/replace/off)

### Phase 4: Polish ✓
- [x] Pause/resume API with queue deduplication
- [x] Windows testing (recursive backend; predates the 2026-07 rework)
- [x] Documentation (README, help doc, inline annotations)
- [x] Health check (:checkhealth agentwatch)
- [x] macOS testing (unit + functional suite, 2026-07)
- [x] Linux code path (walk backend) tested via forced-backend functional
      suite on macOS — NOT yet verified on a real Linux/inotify system
- [ ] Real Linux verification (earlier "WSL Ubuntu" testing predates the
      walk backend and only exercised root-level files)

## Technical Notes

### APIs to Use
- `vim.uv.fs_event` - File watching (NOT vim.loop, that's deprecated)
- `vim.uv.fs_stat` - File metadata (mtime)
- `vim.uv.new_timer` - Debounce timers
- `vim.api.nvim_buf_*` - Buffer operations
- `vim.lsp.get_clients()` - Get LSP clients
- `client:notify()` - Send LSP notification (method syntax, not `client.notify`)

### Buffer Reload
```lua
-- Current buffer: edit! preserves full undo tree
vim.cmd("edit!")

-- Non-current buffers: set_lines avoids visual disturbance
-- Trade-off: creates single "replace all" undo entry
local disk_lines = vim.fn.readfile(filepath)
vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, disk_lines)
vim.bo[bufnr].modified = false

-- Note: nvim_buf_set_lines triggers on_lines callback automatically,
-- so LSP servers are notified via textDocument/didChange without manual work
```

### LSP Notification Format
```lua
-- Workspace file change notification (for LSP servers)
client:notify("workspace/didChangeWatchedFiles", {
  changes = {
    { uri = vim.uri_from_fname(filepath), type = 2 }  -- 1=Created, 2=Changed, 3=Deleted
  }
})
```

### Platform Considerations
libuv's `fs_event` recursive flag is supported ONLY on macOS and Windows;
on Linux/BSD it is silently ignored (only the top-level directory would get
events). watcher.lua therefore has two backends, selected by
`watch.backend = "auto"`:

| Platform | Backend | Notes |
|----------|---------|-------|
| macOS | recursive (FSEvents) | Single handle per root |
| Windows | recursive (ReadDirectoryChangesW) | Single handle per root |
| Linux | walk (inotify, per-directory) | One handle per dir; ignored dirs never watched; may need max_user_watches increase |
| WSL | walk (inotify) | Cross-filesystem watching (/mnt/c) limited |

The walk backend adopts directories created at runtime (and reports files
written into them before the watcher attached), prunes watchers when
directories disappear, and caps handles at 4096. It can be forced on macOS
with `watch.backend = "walk"` — that is how scripts/functional_test.lua
tests the Linux code path without a Linux machine.

### Vim behavior gotchas (discovered empirically, cost real debugging time)
- `FileChangedShell` does NOT fire when 'autoread' applies (unmodified buffer
  + autoread on): Vim reloads directly and only fires `FileChangedShellPost`.
  An autocmd cannot intercept autoread — you must disable 'autoread' first.
- `:checktime` on an unmodified buffer whose content EQUALS the disk content
  silently adopts the new timestamp: no event, no W11, no reload. So syncing
  a background buffer via `nvim_buf_set_lines` without updating Vim's stored
  mtime is safe.
- `vim.bo[bufnr].autoread` returns nil (not the effective value) when no
  buffer-local value is set — 'autoread' is a global-local option. Read the
  local scope explicitly and fall back to `vim.go.autoread`.

## Coding Style

- Lua 5.1 compatible (Neovim's LuaJIT)
- Use `vim.uv` not `vim.loop` (deprecated alias)
- Prefer `vim.schedule()` for callbacks that touch vim state
- Use `pcall` for operations that might fail
- Add `---@param` and `---@return` annotations for public functions
- Test on Windows first (development environment)

## Testing

### Unit Tests
Pure function tests run outside Neovim (vim mock in `spec/helpers/setup.lua`):
```
luajit scripts/run_specs.lua   # no busted required (any Lua 5.1+ works)
busted                         # works too, if installed
```

### Functional Tests
End-to-end suite driving real fs events in a headless Neovim — covers both
backends (walk backend = Linux code path, forced on macOS), pause/resume vs
autoread, conflict handling, gitignore matching, :AgentwatchReload teardown,
LSP registration stripping, and the vanished-file case:
```
nvim --headless --clean -u NORC -l scripts/functional_test.lua
```
Exits non-zero on failure. Run from the repo root.

### Manual Testing
1. Edit plugin in one Neovim instance
2. Test in separate Neovim instance with plugin loaded
3. Use `:AgentwatchReload` command to reload after changes
4. Check `:messages` for errors
5. Use `:lua print(vim.inspect(require("agentwatch").status()))` for debugging

## Integration with claudecode.nvim

The plugins cooperate without tight coupling:

```lua
-- In user config or claudecode.nvim
vim.api.nvim_create_autocmd("User", {
  pattern = "ClaudeCodeEditStart",
  callback = function()
    pcall(function() require("agentwatch").pause() end)
  end,
})

vim.api.nvim_create_autocmd("User", {
  pattern = "ClaudeCodeEditEnd",
  callback = function()
    pcall(function() require("agentwatch").resume() end)
  end,
})
```

## Limitations

### .gitignore Support
The `use_gitignore` option (enabled by default) parses `.gitignore` in cwd,
with proper gitignore semantics: patterns match relative to the .gitignore
location, anchored (`/dist`) and directory-only (`build/`) patterns work,
component boundaries are respected (`config.lua` does not ignore
`myconfig.lua`), `**` globs and `[!...]` classes are supported.

Remaining gaps:
- Only root `.gitignore` is parsed (no nested `.gitignore` in subdirectories)
- Negation patterns (`!pattern`) are skipped (shown in health check)
- Multiple `/**/` segments in one pattern: only all-collapsed / all-expanded
  variants are generated
- Reloads on `DirChanged` and when `.gitignore` itself changes

### Recursive Watching
On macOS/Windows (`recursive` backend), events fire for ALL files in the
tree including ignored directories; filtering happens in the callback. On
Linux/BSD (`walk` backend), ignored directories are never watched at all, but
each directory costs an inotify watch descriptor (capped at 4096, warning in
health check when exceeded).

### Pause vs. modified buffers
While paused, a buffer with unsaved changes whose file changes on disk still
gets Vim's conflict prompt on the next checktime (same as vanilla Vim). Only
unmodified watched buffers are held back.
