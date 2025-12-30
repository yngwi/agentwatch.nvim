---@mod agentwatch File synchronization for external changes
---@brief [[
--- agentwatch detects when external tools modify files and:
--- - Reloads buffers (preserving undo history)
--- - Notifies LSP servers (workspace/didChangeWatchedFiles)
--- - Detects conflicts (defers to Neovim's built-in W12 warning)
---
--- Usage:
---   require("agentwatch").setup({})
---
--- Commands:
---   :AgentwatchStatus    - Show current status
---   :AgentwatchPause     - Pause file watching
---   :AgentwatchResume    - Resume file watching
---   :AgentwatchReload    - Reload plugin (development)
---@brief ]]

local M = {}

---@type "idle"|"debouncing"|"paused"
M._state = "idle"

---@type table[] Queued events when paused
M._event_queue = {}

---@type table<string, function[]> Event callbacks
M._callbacks = {
  reload = {},
  conflict = {},
  lsp_notify = {},
}

---@type table? User-provided options (for reload)
M._user_opts = nil

--- Setup agentwatch with user configuration
---@param opts? table Configuration options (see docs/DESIGN.md)
function M.setup(opts)
  if opts then
    M._user_opts = opts  -- Store for reload
  end

  local config = require("agentwatch.config")
  config.setup(opts or M._user_opts)

  if not config.get().enabled then
    return
  end

  local watcher = require("agentwatch.watcher")
  local lsp = require("agentwatch.lsp")

  lsp.setup_capability_tracking()

  local cwd = vim.fn.getcwd()
  config.load_gitignore(cwd)
  watcher.start({ cwd })

  M._register_commands()
  M._register_autocmds()
end

--- Pause file watching (events will be queued)
function M.pause()
  if M._state == "paused" then
    return
  end
  M._state = "paused"
  require("agentwatch.util").log("info", "agentwatch paused")
end

--- Resume file watching and process queued events
function M.resume()
  if M._state ~= "paused" then
    return
  end
  M._state = "idle"

  local util = require("agentwatch.util")

  local latest_events = {}
  for _, event in ipairs(M._event_queue) do
    local normalized = util.normalize_path(event.filepath)
    latest_events[normalized] = event  -- Keep only latest per file
  end

  local deduped = vim.tbl_values(latest_events)

  util.log("info", string.format(
    "agentwatch resumed, processing %d events (deduped from %d)",
    #deduped, #M._event_queue
  ))

  M._event_queue = {}

  for _, event in ipairs(deduped) do
    M._process_event(event)
  end
end

--- Check if currently paused
---@return boolean
function M.is_paused()
  return M._state == "paused"
end

--- Manually trigger sync for all buffers
function M.sync()
  local buffer = require("agentwatch.buffer")
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local filepath = vim.api.nvim_buf_get_name(bufnr)
      if filepath and filepath ~= "" and not buffer.check_conflict(bufnr, filepath) then
        buffer.reload(bufnr)
      end
    end
  end
end

--- Manually trigger sync for specific buffer
---@param bufnr integer Buffer number
function M.sync_buffer(bufnr)
  local buffer = require("agentwatch.buffer")
  local filepath = vim.api.nvim_buf_get_name(bufnr)
  if filepath and filepath ~= "" and not buffer.check_conflict(bufnr, filepath) then
    buffer.reload(bufnr)
  end
end

--- Get current status
---@return table Status information
function M.status()
  local watcher = require("agentwatch.watcher")
  local config = require("agentwatch.config")

  return {
    state = M._state,
    enabled = config.get().enabled,
    watched_paths = watcher.get_watched_paths(),
    queued_events = #M._event_queue,
    config = config.get(),
  }
end

--- Register event callback
---@param event "reload"|"conflict"|"lsp_notify"
---@param callback function
function M.on(event, callback)
  if M._callbacks[event] then
    table.insert(M._callbacks[event], callback)
  end
end

--- Emit event to callbacks
---@param event string
---@param data any
function M._emit(event, data)
  for _, callback in ipairs(M._callbacks[event] or {}) do
    pcall(callback, data)
  end
end

---@param event table Event data with filepath and change_type
function M._process_event(event)
  if M._state == "paused" then
    table.insert(M._event_queue, event)
    return
  end

  local buffer = require("agentwatch.buffer")
  local lsp = require("agentwatch.lsp")
  local config = require("agentwatch.config")
  local util = require("agentwatch.util")

  local cfg = config.get()
  local filepath = event.filepath
  local change_type = event.change_type
  local short_path = vim.fn.fnamemodify(filepath, ":~:.")
  local bufnr = buffer.get_buffer_for_file(filepath)

  if bufnr then
    local conflict = buffer.check_conflict(bufnr, filepath)

    if conflict then
      -- Neovim's W12 warning handles resolution when user interacts with buffer
      util.log("debug", "Conflict detected for buffer " .. bufnr .. ", skipping reload")
      if cfg.buffer.notify_on_conflict then
        vim.notify(
          string.format("Conflict: %s changed externally (buffer modified)", short_path),
          vim.log.levels.WARN,
          { title = "agentwatch" }
        )
      end
      M._emit("conflict", { bufnr = bufnr, filepath = filepath })
    else
      util.log("debug", "Reloading buffer " .. bufnr .. ": " .. filepath)
      local reloaded = buffer.reload(bufnr)
      if reloaded then
        if cfg.buffer.notify_on_reload then
          vim.notify(
            string.format("Reloaded: %s", short_path),
            vim.log.levels.INFO,
            { title = "agentwatch" }
          )
        end
        M._emit("reload", { bufnr = bufnr, filepath = filepath })
      end
    end
  end

  if cfg.lsp.mode ~= "off" then
    lsp.notify_change(filepath, change_type)
    M._emit("lsp_notify", { filepath = filepath, change_type = change_type })
  end
end

--- Register user commands
function M._register_commands()
  vim.api.nvim_create_user_command("AgentwatchStatus", function()
    print(vim.inspect(M.status()))
  end, { desc = "Show agentwatch status" })

  vim.api.nvim_create_user_command("AgentwatchPause", function()
    M.pause()
    vim.notify("agentwatch paused", vim.log.levels.INFO)
  end, { desc = "Pause agentwatch file watching" })

  vim.api.nvim_create_user_command("AgentwatchResume", function()
    M.resume()
    vim.notify("agentwatch resumed", vim.log.levels.INFO)
  end, { desc = "Resume agentwatch file watching" })

  vim.api.nvim_create_user_command("AgentwatchReload", function()
    -- Save opts before clearing modules
    local saved_opts = M._user_opts

    -- Clear cached modules
    for name, _ in pairs(package.loaded) do
      if name:match("^agentwatch") then
        package.loaded[name] = nil
      end
    end

    -- Re-require and setup with saved opts
    require("agentwatch").setup(saved_opts)
    vim.notify("agentwatch reloaded", vim.log.levels.INFO)
  end, { desc = "Reload agentwatch plugin (development)" })
end

function M._register_autocmds()
  local group = vim.api.nvim_create_augroup("agentwatch", { clear = true })

  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      local cfg = require("agentwatch.config")
      local watcher = require("agentwatch.watcher")
      local cwd = vim.fn.getcwd()
      cfg.load_gitignore(cwd)
      watcher.update_paths({ cwd })
    end,
  })

  -- Ignore fs_events triggered by our own writes
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      local filepath = vim.api.nvim_buf_get_name(ev.buf)
      if filepath and filepath ~= "" then
        local watcher = require("agentwatch.watcher")
        local util = require("agentwatch.util")
        filepath = util.normalize_path(vim.fn.fnamemodify(filepath, ":p"))
        watcher.record_write(filepath)
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimLeave", {
    group = group,
    callback = function()
      local watcher = require("agentwatch.watcher")
      local util = require("agentwatch.util")
      watcher.stop()
      util.close_log()
    end,
  })
end

return M
