---@mod agentwatch.lsp LSP workspace notifications
local M = {}

local util = require("agentwatch.util")
local config = require("agentwatch.config")

---@type table<integer, table> Registered watchers per client
M._registered_watchers = {}

---@type boolean Whether capability tracking is already set up
M._tracking_setup = false

function M.setup_capability_tracking()
  if M._tracking_setup then
    return
  end
  M._tracking_setup = true

  local orig_handler = vim.lsp.handlers["client/registerCapability"]

  vim.lsp.handlers["client/registerCapability"] = function(err, result, ctx, cfg)
    if result and result.registrations then
      for _, reg in ipairs(result.registrations) do
        if reg.method == "workspace/didChangeWatchedFiles" then
          M._registered_watchers[ctx.client_id] = {
            id = reg.id,
            patterns = M._parse_watch_patterns(reg.registerOptions),
          }
          util.log("debug", string.format(
            "Client %d registered for file watching", ctx.client_id
          ))
        end
      end
    end

    if orig_handler then
      return orig_handler(err, result, ctx, cfg)
    end
  end
end

---@param options table
---@return table
function M._parse_watch_patterns(options)
  local patterns = {}

  if options and options.watchers then
    for _, watcher in ipairs(options.watchers) do
      if type(watcher.globPattern) == "string" then
        table.insert(patterns, watcher.globPattern)
      elseif type(watcher.globPattern) == "table" and watcher.globPattern.pattern then
        table.insert(patterns, watcher.globPattern.pattern)
      end
    end
  end

  return patterns
end

---@param filepath string
---@param change_type integer 1=Created, 2=Changed, 3=Deleted
function M.notify_change(filepath, change_type)
  local cfg = config.get()

  if cfg.lsp.mode == "off" then
    return
  end

  local uri = vim.uri_from_fname(filepath)
  local changes = {
    { uri = uri, type = change_type }
  }

  for _, client in ipairs(vim.lsp.get_clients()) do
    if M._should_notify(client, filepath) then
      client:notify("workspace/didChangeWatchedFiles", { changes = changes })
      util.log("debug", string.format(
        "Notified %s of change to %s (type=%d)",
        client.name, filepath, change_type
      ))
    end
  end
end

---@param client vim.lsp.Client
---@param filepath string
---@return boolean
function M._should_notify(client, filepath)
  local cfg = config.get()

  local registered = M._registered_watchers[client.id]
  if registered and M._matches_patterns(filepath, registered.patterns) then
    return true
  end

  if cfg.lsp.mode == "complement" then
    local caps = client.server_capabilities
    if caps and caps.workspace and caps.workspace.didChangeWatchedFiles then
      return M._is_relevant_filetype(client, filepath)
    end
    return false
  end

  if cfg.lsp.mode == "replace" then
    return M._is_relevant_filetype(client, filepath)
  end

  return false
end

---@param filepath string
---@param patterns string[]
---@return boolean
function M._matches_patterns(filepath, patterns)
  if not patterns or #patterns == 0 then
    return true
  end

  local filename = vim.fn.fnamemodify(filepath, ":t")
  local normalized = filepath:gsub("\\", "/")

  for _, pattern in ipairs(patterns) do
    local lua_pattern = M._glob_to_pattern(pattern)
    if normalized:match(lua_pattern) or filename:match(lua_pattern) then
      return true
    end
  end

  return false
end

---@param glob string
---@return string
function M._glob_to_pattern(glob)
  local pattern = glob
  pattern = pattern:gsub("([%.%+%-%^%$%(%)%%])", "%%%1")
  pattern = pattern:gsub("%?", "___QUESTION___")
  pattern = pattern:gsub("%*%*/", ".-")
  pattern = pattern:gsub("%*%*", ".*")
  pattern = pattern:gsub("%*", "[^/\\]*")
  pattern = pattern:gsub("___QUESTION___", ".")
  return pattern
end

---@param client vim.lsp.Client
---@param filepath string
---@return boolean
function M._is_relevant_filetype(client, filepath)
  local ext = vim.fn.fnamemodify(filepath, ":e")
  local ft = vim.filetype.match({ filename = filepath }) or ext

  local client_filetypes = client.config.filetypes
  if client_filetypes then
    for _, client_ft in ipairs(client_filetypes) do
      if client_ft == ft then
        return true
      end
    end
    return false
  end

  return true
end

return M
