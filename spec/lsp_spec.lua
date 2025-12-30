require("spec.helpers.setup")

local lsp = require("agentwatch.lsp")

describe("lsp", function()

  describe("_glob_to_pattern", function()

    describe("literal matching", function()
      it("matches literal string", function()
        local pattern = lsp._glob_to_pattern("foo")
        assert.is_truthy(("foo"):match(pattern))
      end)

      it("escapes dots", function()
        local pattern = lsp._glob_to_pattern("init.lua")
        assert.is_truthy(("init.lua"):match(pattern))
        assert.is_falsy(("initXlua"):match(pattern))
      end)

      it("escapes other special chars", function()
        local pattern = lsp._glob_to_pattern("file(1).txt")
        assert.is_truthy(("file(1).txt"):match(pattern))
      end)
    end)

    describe("single star (*)", function()
      it("matches filename wildcard", function()
        local pattern = lsp._glob_to_pattern("*.lua")
        assert.is_truthy(("init.lua"):match(pattern))
        assert.is_truthy(("test.lua"):match(pattern))
      end)

      it("does not match across path separators", function()
        local pattern = lsp._glob_to_pattern("*.lua")
        -- * should not match the slash in "foo/bar.lua"
        assert.is_falsy(("foo/bar.lua"):match("^" .. pattern .. "$"))
      end)

      it("matches prefix wildcard", function()
        local pattern = lsp._glob_to_pattern("test_*")
        assert.is_truthy(("test_foo"):match(pattern))
        assert.is_truthy(("test_"):match(pattern))
      end)
    end)

    describe("double star (**)", function()
      it("matches any path depth", function()
        local pattern = lsp._glob_to_pattern("**/*.lua")
        assert.is_truthy(("foo/bar.lua"):match(pattern))
        assert.is_truthy(("foo/bar/baz.lua"):match(pattern))
        assert.is_truthy(("bar.lua"):match(pattern))
      end)

      it("matches at start of pattern", function()
        local pattern = lsp._glob_to_pattern("**/test.lua")
        assert.is_truthy(("test.lua"):match(pattern))
        assert.is_truthy(("foo/test.lua"):match(pattern))
        assert.is_truthy(("foo/bar/test.lua"):match(pattern))
      end)
    end)

    describe("question mark (?)", function()
      it("matches single character", function()
        local pattern = lsp._glob_to_pattern("file?.txt")
        assert.is_truthy(("file1.txt"):match(pattern))
        assert.is_truthy(("fileA.txt"):match(pattern))
      end)

      it("requires exactly one character", function()
        local pattern = lsp._glob_to_pattern("file?.txt")
        assert.is_falsy(("file.txt"):match("^" .. pattern .. "$"))
        assert.is_falsy(("file12.txt"):match("^" .. pattern .. "$"))
      end)
    end)

  end)

  describe("_glob_to_pattern cross-platform", function()
    it("matches paths with forward slashes", function()
      local pattern = lsp._glob_to_pattern("**/*.lua")
      assert.is_truthy(("src/foo/bar.lua"):match(pattern))
    end)

    it("matches paths with backslashes", function()
      local pattern = lsp._glob_to_pattern("**/*.lua")
      assert.is_truthy(("src\\foo\\bar.lua"):match(pattern))
    end)

    it("matches mixed separators", function()
      local pattern = lsp._glob_to_pattern("**/*.lua")
      assert.is_truthy(("src/foo\\bar.lua"):match(pattern))
    end)

    it("single star doesn't cross backslash", function()
      local pattern = lsp._glob_to_pattern("*.lua")
      assert.is_falsy(("foo\\bar.lua"):match("^" .. pattern .. "$"))
    end)

    it("handles Windows absolute path", function()
      local pattern = lsp._glob_to_pattern("**/*.lua")
      -- After normalization, C:\Users\test.lua would typically be checked
      assert.is_truthy(("C:/Users/test.lua"):match(pattern))
    end)
  end)

  describe("_parse_watch_patterns", function()
    it("returns empty table for nil input", function()
      local patterns = lsp._parse_watch_patterns(nil)
      assert.same({}, patterns)
    end)

    it("returns empty table for empty watchers", function()
      local patterns = lsp._parse_watch_patterns({ watchers = {} })
      assert.same({}, patterns)
    end)

    it("extracts string glob patterns", function()
      local patterns = lsp._parse_watch_patterns({
        watchers = {
          { globPattern = "**/*.lua" },
          { globPattern = "**/*.vim" },
        }
      })
      assert.same({ "**/*.lua", "**/*.vim" }, patterns)
    end)

    it("extracts relative pattern objects", function()
      local patterns = lsp._parse_watch_patterns({
        watchers = {
          { globPattern = { baseUri = "/foo", pattern = "**/*.ts" } },
        }
      })
      assert.same({ "**/*.ts" }, patterns)
    end)

    it("handles mixed pattern types", function()
      local patterns = lsp._parse_watch_patterns({
        watchers = {
          { globPattern = "*.lua" },
          { globPattern = { pattern = "*.ts" } },
        }
      })
      assert.same({ "*.lua", "*.ts" }, patterns)
    end)
  end)

end)
