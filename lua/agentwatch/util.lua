---@mod agentwatch.util Utility functions
local M = {}

---@type file*?
M._log_file = nil

function M.close_log()
  if M._log_file then
    M._log_file:close()
    M._log_file = nil
  end
end

---@param level "debug"|"info"|"warn"|"error"
---@param msg string
function M.log(level, msg)
  local config = require("agentwatch.config")
  local cfg = config.get()

  if not cfg.debug.enabled and level == "debug" then
    return
  end

  local timestamp = os.date("%Y-%m-%d %H:%M:%S")
  local formatted = string.format("[%s] [agentwatch] [%s] %s", timestamp, level:upper(), msg)

  local log_path = cfg.debug.log_file
  if cfg.debug.enabled and not log_path then
    log_path = vim.fn.stdpath("log") .. "/agentwatch.log"
  end

  if log_path then
    if not M._log_file then
      M._log_file = io.open(log_path, "a")
    end
    if M._log_file then
      M._log_file:write(formatted .. "\n")
      M._log_file:flush()
    end
  end

  if level == "error" then
    vim.schedule(function()
      vim.notify(msg, vim.log.levels.ERROR, { title = "agentwatch" })
    end)
  elseif level == "warn" then
    vim.schedule(function()
      vim.notify(msg, vim.log.levels.WARN, { title = "agentwatch" })
    end)
  end
end

---@param path string
---@return string
function M.normalize_path(path)
  local normalized = path:gsub("\\", "/")
  return normalized:gsub("/$", "")
end

---@param path string
---@return boolean
function M.is_absolute(path)
  if path:match("^%a:[\\/]") or path:match("^[\\/][\\/]") then
    return true
  end
  return path:sub(1, 1) == "/"
end

---@param ... string
---@return string
function M.join_path(...)
  local parts = { ... }
  return table.concat(parts, "/"):gsub("[\\/]+", "/")
end

return M
