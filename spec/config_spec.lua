require("spec.helpers.setup")

local config = require("agentwatch.config")

--- Compile a gitignore glob and test it against a root-relative path.
---@param glob string
---@param relpath string
---@param is_dir? boolean
---@return boolean
local function matches(glob, relpath, is_dir)
  local entry = config._gitignore_glob_to_pattern(glob)
  return config._gitignore_matches(entry, relpath, is_dir)
end

describe("config", function()

  describe("gitignore matching", function()

    describe("simple patterns", function()
      it("matches literal filename at any depth", function()
        assert.is_true(matches("foo.txt", "foo.txt"))
        assert.is_true(matches("foo.txt", "a/b/foo.txt"))
        assert.is_false(matches("foo.txt", "bar.txt"))
      end)

      it("matches only whole path components", function()
        -- "config.lua" must not ignore "myconfig.lua"
        assert.is_false(matches("config.lua", "myconfig.lua"))
        assert.is_false(matches("config.lua", "a/myconfig.lua"))
        assert.is_true(matches("config.lua", "a/config.lua"))
      end)

      it("escapes dots", function()
        assert.is_true(matches("init.lua", "init.lua"))
        assert.is_false(matches("init.lua", "initXlua"))
      end)

      it("trims whitespace", function()
        assert.is_true(matches("  foo.txt  ", "foo.txt"))
      end)

      it("matches files inside a matched directory", function()
        assert.is_true(matches("node_modules", "node_modules/react/index.js"))
        assert.is_true(matches("__pycache__", "src/__pycache__/module.pyc"))
        assert.is_false(matches("node_modules", "node_modules_backup/file.js"))
      end)
    end)

    describe("single star (*)", function()
      it("matches wildcard in filename at any depth", function()
        assert.is_true(matches("*.log", "debug.log"))
        assert.is_true(matches("*.log", "logs/debug.log"))
        assert.is_false(matches("*.log", "log"))
      end)

      it("does not match across slashes", function()
        assert.is_true(matches("log*.txt", "logfile.txt"))
        assert.is_false(matches("log*.txt", "log/file.txt"))
      end)
    end)

    describe("double star (**)", function()
      it("matches any directory depth with **/", function()
        assert.is_true(matches("**/logs", "logs"))
        assert.is_true(matches("**/logs", "foo/logs"))
        assert.is_true(matches("**/logs", "foo/bar/logs/x.txt"))
        assert.is_false(matches("**/logs", "mylogs/x.txt"))
      end)

      it("matches contents with /**", function()
        assert.is_true(matches("logs/**", "logs/debug.log"))
        assert.is_true(matches("logs/**", "logs/foo/bar.log"))
        assert.is_false(matches("logs/**", "logs", true))
        assert.is_false(matches("logs/**", "other/debug.log"))
      end)

      it("matches zero or more directories with a/**/b", function()
        assert.is_true(matches("a/**/b", "a/b"))
        assert.is_true(matches("a/**/b", "a/x/b"))
        assert.is_true(matches("a/**/b", "a/x/y/b"))
        assert.is_false(matches("a/**/b", "a/xb"))
      end)
    end)

    describe("question mark (?)", function()
      it("matches exactly one character", function()
        assert.is_true(matches("debug?.log", "debug1.log"))
        assert.is_true(matches("debug?.log", "debuga.log"))
        assert.is_false(matches("debug?.log", "debug.log"))
        assert.is_false(matches("debug?.log", "debug12.log"))
      end)

      it("does not match path separator", function()
        assert.is_false(matches("debug?.log", "debug/.log"))
      end)
    end)

    describe("leading slash (anchored)", function()
      it("anchors pattern to root", function()
        assert.is_true(matches("/build", "build"))
        assert.is_true(matches("/build", "build/out.js"))
        assert.is_false(matches("/build", "foo/build"))
        assert.is_false(matches("/build", "foo/build/out.js"))
      end)

      it("works with wildcards", function()
        assert.is_true(matches("/*.log", "debug.log"))
        assert.is_false(matches("/*.log", "foo/debug.log"))
      end)
    end)

    describe("middle slash (anchored)", function()
      it("anchors pattern with interior separator to root", function()
        assert.is_true(matches("doc/*.md", "doc/readme.md"))
        assert.is_false(matches("doc/*.md", "sub/doc/readme.md"))
      end)
    end)

    describe("trailing slash (directory only)", function()
      it("matches directories and their contents", function()
        assert.is_true(matches("build/", "foo/build/bar.js"))
        assert.is_true(matches("build/", "build/file.txt"))
        assert.is_true(matches("build/", "build", true))
        assert.is_false(matches("build/", "build_backup/file.txt"))
      end)

      it("does not match a plain file of that name", function()
        assert.is_false(matches("build/", "build"))
        assert.is_false(matches("build/", "foo/build"))
      end)

      it("matches dist directory contents", function()
        assert.is_true(matches("dist/", "foo/dist/bundle.js"))
        assert.is_true(matches("dist/", "dist/index.js"))
      end)
    end)

    describe("character classes", function()
      it("preserves [0-9] range", function()
        assert.is_true(matches("report.[0-9]*.json", "report.1.json"))
        assert.is_true(matches("report.[0-9]*.json", "report.123.json"))
        assert.is_false(matches("report.[0-9]*.json", "report.abc.json"))
      end)

      it("preserves [a-z] range", function()
        assert.is_true(matches("file_[a-z].txt", "file_a.txt"))
        assert.is_false(matches("file_[a-z].txt", "file_1.txt"))
      end)

      it("supports gitignore negated classes [!...]", function()
        assert.is_true(matches("file_[!0-9].txt", "file_a.txt"))
        assert.is_false(matches("file_[!0-9].txt", "file_1.txt"))
      end)

      it("handles multiple character classes", function()
        assert.is_true(matches("[a-z][0-9].log", "a1.log"))
        assert.is_false(matches("[a-z][0-9].log", "11.log"))
      end)
    end)

    describe("common gitignore patterns", function()
      it("matches .env files", function()
        assert.is_true(matches(".env*", ".env"))
        assert.is_true(matches(".env*", ".env.local"))
        assert.is_true(matches(".env*", "config/.env.production"))
      end)

      it("matches *.pyc files", function()
        assert.is_true(matches("*.pyc", "module.pyc"))
        assert.is_true(matches("*.pyc", "src/module.pyc"))
      end)
    end)

  end)

  describe("should_ignore with gitignore", function()
    local function with_gitignore(root, globs, fn)
      config.setup({})
      config._gitignore_root = root
      local entries = {}
      for _, glob in ipairs(globs) do
        table.insert(entries, config._gitignore_glob_to_pattern(glob))
      end
      config._gitignore_patterns = entries
      fn()
      config._gitignore_patterns = {}
      config._gitignore_root = nil
    end

    it("applies anchored patterns relative to the gitignore root", function()
      with_gitignore("/home/user/proj", { "/dist" }, function()
        assert.is_true(config.should_ignore("/home/user/proj/dist/out.js"))
        assert.is_false(config.should_ignore("/home/user/proj/src/dist.js"))
        assert.is_false(config.should_ignore("/home/user/proj/sub/dist/out.js"))
      end)
    end)

    it("does not ignore near-miss filenames", function()
      with_gitignore("/home/user/proj", { "config.lua" }, function()
        assert.is_true(config.should_ignore("/home/user/proj/config.lua"))
        assert.is_false(config.should_ignore("/home/user/proj/myconfig.lua"))
      end)
    end)

    it("ignores files under hidden directories relative to the root", function()
      config.setup({})
      assert.is_true(config.should_ignore("/proj/.cache/foo.txt", { root = "/proj" }))
      assert.is_false(config.should_ignore("/proj/src/foo.txt", { root = "/proj" }))
    end)

    it("does not ignore a project that lives under a hidden directory", function()
      config.setup({})
      assert.is_false(config.should_ignore("/home/u/.config/proj/foo.txt", { root = "/home/u/.config/proj" }))
    end)
  end)

end)
