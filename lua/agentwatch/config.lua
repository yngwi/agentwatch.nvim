---@mod agentwatch.config Configuration management
local M = {}

---@type table
M.defaults = {
  enabled = true,

  watch = {
    -- "auto" picks per platform: libuv only supports recursive fs_event
    -- watching on macOS and Windows; elsewhere a per-directory walk is used.
    backend = "auto", -- "auto"|"recursive"|"walk"
    debounce_ms = 150,
    stability_ms = 50,
    use_gitignore = true,
    ignore_patterns = {
      "/%.git/",
      "~$",
      "%.swp$",
      "%.swo$",
      "/4913$",   -- Vim temp file
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

---@type table[] Compiled entries parsed from .gitignore (see _gitignore_glob_to_pattern)
M._gitignore_patterns = {}

---@type string? Directory whose .gitignore is loaded (normalized, no trailing slash)
M._gitignore_root = nil

---@type string[] Negation patterns that were skipped
M._skipped_negations = {}

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

--- Compute path relative to root, or nil if path is not under root.
---@param path string Normalized absolute path (forward slashes)
---@param root string Root directory (any separators)
---@return string?
function M._relative_to(path, root)
  root = root:gsub("\\", "/"):gsub("/+$", "")
  if path == root then
    return ""
  end
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return nil
end

---@param path string Absolute path
---@param opts? { root?: string, is_dir?: boolean } root = watch root for
---  relative hidden-component checks; is_dir = path refers to a directory
---@return boolean
function M.should_ignore(path, opts)
  if not M._current then
    M.setup({})
  end
  opts = opts or {}

  local normalized = path:gsub("\\", "/")

  for _, pattern in ipairs(M._current.watch.ignore_patterns) do
    if normalized:match(pattern) then
      return true
    end
  end

  if not M._current.watch.watch_hidden then
    -- Check components relative to the watch root, so a project living under
    -- a hidden directory (e.g. ~/.config/foo) is not ignored wholesale
    local rel = opts.root and M._relative_to(normalized, opts.root)
    if rel then
      for component in rel:gmatch("[^/]+") do
        if component:sub(1, 1) == "." then
          return true
        end
      end
    else
      local basename = normalized:match("[^/]+$") or normalized
      if basename:sub(1, 1) == "." then
        return true
      end
    end
  end

  if M._gitignore_root and #M._gitignore_patterns > 0 then
    local rel = M._relative_to(normalized, M._gitignore_root)
    if rel and rel ~= "" then
      for _, entry in ipairs(M._gitignore_patterns) do
        if M._gitignore_matches(entry, rel, opts.is_dir) then
          return true
        end
      end
    end
  end

  -- include_patterns filter files only; directories must stay traversable
  if M._current.watch.include_patterns and not opts.is_dir then
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

--- Compile a gitignore glob into a matcher entry. Negation patterns are not
--- supported (skipped in load_gitignore). The compiled Lua patterns are
--- matched by _gitignore_matches against "/<relpath>/", so every pattern
--- starts and ends at a path component boundary.
---@param glob string
---@return table entry { glob, patterns, dir_only, anchored }
function M._gitignore_glob_to_pattern(glob)
  local pattern = glob:match("^%s*(.-)%s*$")

  local dir_only = pattern:sub(-1) == "/"
  if dir_only then
    pattern = pattern:sub(1, -2)
  end

  -- Leading "**/" means "at any depth" — same as a pattern with no slash
  local any_depth = pattern:sub(1, 3) == "**/"
  if any_depth then
    pattern = pattern:sub(4)
  end

  local anchored = false
  if pattern:sub(1, 1) == "/" then
    anchored = true
    pattern = pattern:sub(2)
  elseif not any_depth and pattern:find("/") then
    -- gitignore: a separator in the middle anchors the pattern to the root
    anchored = true
  end

  -- Preserve [...] before escaping other special chars; gitignore uses [!x]
  -- for negated classes where Lua uses [^x]
  local char_classes = {}
  pattern = pattern:gsub("%[(.-)%]", function(content)
    if content:sub(1, 1) == "!" then
      content = "^" .. content:sub(2)
    end
    table.insert(char_classes, content)
    return "\1" .. #char_classes .. "\1"
  end)

  pattern = pattern:gsub("([%.%+%-%^%$%(%)%%])", "%%%1")

  pattern = pattern:gsub("\1(%d+)\1", function(idx)
    return "[" .. char_classes[tonumber(idx)] .. "]"
  end)

  -- Convert glob wildcards via placeholders to avoid interference
  local Q, SEG, TAIL, DBL = "\2", "\3", "\4", "\5"
  pattern = pattern:gsub("%?", Q)
  pattern = pattern:gsub("/%*%*/", SEG)   -- a/**/b: zero or more directories
  pattern = pattern:gsub("/%*%*$", TAIL)  -- a/**: everything inside a
  pattern = pattern:gsub("%*%*", DBL)     -- bare **: any characters
  pattern = pattern:gsub("%*", "[^/]*")
  pattern = pattern:gsub(Q, "[^/]")
  pattern = pattern:gsub(DBL, ".*")

  -- "/**/" matches zero or more intermediate directories; Lua patterns have
  -- no alternation, so expand into one variant per case
  local bodies = { pattern }
  if pattern:find(SEG) then
    bodies = {
      (pattern:gsub(SEG, "/")),
      (pattern:gsub(SEG, "/.-/")),
    }
  end

  local prefix = anchored and "^/" or "/"
  local patterns = {}
  for _, body in ipairs(bodies) do
    body = body:gsub(TAIL, "/.*")
    table.insert(patterns, prefix .. body .. "/")
  end

  return {
    glob = glob,
    patterns = patterns,
    dir_only = dir_only,
    anchored = anchored,
  }
end

--- Test a compiled gitignore entry against a root-relative path.
---@param entry table Entry from _gitignore_glob_to_pattern
---@param relpath string Path relative to the gitignore root ("/"-separated, no leading slash)
---@param is_dir? boolean Whether relpath refers to a directory
---@return boolean
function M._gitignore_matches(entry, relpath, is_dir)
  local candidate
  if entry.dir_only and not is_dir then
    -- Directory-only patterns can only match ancestor directories of a file
    local parent = relpath:match("^(.*)/[^/]*$")
    if not parent then
      return false
    end
    candidate = "/" .. parent .. "/"
  else
    candidate = "/" .. relpath .. "/"
  end

  for _, pat in ipairs(entry.patterns) do
    if candidate:find(pat) then
      return true
    end
  end
  return false
end

--- Path of the currently relevant .gitignore (for hot-reload), or nil.
---@return string?
function M.gitignore_path()
  if not M._current or not M._current.watch.use_gitignore then
    return nil
  end
  return M._gitignore_root and (M._gitignore_root .. "/.gitignore") or nil
end

--- Re-read the .gitignore last loaded via load_gitignore.
function M.reload_gitignore()
  if M._gitignore_root then
    M.load_gitignore(M._gitignore_root)
  end
end

---@param dir string Directory containing .gitignore
function M.load_gitignore(dir)
  if not M._current then
    M.setup({})
  end

  M._gitignore_patterns = {}
  M._skipped_negations = {}
  M._gitignore_root = nil

  if not M._current.watch.use_gitignore then
    return
  end

  M._gitignore_root = dir:gsub("\\", "/"):gsub("/+$", "")

  local gitignore_path = M._gitignore_root .. "/.gitignore"
  local file = io.open(gitignore_path, "r")
  if not file then
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
