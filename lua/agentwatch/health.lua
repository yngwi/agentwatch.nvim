---@mod agentwatch.health Health check for agentwatch
local M = {}

function M.check()
  vim.health.start("agentwatch")

  if vim.uv then
    vim.health.ok("vim.uv available")
  else
    vim.health.error("vim.uv not available (requires Neovim 0.10+)")
    return
  end

  local ok, agentwatch = pcall(require, "agentwatch")
  if not ok then
    vim.health.error("Failed to load agentwatch: " .. tostring(agentwatch))
    return
  end

  local config_ok, config = pcall(require, "agentwatch.config")
  if not config_ok or not config._current then
    vim.health.warn("setup() not called - plugin not initialized")
    return
  end

  if config.get().enabled then
    vim.health.ok("Plugin enabled")
  else
    vim.health.info("Plugin disabled via config")
    return
  end

  local state = agentwatch._state
  if state == "idle" then
    vim.health.ok("State: idle")
  elseif state == "paused" then
    vim.health.warn("State: paused (" .. #agentwatch._event_queue .. " events queued)")
  elseif state == "debouncing" then
    vim.health.info("State: debouncing")
  else
    vim.health.warn("State: " .. tostring(state))
  end

  vim.health.start("agentwatch: file watching")

  local watcher_ok, watcher = pcall(require, "agentwatch.watcher")
  if watcher_ok then
    local paths = watcher.get_watched_paths()
    local handle_count = vim.tbl_count(watcher._handles)

    if #paths > 0 then
      vim.health.ok("Watching " .. #paths .. " path(s) with " .. handle_count .. " handle(s)")
      for _, path in ipairs(paths) do
        vim.health.info("    " .. path)
      end
    else
      vim.health.warn("No paths being watched")
    end
  end

  vim.health.start("agentwatch: ignore patterns")

  local cfg = config.get()
  local config_patterns = cfg.watch.ignore_patterns or {}
  local gitignore_patterns = config._gitignore_patterns or {}

  vim.health.info("Config (" .. #config_patterns .. "): " .. table.concat(config_patterns, ", "))

  if cfg.watch.use_gitignore then
    if #gitignore_patterns > 0 then
      vim.health.info("Gitignore (" .. #gitignore_patterns .. "): " .. table.concat(gitignore_patterns, ", "))
    else
      vim.health.info("Gitignore: no .gitignore found")
    end

    local skipped = config._skipped_negations or {}
    if #skipped > 0 then
      vim.health.warn("Skipped negation patterns (" .. #skipped .. "): " .. table.concat(skipped, ", "))
    end
  else
    vim.health.info("Gitignore: disabled")
  end

  vim.health.start("agentwatch: LSP integration")

  vim.health.info("Mode: " .. cfg.lsp.mode)

  if cfg.lsp.mode ~= "off" then
    local clients = vim.lsp.get_clients()
    if #clients > 0 then
      vim.health.ok(#clients .. " LSP client(s) attached")
      for _, client in ipairs(clients) do
        vim.health.info("    " .. client.name)
      end

      local lsp_ok, lsp = pcall(require, "agentwatch.lsp")
      if lsp_ok then
        local registered_count = vim.tbl_count(lsp._registered_watchers)
        if registered_count > 0 then
          vim.health.info(registered_count .. " client(s) registered for file watching")
        end
      end
    else
      vim.health.info("No LSP clients attached")
    end
  end

  vim.health.start("agentwatch: environment")

  local platform = vim.uv.os_uname().sysname
  vim.health.info("Platform: " .. platform)

  if platform == "Linux" then
    vim.health.info("Note: Neovim's built-in LSP file watching is disabled on Linux by default")
  end

  if cfg.debug.enabled then
    vim.health.info("Debug: enabled")
    local log_path = cfg.debug.log_file or (vim.fn.stdpath("log") .. "/agentwatch.log")
    vim.health.info("Log file: " .. log_path)
  else
    vim.health.info("Debug: disabled")
  end
end

return M
