-- Minimal busted-compatible runner for the unit specs in spec/.
-- Usage (from the repo root):  luajit scripts/run_specs.lua
-- (any Lua 5.1+ interpreter works; busted itself works too if installed)
package.path = "./?.lua;./?/init.lua;" .. package.path

local names = {}
local passed, failed = 0, 0
local failures = {}

_G.describe = function(name, fn)
  table.insert(names, name)
  fn()
  table.remove(names)
end

_G.it = function(name, fn)
  table.insert(names, name)
  local label = table.concat(names, " > ")
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    table.insert(failures, label .. "\n    " .. tostring(err))
  end
  table.remove(names)
end

local function deep_equal(a, b)
  if a == b then return true end
  if type(a) ~= "table" or type(b) ~= "table" then return false end
  for k, v in pairs(a) do
    if not deep_equal(v, b[k]) then return false end
  end
  for k in pairs(b) do
    if a[k] == nil then return false end
  end
  return true
end

local function fmt(v)
  if type(v) == "table" then
    local parts = {}
    for k, val in pairs(v) do
      table.insert(parts, tostring(k) .. "=" .. fmt(val))
    end
    return "{" .. table.concat(parts, ", ") .. "}"
  end
  return tostring(v)
end

local asserts = {
  is_truthy = function(v) if not v then error("expected truthy, got " .. fmt(v), 2) end end,
  is_falsy = function(v) if v then error("expected falsy, got " .. fmt(v), 2) end end,
  is_true = function(v) if v ~= true then error("expected true, got " .. fmt(v), 2) end end,
  is_false = function(v) if v ~= false then error("expected false, got " .. fmt(v), 2) end end,
  equals = function(exp, act)
    if exp ~= act then error("expected " .. fmt(exp) .. ", got " .. fmt(act), 2) end
  end,
  same = function(exp, act)
    if not deep_equal(exp, act) then error("expected " .. fmt(exp) .. ", got " .. fmt(act), 2) end
  end,
}
asserts.are = { same = asserts.same, equal = asserts.equals, equals = asserts.equals }
_G.assert = setmetatable(asserts, {
  __call = function(_, v, msg) if not v then error(msg or "assertion failed!", 2) end return v end,
})

for _, spec in ipairs({ "spec/util_spec.lua", "spec/lsp_spec.lua", "spec/config_spec.lua" }) do
  dofile(spec)
end

print(string.format("%d passed, %d failed", passed, failed))
for _, f in ipairs(failures) do
  print("FAIL: " .. f)
end
os.exit(failed == 0 and 0 or 1)
