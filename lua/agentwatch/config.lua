---@mod agentwatch.config Configuration management
local M = {}

---@type table
M.defaults = {
  enabled = true,

  watch = {
    debounce_ms = 150,
    stability_ms = 50,
    use_gitignore = true,
    ignore_patterns = {
      "%.git/",   -- Not in .gitignore
      "~$",
      "%.swp$",
      "%.swo$",
      "4913$",    -- Vim temp file
    },
    include_patterns = nil,
    watch_hidden = false,
  },

  buffer = {
    notify_on_reload = false,
    notify_on_conflict = false,
    restore_view = true,
  },

  lsp = {
    mode = "complement",
  },

  debug = {
    enabled = false,
    log_file = nil,
  },
}

---@type table Current configuration (after user overrides)
M._current = nil

---@type string[] Patterns parsed from .gitignore (Lua patterns)
M._gitignore_patterns = {}

---@param opts? table
function M.setup(opts)
  opts = opts or {}

  -- User ignore_patterns are additive, not replacing
  local user_ignore = opts.watch and opts.watch.ignore_patterns
  if user_ignore then
    opts = vim.deepcopy(opts)
    opts.watch.ignore_patterns = vim.list_extend(
      vim.deepcopy(M.defaults.watch.ignore_patterns),
      user_ignore
    )
  end

  M._current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
end

---@return table
function M.get()
  if not M._current then
    M.setup({})
  end
  return M._current
end

---@param path string
---@return boolean
function M.should_ignore(path)
  if not M._current then
    M.setup({})
  end

  local normalized = path:gsub("\\", "/")

  for _, pattern in ipairs(M._current.watch.ignore_patterns) do
    if normalized:match(pattern) then
      return true
    end
  end

  for _, pattern in ipairs(M._gitignore_patterns) do
    if normalized:match(pattern) then
      return true
    end
  end

  if not M._current.watch.watch_hidden then
    local basename = vim.fn.fnamemodify(path, ":t")
    if basename:sub(1, 1) == "." then
      return true
    end
  end

  if M._current.watch.include_patterns then
    local included = false
    for _, pattern in ipairs(M._current.watch.include_patterns) do
      if normalized:match(pattern) then
        included = true
        break
      end
    end
    if not included then
      return true
    end
  end

  return false
end

--- Convert gitignore glob to Lua pattern. Negation patterns not supported.
---@param glob string
---@return string
function M._gitignore_glob_to_pattern(glob)
  local pattern = glob:match("^%s*(.-)%s*$")

  local anchored = pattern:sub(1, 1) == "/"
  if anchored then
    pattern = pattern:sub(2)
  end

  if pattern:sub(-1) == "/" then
    pattern = pattern:sub(1, -2)
  end

  -- Preserve [...] before escaping other special chars
  local char_classes = {}
  local class_idx = 0
  pattern = pattern:gsub("%[(.-)%]", function(content)
    class_idx = class_idx + 1
    char_classes[class_idx] = content
    return "___CHARCLASS_" .. class_idx .. "___"
  end)

  pattern = pattern:gsub("([%.%+%-%^%$%(%)%%])", "%%%1")

  for i, content in ipairs(char_classes) do
    pattern = pattern:gsub("___CHARCLASS_" .. i .. "___", "[" .. content .. "]")
  end

  -- Convert glob wildcards via placeholders to avoid interference
  pattern = pattern:gsub("%?", "___QUESTION___")
  pattern = pattern:gsub("%*%*/", "___DOUBLESTAR_SLASH___")
  pattern = pattern:gsub("/%*%*", "___SLASH_DOUBLESTAR___")
  pattern = pattern:gsub("%*%*", "___DOUBLESTAR___")
  pattern = pattern:gsub("%*", "[^/]*")
  pattern = pattern:gsub("___QUESTION___", "[^/]")
  pattern = pattern:gsub("___DOUBLESTAR_SLASH___", ".-")
  pattern = pattern:gsub("___SLASH_DOUBLESTAR___", "/.*")
  pattern = pattern:gsub("___DOUBLESTAR___", ".*")

  -- Simple names (no wildcards, no extension) match as path components
  local is_simple_dir = not glob:find("[%*%?]") and not glob:find("%.")

  if is_simple_dir and not anchored then
    pattern = "/" .. pattern .. "/"
  elseif anchored then
    pattern = "^" .. pattern .. "$"
  else
    pattern = pattern .. "$"
  end

  return pattern
end

---@type string[] Negation patterns that were skipped
M._skipped_negations = {}

---@param dir string Directory containing .gitignore
function M.load_gitignore(dir)
  if not M._current then
    M.setup({})
  end

  if not M._current.watch.use_gitignore then
    M._gitignore_patterns = {}
    M._skipped_negations = {}
    return
  end

  local gitignore_path = dir .. "/.gitignore"
  local file = io.open(gitignore_path, "r")
  if not file then
    M._gitignore_patterns = {}
    M._skipped_negations = {}
    return
  end

  local patterns = {}
  local skipped = {}
  local util = require("agentwatch.util")

  for line in file:lines() do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then
      if trimmed:sub(1, 1) == "!" then
        table.insert(skipped, trimmed)
        util.log("debug", "Skipping gitignore negation pattern: " .. trimmed)
      else
        table.insert(patterns, M._gitignore_glob_to_pattern(trimmed))
      end
    end
  end

  file:close()
  M._gitignore_patterns = patterns
  M._skipped_negations = skipped
  util.log("debug", string.format("Loaded %d patterns from %s", #patterns, gitignore_path))
end

return M
