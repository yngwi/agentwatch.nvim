---@mod agentwatch.buffer Buffer reload and conflict detection
local M = {}

local util = require("agentwatch.util")
local config = require("agentwatch.config")


---@param filepath string
---@return integer?
function M.get_buffer_for_file(filepath)
  filepath = util.normalize_path(vim.fn.fnamemodify(filepath, ":p"))

  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local bufpath = vim.api.nvim_buf_get_name(bufnr)
      local normalized = util.normalize_path(vim.fn.fnamemodify(bufpath, ":p"))
      if bufpath and normalized == filepath then
        return bufnr
      end
    end
  end

  return nil
end

---@param bufnr integer
---@param filepath string
---@return boolean
function M.check_conflict(bufnr, filepath)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  if not vim.bo[bufnr].modified then
    return false
  end

  util.log("debug", string.format("Conflict: buffer %d modified, file %s changed", bufnr, filepath))
  return true
end

--- Remember the disk state a buffer was synced to, so the FileChangedShell
--- handler can tell Vim there is nothing left to do (avoids spurious W11
--- warnings / redundant autoread reloads after background syncs).
---@param bufnr integer
---@param stat uv.fs_stat.result? Stat taken before the buffer content was read
function M._mark_synced(bufnr, stat)
  if stat then
    vim.b[bufnr].agentwatch_synced_mtime = {
      sec = stat.mtime.sec,
      nsec = stat.mtime.nsec,
    }
  end
end

---@param bufnr integer
---@param opts? { force?: boolean }
---@return boolean
function M.reload(bufnr, opts)
  opts = opts or {}

  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end

  local cfg = config.get()
  local filepath = vim.api.nvim_buf_get_name(bufnr)

  if vim.bo[bufnr].modified and not opts.force then
    util.log("debug", "Skipping reload of modified buffer: " .. filepath)
    return false
  end

  -- Stat before reading: if the file changes in between, the marker is older
  -- than the content and Vim will still do its own (redundant but safe) check
  local stat = vim.uv.fs_stat(filepath)

  local ok, disk_lines = pcall(vim.fn.readfile, filepath)
  if not ok then
    util.log("debug", "Could not read file: " .. filepath)
    return false
  end

  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if vim.deep_equal(buf_lines, disk_lines) then
    util.log("debug", "Content unchanged, skipping reload: " .. filepath)
    M._mark_synced(bufnr, stat)
    return false
  end

  local view = nil
  local was_current = vim.api.nvim_get_current_buf() == bufnr

  if was_current and cfg.buffer.restore_view then
    view = vim.fn.winsaveview()
  end

  -- Current buffer: edit! preserves undo tree
  -- Background buffer: set_lines avoids UI flash (coarser undo, but no flicker)
  local reloaded
  if was_current then
    reloaded = pcall(vim.cmd, "edit!")
    if not reloaded then
      -- edit! is invalid in some contexts (e.g. cmdline window)
      reloaded = M._set_lines(bufnr, disk_lines)
    end
  else
    reloaded = M._set_lines(bufnr, disk_lines)
  end

  if not reloaded then
    util.log("debug", "Could not reload buffer: " .. filepath)
    return false
  end

  if view and was_current and cfg.buffer.restore_view then
    pcall(vim.fn.winrestview, view)
  end

  M._mark_synced(bufnr, stat)
  util.log("debug", "Reloaded buffer: " .. filepath)
  return true
end

---@param bufnr integer
---@param disk_lines string[]
---@return boolean
function M._set_lines(bufnr, disk_lines)
  return (pcall(function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, disk_lines)
    vim.bo[bufnr].modified = false
  end))
end

return M
