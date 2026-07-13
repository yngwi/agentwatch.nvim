# agentwatch.nvim

> [!WARNING]
> **Retired / unmaintained.** On **macOS and Windows**, Neovim's built-in LSP
> file watching (`workspace/didChangeWatchedFiles`, enabled by default since
> 0.10) already keeps language servers in sync with on-disk changes to files
> you haven't opened — the main thing this plugin existed for. Paired with a
> few lines of config for buffer reloading, you don't need it there.
>
> **Replacement (macOS/Windows):** nothing for the LSP side. For reloading
> buffers changed on disk, one autocmd:
>
> ```lua
> vim.o.autoread = true -- already the default; set explicitly for clarity
> vim.api.nvim_create_autocmd(
>   { "FocusGained", "BufEnter", "TermLeave", "CursorHold", "CursorHoldI" },
>   {
>     group = vim.api.nvim_create_augroup("autoreload", { clear = true }),
>     callback = function()
>       if vim.o.buftype == "" then vim.cmd("silent! checktime") end
>     end,
>   }
> )
> ```
>
> Unmodified buffers reload silently; buffers with unsaved edits get Vim's W12
> prompt; deleted files are left as-is — the same behaviour this plugin gave.
>
> **On Linux**, Neovim disables the built-in watcher by default (no scalable
> recursive inotify backend — see [#23291](https://github.com/neovim/neovim/issues/23291)),
> so this plugin's approach still fills a real gap. The final code here is
> functional — a per-directory Linux watcher, mid-write stability checks, and
> an LSP `replace` mode that stops the built-in from double-watching — but it
> is no longer actively maintained. Fork if you need it.

---

File watcher for Neovim that synchronizes buffers and LSP when external tools modify files.

## The Problem

When external tools (Claude Code, Aider, git, formatters) modify files:

- Neovim buffers show stale content (`autoread` only checks on focus)
- LSP servers don't know files changed
- Unsaved changes may conflict with external modifications
- Naive file watchers can read files mid-write

### Neovim's Built-in LSP File Watching

Neovim 0.10+ has `workspace/didChangeWatchedFiles`, but:

- **Disabled on Linux** - inotify can't watch recursively; polling fallback uses 30-40% CPU ([#23291](https://github.com/neovim/neovim/issues/23291))
- **Only notifies LSP** - doesn't reload buffers
- **No stability check** - can read files mid-write

## Features

- Cross-platform file watching (libuv): recursive fs_event on macOS/Windows,
  per-directory watchers on Linux/BSD (libuv's recursive flag is silently
  ignored there — see `:h agentwatch-watch`)
- Buffer reloading with undo preservation
- LSP notifications, including a `replace` mode that takes over file watching
  from Neovim's built-in (useful on Linux, where the built-in either doesn't
  run or falls back to polling)
- Conflict detection (defers to Neovim's W12 warning)
- Pause/resume API for tool integration (also holds off Vim's own `autoread`
  while paused)

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "yngwi/agentwatch.nvim",
  config = function()
    require("agentwatch").setup({})  -- starts watching cwd immediately
  end,
}
```

## Configuration

Defaults:

```lua
require("agentwatch").setup({
  enabled = true,

  watch = {
    backend = "auto",           -- "auto" | "recursive" | "walk"
    debounce_ms = 150,
    stability_ms = 50,
    use_gitignore = true,       -- parse .gitignore (default: true)
    ignore_patterns = {},       -- additional Lua patterns (merged with defaults)
    include_patterns = nil,     -- Lua patterns
    watch_hidden = false,
  },

  buffer = {
    notify_on_reload = false,
    notify_on_conflict = false,
    restore_view = true,
  },

  lsp = {
    mode = "complement",  -- "complement" | "replace" | "off"
  },

  debug = {
    enabled = false,
    log_file = nil,
  },
})
```

## Commands

| Command             | Description                  |
| ------------------- | ---------------------------- |
| `:AgentwatchStatus` | Show state and watched paths |
| `:AgentwatchPause`  | Pause watching, queue events |
| `:AgentwatchResume` | Resume and process queue     |

## API

```lua
local aw = require("agentwatch")

aw.pause()              -- pause watching
aw.resume()             -- resume and process queue
aw.is_paused()          -- check if paused
aw.sync()               -- reload all buffers
aw.sync_buffer(bufnr)   -- reload specific buffer
aw.status()             -- get status table
aw.on(event, callback)  -- subscribe to "reload", "conflict", "lsp_notify"
```

## Integration Example

Pause during external tool writes:

```lua
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

## License

MIT
