-- Test setup: package.path and minimal vim mock
-- Expand vim mock as needed when adding more tests

-- Add lua/ to package.path so we can require agentwatch modules
local repo_root = debug.getinfo(1, "S").source:match("@(.*/)")
  or debug.getinfo(1, "S").source:match("@(.*\\)")
  or "./"

-- Handle both forward and backslashes, go up from spec/helpers/ to repo root
repo_root = repo_root:gsub("spec[/\\]helpers[/\\]$", "")
package.path = repo_root .. "lua/?.lua;" .. repo_root .. "lua/?/init.lua;" .. package.path

-- Minimal vim mock - only what's needed for current tests
-- Expand this table as you add tests that need more vim APIs
_G.vim = {
  -- Table utilities (needed by config.lua)
  deepcopy = function(t)
    if type(t) ~= "table" then return t end
    local copy = {}
    for k, v in pairs(t) do
      copy[k] = _G.vim.deepcopy(v)
    end
    return copy
  end,

  tbl_deep_extend = function(behavior, ...)
    local result = {}
    for _, t in ipairs({ ... }) do
      for k, v in pairs(t) do
        if type(v) == "table" and type(result[k]) == "table" then
          result[k] = _G.vim.tbl_deep_extend(behavior, result[k], v)
        else
          result[k] = _G.vim.deepcopy(v)
        end
      end
    end
    return result
  end,

  -- Stubs for things that get called but we don't care about in pure tests
  fn = {
    fnamemodify = function(path, mods)
      if mods == ":t" then
        return path:match("[^/\\]+$") or path
      end
      return path
    end,
  },

  schedule = function(fn) fn() end,
  notify = function() end,
  log = { levels = { ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4 } },
}
