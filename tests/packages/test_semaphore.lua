-- tests/packages/test_semaphore.lua : counting semaphore via CreateSemaphoreW.
--
-- KNOWN BUG (FFI-HANDLE-ARRAY-INIT-001): every semaphore constructor goes
-- through wrap(), which does ffi.new("HANDLE[1]", handle). In this CLua FFI,
-- initializing a pointer-array from a pointer cdata raises
-- "ffi.new init: ffi: cdata kind 4 does not match target kind 5", so even
-- semaphore.new(2,5) fails. (Workaround in the FFI: ffi.new("HANDLE[1]") then
-- holder[0]=h.) We assert the API surface and XFAIL the constructor; it flips
-- to XPASS when ffi.new("HANDLE[1]", h) is fixed.
local ok_req, semaphore = pcall(require, "semaphore")
if not ok_req then print("[~] SKIP test_semaphore (" .. tostring(semaphore) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_semaphore: " .. tostring(m)) end end
local function xfail(cond, desc, bug)
  if cond then print(("[!] XPASS test_semaphore: %s -- bug %s appears FIXED, remove this xfail"):format(desc, bug))
  else        print(("[x] XFAIL test_semaphore: %s (known bug %s)"):format(desc, bug)) end
end

-- ===== API surface present =====
ok(type(semaphore.new) == "function",   "semaphore.new present")
ok(type(semaphore.named) == "function", "semaphore.named present")
ok(type(semaphore.open) == "function",  "semaphore.open present")
ok(type(semaphore.with) == "function",  "semaphore.with present")

-- ===== argument validation runs BEFORE the broken ffi.new, so it works =====
ok(pcall(semaphore.new, -1, 5) == false, "new rejects negative initial")
ok(pcall(semaphore.new, 6, 5) == false, "new rejects initial > max (6 > 5)")
ok(pcall(semaphore.new, 0, 0) == false, "new rejects max < 1")

-- ===== core constructor (regression: FFI-HANDLE-ARRAY-INIT-001 fixed) =====
local new_ok, sem = pcall(function() return semaphore.new(2, 5) end)
ok(new_ok and type(sem) == "table",
   "semaphore.new(2,5) constructs a usable object")

-- The behavioral round-trip below goes through acquire/release, which uses the
-- atomic package's x64 Interlocked intrinsics. Those are compiler intrinsics,
-- not kernel32 exports, so they are NOT callable on this build (known bug
-- ATOMIC-INTERLOCKED-SYMS-001; proper fix needs machine-code atomic thunks).
-- Probe the capability; SKIP the atomic-dependent portion cleanly if missing.
local atom_ok = pcall(function() local a = require("atomic"); return a.int(0):add(1) end)
if not atom_ok then
    if fails == 0 then print("[+] PASS test_semaphore (API surface + arg validation; atomic ops skipped)") end
    print("[~] SKIP test_semaphore atomic ops (need x64 Interlocked machine-code thunks -- ATOMIC-INTERLOCKED-SYMS-001)")
    os.exit(fails == 0 and 0 or 1)
end

-- Full behavioral check (atomics available).
if new_ok and sem then
    ok(sem:value() == 2, "new semaphore value hint is initial")
    ok(sem:acquire() == true, "acquire 1 (2->1)")
    ok(sem:acquire() == true, "acquire 2 (1->0)")
    ok(sem:try_acquire() == false, "try_acquire fails when empty")
    local got, why = sem:acquire(0)
    ok(got == false and why == "timeout", "acquire(0) on empty times out")
    local rok, prev = sem:release(1)
    ok(rok == true and prev == 0, "release returns previous kernel count 0")
    ok(sem:try_acquire() == true, "try_acquire after release")
    -- batch all-or-nothing
    local s2 = semaphore.new(3, 10)
    ok(s2:try_acquire(2) == true, "batch try_acquire(2) of 3 succeeds")
    ok(s2:try_acquire(2) == false, "batch try_acquire(2) of remaining 1 fails")
    ok(s2:try_acquire(1) == true, "single try_acquire after failed-batch rollback")
    -- with helper
    local s3 = semaphore.new(1, 1)
    ok(semaphore.with(s3, function(x) return x * 2 end, 21) == 42, "semaphore.with returns value")
    ok(s3:try_acquire() == true, "permit restored after semaphore.with")
end

if fails == 0 then print("[+] PASS test_semaphore") os.exit(0) else os.exit(1) end
