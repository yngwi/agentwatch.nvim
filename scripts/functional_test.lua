-- End-to-end functional suite (real fs events, both backends).
-- Usage (from the repo root):  nvim --headless --clean -u NORC -l scripts/functional_test.lua
-- Exits non-zero on failure.
local SCRATCH = vim.fn.tempname()
vim.fn.mkdir(SCRATCH, "p")
local results, fails = {}, 0

local function check(name, cond, detail)
  results[#results + 1] = string.format("%s %s%s", cond and "PASS" or "FAIL", name, detail and (" [" .. tostring(detail) .. "]") or "")
  if not cond then fails = fails + 1 end
end

local function ext_write(path, content)
  os.execute(string.format("sh -c 'printf \"%%s\\n\" \"%s\" > \"%s\"'", content, path))
end

local function wait_for(cond, ms)
  return vim.wait(ms or 2000, cond, 25)
end

local function settle(ms)
  vim.wait(ms or 400, function() return false end, 50)
end

vim.opt.runtimepath:prepend(vim.fn.getcwd())

------------------------------------------------------------------ Section A: recursive backend
local A = SCRATCH .. "/projA"
vim.fn.delete(A, "rf")
vim.fn.mkdir(A .. "/subdir", "p")
vim.fn.mkdir(A .. "/dist", "p")
vim.fn.writefile({ "/dist", "config.lua" }, A .. "/.gitignore")
vim.fn.writefile({ "root v1" }, A .. "/root.txt")
vim.fn.writefile({ "nested v1" }, A .. "/subdir/nested.txt")
vim.fn.writefile({ "ignored v1" }, A .. "/dist/out.js")
vim.fn.writefile({ "near v1" }, A .. "/myconfig.lua")
vim.cmd("cd " .. A)

require("agentwatch").setup({ watch = { debounce_ms = 50, stability_ms = 20 } })

local notified = {}
require("agentwatch").on("lsp_notify", function(d) notified[#notified + 1] = d end)

vim.cmd("edit " .. A .. "/subdir/nested.txt")
vim.cmd("edit " .. A .. "/root.txt")

check("A0 backend is recursive on macOS", require("agentwatch.watcher")._backend == "recursive")

-- current buffer reload
ext_write(A .. "/root.txt", "root v2")
wait_for(function() return vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "root v2" end)
check("A1 current buffer reloads", vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "root v2")

-- background subdir buffer reload
local nested_buf = vim.fn.bufnr(A .. "/subdir/nested.txt")
ext_write(A .. "/subdir/nested.txt", "nested v2")
wait_for(function() return vim.api.nvim_buf_get_lines(nested_buf, 0, -1, false)[1] == "nested v2" end)
check("A2 background subdir buffer reloads", vim.api.nvim_buf_get_lines(nested_buf, 0, -1, false)[1] == "nested v2")
check("A3 background buffer not marked modified", vim.bo[nested_buf].modified == false)

-- gitignore end-to-end: anchored /dist and boundary
local n_before = #notified
ext_write(A .. "/dist/out.js", "ignored v2")
ext_write(A .. "/myconfig.lua", "near v2")
settle(600)
local dist_seen, near_seen = false, false
for i = n_before + 1, #notified do
  if notified[i].filepath:find("dist/out%.js") then dist_seen = true end
  if notified[i].filepath:find("myconfig%.lua") then near_seen = true end
end
check("A4 anchored /dist gitignore entry is honored", not dist_seen)
check("A5 near-miss myconfig.lua is NOT ignored by config.lua entry", near_seen)

-- conflict: local edit + external write -> keep buffer
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local edit" })
ext_write(A .. "/root.txt", "root v3")
settle(600)
check("A6 conflicting buffer kept", vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "local edit")
check("A7 conflicting buffer still modified", vim.bo[0].modified == true)

-- pause: neither agentwatch nor vim's autoread may reload
vim.bo[0].modified = false
require("agentwatch").pause()
ext_write(A .. "/root.txt", "root v4")
settle(800)
vim.cmd("silent! checktime")  -- force vim's own timestamp check while paused
settle(200)
check("A8 paused: buffer untouched despite checktime", vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "local edit")
check("A9 paused: events queued", require("agentwatch").status().queued_events >= 1)
require("agentwatch").resume()
wait_for(function() return vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "root v4" end)
check("A10 resume applies queued change", vim.api.nvim_buf_get_lines(0, 0, -1, false)[1] == "root v4")

------------------------------------------------------------------ Section B: checktime suppression after background sync
-- With 'autoread' set, Vim bypasses FileChangedShell entirely and its
-- redundant same-content reload is benign. The interceptable case is
-- 'noautoread', where stock Vim would show a W11 warning/dialog.
vim.o.autoread = false
local fcs_choice_seen = nil
vim.api.nvim_create_autocmd("FileChangedShell", {
  callback = function(ev)
    if ev.file:find("nested") then fcs_choice_seen = vim.v.fcs_choice end
  end,
})
ext_write(A .. "/subdir/nested.txt", "nested v3")
wait_for(function() return vim.api.nvim_buf_get_lines(nested_buf, 0, -1, false)[1] == "nested v3" end)
vim.cmd("silent! checktime")
settle(200)
check("B1 background sync content correct", vim.api.nvim_buf_get_lines(nested_buf, 0, -1, false)[1] == "nested v3")
-- Vim compares contents on checktime: an already-synced buffer is adopted
-- silently (no FileChangedShell, no W11, no reload)
check("B2 checktime after background sync is silent", fcs_choice_seen == nil, fcs_choice_seen)
check("B3 buffer content intact", vim.api.nvim_buf_get_lines(nested_buf, 0, -1, false)[1] == "nested v3")
vim.o.autoread = true

------------------------------------------------------------------ Section C: AgentwatchReload teardown
local old_watcher = require("agentwatch.watcher")
local old_handle_count = vim.tbl_count(old_watcher._handles)
vim.cmd("AgentwatchReload")
settle(100)
local new_watcher = require("agentwatch.watcher")
check("C1 reload swapped module", new_watcher ~= old_watcher)
check("C2 old watcher handles released", vim.tbl_count(old_watcher._handles) == 0, vim.tbl_count(old_watcher._handles))
check("C3 new watcher active", vim.tbl_count(new_watcher._handles) >= 1)
-- events must not double-process after reload
notified = {}
require("agentwatch").on("lsp_notify", function(d) notified[#notified + 1] = d end)
ext_write(A .. "/root.txt", "root v5")
wait_for(function() return #notified >= 1 end)
settle(500)
local root_events = 0
for _, d in ipairs(notified) do
  if d.filepath:find("root%.txt") then root_events = root_events + 1 end
end
check("C4 exactly one event after reload (no orphans)", root_events == 1, root_events)

------------------------------------------------------------------ Section D: vanished file no longer loops
local watcher = require("agentwatch.watcher")
local stability_calls = 0
local orig_check = watcher._check_stability
watcher._check_stability = function(fp, cb)
  stability_calls = stability_calls + 1
  return orig_check(fp, cb)
end
notified = {}
watcher._process_after_stability(A .. "/ghost.txt", 2)
settle(1000)
watcher._check_stability = orig_check
local ghost_delete = false
for _, d in ipairs(notified) do
  if d.filepath:find("ghost") and d.change_type == 3 then ghost_delete = true end
end
check("D1 vanished file: single stability check", stability_calls == 1, stability_calls)
check("D2 vanished file: reported as deletion", ghost_delete)
check("D3 no lingering debounce timers", vim.tbl_count(watcher._debounce_timers) == 0, vim.tbl_count(watcher._debounce_timers))

------------------------------------------------------------------ Section E: LSP registration handling
local forwarded = {}
require("agentwatch.lsp").teardown()
vim.lsp.handlers["client/registerCapability"] = function(_, result)
  forwarded[#forwarded + 1] = vim.deepcopy(result.registrations)
  return vim.NIL
end
require("agentwatch.config").setup({ lsp = { mode = "replace" }, watch = { debounce_ms = 50, stability_ms = 20 } })
require("agentwatch.lsp").setup_capability_tracking()

local reg = {
  registrations = {
    { id = "w1", method = "workspace/didChangeWatchedFiles",
      registerOptions = { watchers = { { globPattern = "**/*.lua" } } } },
    { id = "o1", method = "workspace/didChangeConfiguration" },
  },
}
vim.lsp.handlers["client/registerCapability"](nil, vim.deepcopy(reg), { client_id = 42 })
local lspmod = require("agentwatch.lsp")
check("E1 replace: watcher registration recorded", lspmod._registered_watchers[42] ~= nil)
check("E2 replace: watch registration NOT forwarded to built-in",
  #forwarded == 1 and #forwarded[1] == 1 and forwarded[1][1].method == "workspace/didChangeConfiguration")

vim.lsp.handlers["client/unregisterCapability"](nil,
  { unregisterations = { { id = "w1", method = "workspace/didChangeWatchedFiles" } } },
  { client_id = 42 })
check("E3 unregister clears recorded watcher", lspmod._registered_watchers[42] == nil)

require("agentwatch.config").setup({ lsp = { mode = "complement" }, watch = { debounce_ms = 50, stability_ms = 20 } })
forwarded = {}
vim.lsp.handlers["client/registerCapability"](nil, vim.deepcopy(reg), { client_id = 43 })
check("E4 complement: registration forwarded untouched", #forwarded == 1 and #forwarded[1] == 2)
check("E5 complement: registration also recorded", lspmod._registered_watchers[43] ~= nil)

------------------------------------------------------------------ Section F: walk backend (Linux simulation)
local F = SCRATCH .. "/projF"
vim.fn.delete(F, "rf")
vim.fn.mkdir(F .. "/sub/deep", "p")
vim.fn.mkdir(F .. "/node_modules/pkg", "p")
vim.fn.writefile({ "node_modules" }, F .. "/.gitignore")
vim.fn.writefile({ "deep v1" }, F .. "/sub/deep/file.txt")
vim.fn.writefile({ "dep v1" }, F .. "/node_modules/pkg/index.js")
vim.cmd("cd " .. F)

require("agentwatch.config").setup({ watch = { backend = "walk", debounce_ms = 50, stability_ms = 20 } })
require("agentwatch.config").load_gitignore(F)
require("agentwatch.watcher").update_paths({ F })
local wtr = require("agentwatch.watcher")
check("F1 walk backend selected", wtr._backend == "walk")
check("F2 watches root + sub + sub/deep, not node_modules",
  wtr._handles[F] ~= nil and wtr._handles[F .. "/sub"] ~= nil and wtr._handles[F .. "/sub/deep"] ~= nil
    and wtr._handles[F .. "/node_modules"] == nil and wtr._handles[F .. "/node_modules/pkg"] == nil,
  vim.tbl_count(wtr._handles))

notified = {}
ext_write(F .. "/sub/deep/file.txt", "deep v2")
wait_for(function() return #notified >= 1 end)
local deep_seen = false
for _, d in ipairs(notified) do
  if d.filepath:find("deep/file%.txt") then deep_seen = true end
end
check("F3 event from nested subdirectory", deep_seen)

-- new directory created at runtime gets adopted (git checkout scenario)
notified = {}
os.execute(string.format("sh -c 'mkdir -p \"%s/newdir/inner\" && printf \"born\\n\" > \"%s/newdir/inner/born.txt\"'", F, F))
wait_for(function() return #notified >= 1 end, 3000)
local born_seen = false
for _, d in ipairs(notified) do
  if d.filepath:find("born%.txt") then born_seen = true end
end
check("F4 files in newly created directories reported", born_seen)
check("F5 new directories watched", wtr._handles[F .. "/newdir"] ~= nil and wtr._handles[F .. "/newdir/inner"] ~= nil)

-- and changes inside the adopted directory keep flowing
notified = {}
ext_write(F .. "/newdir/inner/born.txt", "changed")
wait_for(function() return #notified >= 1 end, 3000)
local born_change = false
for _, d in ipairs(notified) do
  if d.filepath:find("born%.txt") then born_change = true end
end
check("F6 events flow from adopted directory", born_change)

-- ignored directory stays silent
notified = {}
ext_write(F .. "/node_modules/pkg/index.js", "dep v2")
settle(600)
local dep_seen = false
for _, d in ipairs(notified) do
  if d.filepath:find("node_modules") then dep_seen = true end
end
check("F7 gitignored directory produces no events", not dep_seen)

-- .gitignore hot reload
vim.fn.writefile({ "node_modules", "hot.txt" }, F .. "/.gitignore")
settle(600)
notified = {}
ext_write(F .. "/hot.txt", "should be ignored")
settle(600)
local hot_seen = false
for _, d in ipairs(notified) do
  if d.filepath:find("hot%.txt") then hot_seen = true end
end
check("F8 .gitignore changes hot-reload ignore rules", not hot_seen)

------------------------------------------------------------------
print(table.concat(results, "\n"))
print(string.format("== %d checks, %d failed ==", #results, fails))
vim.cmd((fails == 0) and "qa!" or "cq!")
