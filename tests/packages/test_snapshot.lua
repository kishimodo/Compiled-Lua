-- tests/packages/test_snapshot.lua : snapshot/golden serialization + match.
-- Determinism: the heavy lifting is snapshot.serialize() which is pure (no I/O,
-- no time, keys sorted). The match() path touches the filesystem, so we point
-- it at a private temp dir and DELETE any prior store first, making every run
-- (JIT and interpreter) take the identical "created" branch. Output is fixed.
local ok_req, snapshot = pcall(require, "snapshot")
if not ok_req then
    print("[~] SKIP test_snapshot (" .. tostring(snapshot) .. ")")
    os.exit(0)
end

local fails = 0
local function ok(c, m)
    if not c then fails = fails + 1; print("[-] FAIL test_snapshot: " .. tostring(m)) end
end

-- ===== serialize: lua_repr (default) =====
ok(snapshot.serialize(nil) == "nil", "lua_repr nil")
ok(snapshot.serialize(true) == "true", "lua_repr true")
ok(snapshot.serialize(false) == "false", "lua_repr false")
ok(snapshot.serialize(42) == "42", "lua_repr integer")
ok(snapshot.serialize(0/0) == "0/0", "lua_repr NaN")
ok(snapshot.serialize(math.huge) == "math.huge", "lua_repr +inf")
ok(snapshot.serialize(-math.huge) == "-math.huge", "lua_repr -inf")
ok(snapshot.serialize("hi") == '"hi"', "lua_repr string quoted")
ok(snapshot.serialize({}) == "{}", "lua_repr empty table")

-- array table: each element on its own indented line
local arr_repr = snapshot.serialize({ 1, 2, 3 })
ok(arr_repr == "{\n  1,\n  2,\n  3,\n}", "lua_repr array layout")

-- map table: keys are sorted for determinism
local map_repr = snapshot.serialize({ b = 2, a = 1 })
ok(map_repr == "{\n  a = 1,\n  b = 2,\n}", "lua_repr sorts map keys")

-- cycle handling
local cyc = {}
cyc.self = cyc
local cyc_repr = snapshot.serialize(cyc)
ok(cyc_repr:find("<cycle>", 1, true) ~= nil, "lua_repr marks cycles")

-- ===== serialize: text =====
ok(snapshot.serialize("plain", "text") == "plain", "text passthrough string")
ok(snapshot.serialize(123, "text") == "123", "text tostring number")

-- ===== serialize: json =====
ok(snapshot.serialize(nil, "json") == "null", "json nil")
ok(snapshot.serialize(true, "json") == "true", "json true")
ok(snapshot.serialize(7, "json") == "7", "json number")
ok(snapshot.serialize("a\"b", "json") == '"a\\"b"', "json escapes quote")
ok(snapshot.serialize({ 1, 2, 3 }, "json") == "[1,2,3]", "json array")
ok(snapshot.serialize({ b = 2, a = 1 }, "json") == '{"a":1,"b":2}', "json sorts keys")
-- NaN/inf -> null in json
ok(snapshot.serialize(0/0, "json") == "null", "json NaN -> null")

-- ===== is_update_mode / update() toggle =====
snapshot.update(true)
ok(snapshot.is_update_mode() == true, "update(true) sets update mode")
snapshot.update(false)
ok(snapshot.is_update_mode() == false, "update(false) clears update mode")

-- ===== match() round trip in an isolated temp dir =====
-- Make every run identical: remove the store first so match() always takes the
-- "created" branch, then a second match with the same value returns ok (no diff).
local tmpdir = (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "/clua_snap_test/"
tmpdir = tmpdir:gsub("\\", "/")
snapshot.set_dir(tmpdir)
-- Force a stable test_file stem so the store filename is deterministic.
snapshot.set_test_file("snaptest.lua")
local store_path = tmpdir .. "snaptest.snap.lua"
os.remove(store_path)

local r1 = snapshot.match({ x = 1, y = "two" }, "case1")
ok(type(r1) == "table" and r1.ok == true, "match returns ok table")
ok(r1.created == true, "first match creates snapshot")
ok(r1.name == "case1", "match echoes name")

-- Second match with the SAME value must succeed (matches stored snapshot).
local r2 = snapshot.match({ x = 1, y = "two" }, "case1")
ok(r2.ok == true, "re-match same value ok")
ok(r2.created == nil, "re-match does not re-create")

-- Mismatch must raise (different value, not in update mode).
local raised = not pcall(function()
    snapshot.match({ x = 2, y = "two" }, "case1")
end)
ok(raised, "match raises on mismatch")

-- With update=true the mismatch is absorbed.
local r3 = snapshot.match({ x = 2, y = "two" }, "case1", { update = true })
ok(r3.ok == true and r3.updated == true, "update=true overwrites snapshot")

-- Clean up the store so we don't leave artifacts / affect determinism.
os.remove(store_path)

if fails == 0 then print("[+] PASS test_snapshot") os.exit(0) else os.exit(1) end
