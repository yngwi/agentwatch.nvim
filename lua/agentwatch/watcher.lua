---@mod agentwatch.watcher File system watching
local M = {}

local util = require("agentwatch.util")
local config = require("agentwatch.config")

---@class agentwatch.WatchEntry
---@field handle uv.uv_fs_event_t
---@field root string Top-level watch root this directory belongs to

---@type table<string, agentwatch.WatchEntry> Active fs_event handles by watched directory
M._handles = {}

---@type table<string, uv.uv_timer_t> Debounce timers by filepath
M._debounce_timers = {}

---@type table<string, function> Latest debounced callback by filepath
M._debounce_callbacks = {}

---@type string[] Currently watched root paths (normalized)
M._watched_paths = {}

---@type table<string, number> Recent Neovim writes (filepath -> timestamp)
M._recent_writes = {}

---@type "recursive"|"walk" Backend chosen at start()
M._backend = "recursive"

---@type boolean True when the walk backend hit MAX_DIR_WATCHERS
M._overflowed = false

--- Cap on per-directory watchers (inotify watch descriptors are finite)
local MAX_DIR_WATCHERS = 4096

--- libuv supports recursive fs_event watching only on macOS and Windows; on
--- other platforms the flag is silently ignored and only the top-level
--- directory would be watched. There, watch every directory individually.
--- https://docs.libuv.org/en/v1.x/fs_event.html
---@return "recursive"|"walk"
function M._select_backend()
  local backend = config.get().watch.backend
  if backend == "recursive" or backend == "walk" then
    return backend
  end
  local sysname = vim.uv.os_uname().sysname
  if sysname == "Darwin" or sysname:find("Windows") then
    return "recursive"
  end
  return "walk"
end

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
  M._backend = M._select_backend()

  local roots = {}
  for _, path in ipairs(paths) do
    local root = util.normalize_path(vim.fn.fnamemodify(path, ":p"))
    table.insert(roots, root)
    if M._backend == "recursive" then
      M._watch_dir(root, root, true)
    else
      M._watch_tree(root, root)
    end
  end

  M._watched_paths = roots
  util.log("info", string.format(
    "Started watching %d paths (backend: %s, %d handles)",
    #roots, M._backend, vim.tbl_count(M._handles)
  ))
end

function M.stop()
  for _, entry in pairs(M._handles) do
    local handle = entry.handle
    if not handle:is_closing() then
      pcall(function()
        handle:stop()
        handle:close()
      end)
    end
  end
  M._handles = {}

  for _, timer in pairs(M._debounce_timers) do
    if not timer:is_closing() then
      pcall(function()
        timer:stop()
        timer:close()
      end)
    end
  end
  M._debounce_timers = {}
  M._debounce_callbacks = {}

  M._watched_paths = {}
  M._overflowed = false
  util.log("info", "Stopped all watchers")
end

--- Watch a single directory.
---@param dir string Normalized directory path
---@param root string Watch root this directory belongs to
---@param recursive boolean
---@return boolean started
function M._watch_dir(dir, root, recursive)
  if M._handles[dir] then
    return true
  end

  if vim.tbl_count(M._handles) >= MAX_DIR_WATCHERS then
    if not M._overflowed then
      M._overflowed = true
      util.log("warn", string.format(
        "agentwatch: directory watcher limit (%d) reached; some directories are not watched",
        MAX_DIR_WATCHERS
      ))
    end
    return false
  end

  local handle = vim.uv.new_fs_event()
  if not handle then
    util.log("error", "Failed to create fs_event handle for: " .. dir)
    return false
  end

  local ok, err = pcall(function()
    handle:start(dir, recursive and { recursive = true } or {}, function(cb_err, filename, events)
      if cb_err then
        util.log("error", "fs_event error: " .. tostring(cb_err))
        return
      end

      vim.schedule(function()
        M._on_event(dir, root, filename, events)
      end)
    end)
  end)

  if not ok then
    pcall(function() handle:close() end)
    util.log("error", "Failed to start watching " .. dir .. ": " .. tostring(err))
    return false
  end

  M._handles[dir] = { handle = handle, root = root }
  return true
end

--- Watch a directory and (walk backend) all non-ignored subdirectories.
---@param dir string Normalized directory path
---@param root string Watch root
---@param on_file? fun(filepath: string) Called for each regular file found
function M._watch_tree(dir, root, on_file)
  if dir ~= root and config.should_ignore(dir, { root = root, is_dir = true }) then
    return
  end
  if not M._watch_dir(dir, root, false) then
    return
  end

  local req = vim.uv.fs_scandir(dir)
  if not req then
    return
  end

  while true do
    local name, ftype = vim.uv.fs_scandir_next(req)
    if not name then
      break
    end
    local child = dir .. "/" .. name
    if not ftype then
      local stat = vim.uv.fs_stat(child)
      ftype = stat and stat.type
    end
    if ftype == "directory" then
      M._watch_tree(child, root, on_file)
    elseif ftype == "file" and on_file then
      on_file(child)
    end
  end
end

--- Stop watchers for a directory and everything beneath it.
---@param dir string Normalized directory path
function M._remove_subtree(dir)
  for watched, entry in pairs(M._handles) do
    if watched == dir or watched:sub(1, #dir + 1) == dir .. "/" then
      local handle = entry.handle
      if not handle:is_closing() then
        pcall(function()
          handle:stop()
          handle:close()
        end)
      end
      M._handles[watched] = nil
    end
  end
end

---@param path string
function M.remove_path(path)
  M._remove_subtree(util.normalize_path(vim.fn.fnamemodify(path, ":p")))
end

---@param paths string[]
function M.update_paths(paths)
  M.start(paths)
end

---@return string[]
function M.get_watched_paths()
  return M._watched_paths
end

--- Whether a file lies inside a watched root and is not ignored.
---@param filepath string Absolute path
---@return boolean
function M.is_watched(filepath)
  local normalized = util.normalize_path(vim.fn.fnamemodify(filepath, ":p"))
  for _, root in ipairs(M._watched_paths) do
    if normalized == root or normalized:sub(1, #root + 1) == root .. "/" then
      return not config.should_ignore(normalized, { root = root })
    end
  end
  return false
end

---@param dir string Directory whose watcher fired
---@param root string Watch root the directory belongs to
---@param filename string? Filename relative to dir
---@param events table Event flags
function M._on_event(dir, root, filename, events)
  if not filename then
    return
  end

  local filepath = vim.fs.joinpath(dir, filename)
  filepath = util.normalize_path(vim.fn.fnamemodify(filepath, ":p"))

  -- Hot-reload ignore rules when .gitignore itself changes (checked before
  -- the ignore filter: dotfiles are normally filtered out)
  if filepath == config.gitignore_path() then
    config.reload_gitignore()
  end

  local stat = vim.uv.fs_stat(filepath)
  local is_dir = (stat and stat.type == "directory") or false

  if config.should_ignore(filepath, { root = root, is_dir = is_dir }) then
    util.log("debug", "Ignoring: " .. filepath)
    return
  end

  if is_dir then
    if M._backend == "walk" and not M._handles[filepath] then
      -- New directory: watch it, and report files written before the
      -- watcher attached (e.g. `git checkout` creating whole trees)
      M._watch_tree(filepath, root, function(newfile)
        if not config.should_ignore(newfile, { root = root }) then
          M._queue(newfile, 1)
        end
      end)
    end
    return
  end

  if not stat and M._handles[filepath] then
    -- A watched directory disappeared; per-file deletions arrive from its
    -- own watcher, so only the bookkeeping is needed here
    M._remove_subtree(filepath)
    return
  end

  if M._recent_writes[filepath] then
    util.log("debug", "Skipping self-triggered event: " .. filepath)
    return
  end

  local change_type = 2  -- Changed
  if events.rename then
    change_type = stat and 1 or 3  -- Created or Deleted
  end

  M._queue(filepath, change_type)
end

---@param filepath string Normalized absolute path
---@param change_type integer 1=Created, 2=Changed, 3=Deleted
function M._queue(filepath, change_type)
  util.log("debug", string.format("Event: %s (type=%d)", filepath, change_type))
  M._debounce(filepath, function()
    M._process_after_stability(filepath, change_type)
  end)
end

---@param filepath string
---@param callback function
function M._debounce(filepath, callback)
  local cfg = config.get()

  M._debounce_callbacks[filepath] = callback

  local timer = M._debounce_timers[filepath]
  if not timer or timer:is_closing() then
    timer = vim.uv.new_timer()
    if not timer then
      return
    end
    M._debounce_timers[filepath] = timer
  end

  timer:stop()
  timer:start(cfg.watch.debounce_ms, 0, vim.schedule_wrap(function()
    local cb = M._debounce_callbacks[filepath]
    M._debounce_callbacks[filepath] = nil

    local t = M._debounce_timers[filepath]
    if t and not t:is_closing() then
      t:stop()
      t:close()
    end
    M._debounce_timers[filepath] = nil

    if cb then
      cb()
    end
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
    if is_stable == nil then
      -- File vanished between the event and the stability check
      util.log("debug", "File vanished, reporting deletion: " .. filepath)
      M._emit_event(filepath, 3)
    elseif is_stable then
      M._emit_event(filepath, change_type)
    else
      util.log("debug", "File not stable, re-debouncing: " .. filepath)
      M._debounce(filepath, function()
        M._process_after_stability(filepath, change_type)
      end)
    end
  end)
end

--- Verify file mtime unchanged after stability_ms delay.
---@param filepath string
---@param callback fun(is_stable: boolean?) nil = file no longer exists
function M._check_stability(filepath, callback)
  local cfg = config.get()
  local stat1 = vim.uv.fs_stat(filepath)
  if not stat1 then
    callback(nil)
    return
  end

  vim.defer_fn(function()
    local stat2 = vim.uv.fs_stat(filepath)
    if not stat2 then
      callback(nil)
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
