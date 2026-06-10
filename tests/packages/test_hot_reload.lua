-- tests/packages/test_hot_reload.lua : module hot-swap.
-- Determinism: we never assert real mtimes/timestamps. We exercise the
-- watch/unwatch/list bookkeeping, listener registration + error paths,
-- with_state persistence, and the in-place table-patch reload behavior using
-- a synthetic module injected directly into package.loaded (no filesystem).
local ok_req, hot = pcall(require, "hot_reload")
if not ok_req then print("[~] SKIP test_hot_reload (" .. tostring(hot) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_hot_reload: " .. tostring(m)) end end

-- ---- on(): unknown event errors; known events accept listeners ----
ok(not pcall(hot.on, "no-such-event", function() end), "on() errors on an unknown event")
ok(pcall(hot.on, "reload", function() end),            "on('reload', fn) is accepted")

-- ---- with_state(): a value survives across reloads (just get/set here) ----
local get, set = hot.with_state("counter")
ok(get() == nil, "with_state value starts nil")
set(41)
ok(get() == 41,  "with_state set/get round-trips")
local get2 = (hot.with_state("counter"))
ok(get2() == 41, "with_state value is keyed and shared across handles")

-- ---- watch a real file path so module_to_path isn't needed ----
-- Use this very test file's source as a file-kind watch target (it exists).
local target_path = "tests/packages/test_hot_reload.lua"
local id = hot.watch(target_path)
ok(type(id) == "number", "watch returns a numeric id")

local listed = hot.list()
local found = nil
for _, e in ipairs(listed) do if e.file == target_path then found = e end end
ok(found ~= nil,                "list() includes the watched file")
ok(found and found.id == id,    "list() entry carries the watch id")
ok(found and found.target == target_path, "list() target equals the file path")

-- list() is sorted by id ascending (deterministic order).
local id2 = hot.watch("tests/packages/test_json.lua")
local l2 = hot.list()
local prev = -1
local ascending = true
for _, e in ipairs(l2) do if e.id < prev then ascending = false end prev = e.id end
ok(ascending, "list() is sorted by id ascending")

-- ---- unwatch by id removes the entry ----
hot.unwatch(id2)
local l3 = hot.list()
local still_there = false
for _, e in ipairs(l3) do if e.id == id2 then still_there = true end end
ok(not still_there, "unwatch(id) removes that entry from list()")

-- ---- reload() with in-place table patch preserves identity ----
-- Inject a synthetic module table directly into package.loaded, then point a
-- fake loader at it so reload() rebuilds and patches-in-place. We simulate the
-- "new version" by mutating the source the next require sees. Because we can't
-- easily swap a require source here, we instead directly verify patch behavior
-- through reload of a module that re-requires to the SAME table identity.
local mod_name = "__hot_reload_test_mod__"
local old_tbl = { value = 1, keep_me = "orig", removed = true }
package.loaded[mod_name] = old_tbl

-- Provide a package.preload entry that returns a *new* table on re-require.
package.preload[mod_name] = function()
    return { value = 2, keep_me = "orig", added = "new" }
end

local rok, newmod = hot.reload(mod_name)
ok(rok == true, "reload() of a preloaded module succeeds")
-- In-place patch: the ORIGINAL table object is mutated and re-published.
ok(package.loaded[mod_name] == old_tbl, "reload patches the old table in place (identity preserved)")
ok(old_tbl.value == 2,          "patched: updated key takes the new value")
ok(old_tbl.added == "new",      "patched: a new key is added")
ok(old_tbl.removed == nil,      "patched: a key absent in new is removed")
ok(newmod == old_tbl,           "reload returns the patched old table")

-- Clean up the synthetic module so it can't leak into other state.
package.loaded[mod_name] = nil
package.preload[mod_name] = nil

-- ---- reload() of a module whose require fails rolls back ----
local fail_name = "__hot_reload_fail_mod__"
local original = { ok = true }
package.loaded[fail_name] = original
package.preload[fail_name] = function() error("load failure") end
local fok, ferr = hot.reload(fail_name)
ok(fok == false,                          "reload returns false when require errors")
ok(package.loaded[fail_name] == original, "reload rolls back to the original on failure")
ok(tostring(ferr):find("load failure", 1, true) ~= nil, "reload surfaces the load error")
package.loaded[fail_name] = nil
package.preload[fail_name] = nil

if fails == 0 then print("[+] PASS test_hot_reload") os.exit(0) else os.exit(1) end
