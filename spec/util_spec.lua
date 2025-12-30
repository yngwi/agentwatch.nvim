require("spec.helpers.setup")

local util = require("agentwatch.util")

describe("util", function()

  describe("normalize_path", function()
    it("converts backslashes to forward slashes", function()
      assert.equals("foo/bar/baz", util.normalize_path("foo\\bar\\baz"))
    end)

    it("handles mixed separators", function()
      assert.equals("foo/bar/baz", util.normalize_path("foo/bar\\baz"))
    end)

    it("removes trailing slash", function()
      assert.equals("foo/bar", util.normalize_path("foo/bar/"))
    end)

    it("removes trailing backslash", function()
      assert.equals("foo/bar", util.normalize_path("foo\\bar\\"))
    end)

    it("handles empty string", function()
      assert.equals("", util.normalize_path(""))
    end)

    it("handles single component", function()
      assert.equals("foo", util.normalize_path("foo"))
    end)

    it("preserves Windows drive letter", function()
      assert.equals("C:/Users/test", util.normalize_path("C:\\Users\\test"))
    end)

    it("handles UNC path", function()
      assert.equals("//server/share/file", util.normalize_path("\\\\server\\share\\file"))
    end)
  end)

  describe("is_absolute", function()
    -- Windows paths
    it("recognizes Windows drive path", function()
      assert.is_true(util.is_absolute("C:\\Users\\test"))
    end)

    it("recognizes Windows drive path with forward slash", function()
      assert.is_true(util.is_absolute("C:/Users/test"))
    end)

    it("recognizes UNC path", function()
      assert.is_true(util.is_absolute("\\\\server\\share"))
    end)

    it("recognizes UNC path with forward slashes", function()
      assert.is_true(util.is_absolute("//server/share"))
    end)

    -- Unix paths
    it("recognizes Unix absolute path", function()
      assert.is_true(util.is_absolute("/home/user"))
    end)

    it("recognizes Unix root", function()
      assert.is_true(util.is_absolute("/"))
    end)

    -- Relative paths
    it("rejects relative path", function()
      assert.is_false(util.is_absolute("foo/bar"))
    end)

    it("rejects dot-relative path", function()
      assert.is_false(util.is_absolute("./foo"))
    end)

    it("rejects parent-relative path", function()
      assert.is_false(util.is_absolute("../foo"))
    end)

    it("rejects empty string", function()
      assert.is_false(util.is_absolute(""))
    end)
  end)

  describe("join_path", function()
    it("joins two components", function()
      assert.equals("foo/bar", util.join_path("foo", "bar"))
    end)

    it("joins multiple components", function()
      assert.equals("foo/bar/baz", util.join_path("foo", "bar", "baz"))
    end)

    it("normalizes double slashes", function()
      assert.equals("foo/bar", util.join_path("foo/", "/bar"))
    end)

    it("normalizes mixed separators", function()
      assert.equals("foo/bar/baz", util.join_path("foo\\", "bar/baz"))
    end)

    it("handles single component", function()
      assert.equals("foo", util.join_path("foo"))
    end)
  end)

end)
