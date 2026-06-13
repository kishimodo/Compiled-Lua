-- tests/packages/test_event.lua : Win32 kernel events (CreateEventW).
--
-- KNOWN BUG (FFI-HANDLE-ARRAY-INIT-001): every event constructor goes through
-- wrap(), which does ffi.new("HANDLE[1]", handle). In this CLua FFI,
-- initializing a pointer-array from a pointer cdata raises
-- "ffi.new init: ffi: cdata kind 4 does not match target kind 5", so even
-- event.manual()/event.auto() fail. We assert the API surface and XFAIL the
-- constructor; it flips to XPASS when ffi.new("HANDLE[1]", h) is fixed.
local ok_req, event = pcall(require, "event")
if not ok_req then print("[~] SKIP test_event (" .. tostring(event) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_event: " .. tostring(m)) end end
local function xfail(cond, desc, bug)
  if cond then print(("[!] XPASS test_event: %s -- bug %s appears FIXED, remove this xfail"):format(desc, bug))
  else        print(("[x] XFAIL test_event: %s (known bug %s)"):format(desc, bug)) end
end

-- ===== API surface present =====
ok(type(event.manual) == "function",   "event.manual present")
ok(type(event.auto) == "function",     "event.auto present")
ok(type(event.named) == "function",    "event.named present")
ok(type(event.open) == "function",     "event.open present")
ok(type(event.wait_any) == "function", "event.wait_any present")
ok(type(event.wait_all) == "function", "event.wait_all present")

-- wait_any/wait_all reject an empty list before touching any handle.
ok(pcall(event.wait_any, {}, 0) == false, "wait_any rejects empty list")
ok(pcall(event.wait_all, {}, 0) == false, "wait_all rejects empty list")

-- ===== core constructor (regression: FFI-HANDLE-ARRAY-INIT-001 fixed) =====
local man_ok, m = pcall(function() return event.manual() end)
ok(man_ok and type(m) == "table",
   "event.manual() constructs a usable object")

-- Full behavioral check, guarded so it only runs once the constructor is fixed.
if man_ok and m then
    -- manual-reset
    ok(m:wait(0) == false, "manual event starts non-signalled")
    m:set()
    ok(m:wait(0) == true, "manual event signalled after set")
    ok(m:wait(0) == true, "manual event STAYS signalled")
    m:reset()
    ok(m:wait(0) == false, "manual event cleared after reset")
    ok(event.manual(true):wait(0) == true, "manual(true) starts signalled")

    -- auto-reset consumes the signal
    local a = event.auto()
    ok(a:wait(0) == false, "auto event starts non-signalled")
    a:set()
    ok(a:wait(0) == true, "auto event signalled after set")
    ok(a:wait(0) == false, "auto event auto-reset consumed the signal")

    -- wait_any returns the 1-based index of the signalled event
    local e1, e2, e3 = event.manual(), event.manual(), event.manual()
    e2:set()
    local idx = event.wait_any({ e1, e2, e3 }, 0)
    ok(idx == 2, "wait_any returns index of signalled event")
    e2:reset()
    local nidx, why = event.wait_any({ e1, e2, e3 }, 0)
    ok(nidx == nil and why == "timeout", "wait_any times out when none signalled")

    -- wait_all
    local f1, f2 = event.manual(true), event.manual(true)
    ok(event.wait_all({ f1, f2 }, 0) == true, "wait_all true when all signalled")
    f2:reset()
    local wall, ww = event.wait_all({ f1, f2 }, 0)
    ok(wall == nil and ww == "timeout", "wait_all times out when not all signalled")
end

if fails == 0 then print("[+] PASS test_event") os.exit(0) else os.exit(1) end
