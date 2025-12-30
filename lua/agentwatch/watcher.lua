---@mod agentwatch.watcher File system watching
local M = {}

local util = require("agentwatch.util")
local config = require("agentwatch.config")

---@type table<string, userdata> Active fs_event handles by path
M._handles = {}

---@type table<string, userdata> Debounce timers by filepath
M._debounce_timers = {}

---@type table<string, number> Last event time by filepath (for stability check)
M._last_event = {}

---@type string[] Currently watched root paths
M._watched_paths = {}

---@type table<string, number> Recent Neovim writes (filepath -> timestamp)
M._recent_writes = {}

---@param filepath string Absolute, normalized path
function M.record_write(filepath)
  M._recent_writes[filepath] = vim.uv.hrtime()
  vim.defer_fn(function()
    M._recent_writes[filepath] = nil
  end, 1000)
end

---@param paths string[]
function M.start(paths)
  M.stop()

  for _, path in ipairs(paths) do
    M.add_path(path)
  end

  M._watched_paths = paths
  util.log("info", "Started watching " .. #paths .. " paths")
end

function M.stop()
  for _, handle in pairs(M._handles) do
    pcall(function() handle:stop() end)
  end
  M._handles = {}

  for _, timer in pairs(M._debounce_timers) do
    pcall(function() timer:stop() end)
  end
  M._debounce_timers = {}

  M._watched_paths = {}
  util.log("info", "Stopped all watchers")
end

---@param path string
function M.add_path(path)
  if M._handles[path] then
    return
  end

  local handle = vim.uv.new_fs_event()
  if not handle then
    util.log("error", "Failed to create fs_event handle for: " .. path)
    return
  end

  local ok, err = pcall(function()
    handle:start(path, { recursive = true }, function(err, filename, events)
      if err then
        util.log("error", "fs_event error: " .. err)
        return
      end

      vim.schedule(function()
        M._on_event(path, filename, events)
      end)
    end)
  end)

  if not ok then
    util.log("error", "Failed to start watching " .. path .. ": " .. tostring(err))
    return
  end

  M._handles[path] = handle
  util.log("debug", "Now watching: " .. path)
end

---@param path string
function M.remove_path(path)
  local handle = M._handles[path]
  if handle then
    pcall(function() handle:stop() end)
    M._handles[path] = nil
    util.log("debug", "Stopped watching: " .. path)
  end
end

---@param paths string[]
function M.update_paths(paths)
  M.start(paths)
end

---@return string[]
function M.get_watched_paths()
  return M._watched_paths
end

---@param root string Root path that fired event
---@param filename string Relative filename
---@param events table Event flags
function M._on_event(root, filename, events)
  if not filename then
    return
  end

  local filepath = vim.fs.joinpath(root, filename)
  filepath = vim.fn.fnamemodify(filepath, ":p")

  if config.should_ignore(filepath) then
    util.log("debug", "Ignoring: " .. filepath)
    return
  end

  local stat = vim.uv.fs_stat(filepath)
  if stat and stat.type == "directory" then
    return
  end

  local normalized = util.normalize_path(filepath)
  if M._recent_writes[normalized] then
    util.log("debug", "Skipping self-triggered event: " .. filepath)
    return
  end

  local change_type = 2  -- Changed
  if events.rename then
    change_type = vim.uv.fs_stat(filepath) and 1 or 3  -- Created or Deleted
  end

  util.log("debug", string.format("Event: %s (type=%d)", filepath, change_type))
  M._last_event[filepath] = vim.uv.hrtime()
  M._debounce(filepath, function()
    M._process_after_stability(filepath, change_type)
  end)
end

---@param filepath string
---@param callback function
function M._debounce(filepath, callback)
  local cfg = config.get()

  if M._debounce_timers[filepath] then
    M._debounce_timers[filepath]:stop()
  end

  local timer = vim.uv.new_timer()
  M._debounce_timers[filepath] = timer

  timer:start(cfg.watch.debounce_ms, 0, vim.schedule_wrap(function()
    timer:stop()
    M._debounce_timers[filepath] = nil
    callback()
  end))
end

---@param filepath string
---@param change_type integer 1=Created, 2=Changed, 3=Deleted
function M._process_after_stability(filepath, change_type)
  if change_type == 3 then
    M._emit_event(filepath, change_type)
    return
  end

  M._check_stability(filepath, function(is_stable)
    if is_stable then
      M._emit_event(filepath, change_type)
    else
      util.log("debug", "File not stable, re-debouncing: " .. filepath)
      M._debounce(filepath, function()
        M._process_after_stability(filepath, change_type)
      end)
    end
  end)
end

--- Verify file mtime unchanged after stability_ms delay
---@param filepath string
---@param callback fun(is_stable: boolean)
function M._check_stability(filepath, callback)
  local cfg = config.get()
  local stat1 = vim.uv.fs_stat(filepath)
  if not stat1 then
    callback(false)
    return
  end

  vim.defer_fn(function()
    local stat2 = vim.uv.fs_stat(filepath)
    if not stat2 then
      callback(false)
      return
    end
    callback(stat1.mtime.sec == stat2.mtime.sec and
             stat1.mtime.nsec == stat2.mtime.nsec)
  end, cfg.watch.stability_ms)
end

---@param filepath string
---@param change_type integer
function M._emit_event(filepath, change_type)
  util.log("debug", "Emitting event: " .. filepath .. " (type=" .. change_type .. ")")
  local init = require("agentwatch")
  init._process_event({
    filepath = filepath,
    change_type = change_type,
    timestamp = vim.uv.hrtime(),
  })
end

return M
