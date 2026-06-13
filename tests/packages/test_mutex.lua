-- tests/packages/test_mutex.lua : SRWLOCK reader-writer lock + with_lock.
--
-- NOTE: the CRITICAL_SECTION-backed mutex.mutex() and the kernel_mutex()
-- paths are currently BROKEN in this FFI (see the XFAILs at the bottom):
--   * ffi.sizeof("CRITICAL_SECTION") and ffi.sizeof("SRWLOCK") both return 0,
--     so mutex.mutex() does malloc(0) then InitializeCriticalSection() writes
--     ~40 bytes past the allocation, corrupting the heap. The process then
--     ABORTS (exit 127) when the cs is free()'d during GC -- a deferred,
--     uncatchable crash, so this test must NEVER create a mutex.mutex().
--   * mutex.kernel_mutex() throws at ffi.new("HANDLE[1]", h):
--     "ffi: cdata kind 4 does not match target kind 5".
-- The SRWLOCK path's 8-byte write into the 0-byte alloc happens not to be
-- fatal and its lock semantics are correct, so we exercise that fully.
local ok_req, mutex = pcall(require, "mutex")
if not ok_req then print("[~] SKIP test_mutex (" .. tostring(mutex) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_mutex: " .. tostring(m)) end end
local function xfail(cond, desc, bug)
  if cond then print(("[!] XPASS test_mutex: %s -- bug %s appears FIXED, remove this xfail"):format(desc, bug))
  else        print(("[x] XFAIL test_mutex: %s (known bug %s)"):format(desc, bug)) end
end

-- ===== rwlock (SRWLOCK) -- the working path =====
local rw = mutex.rwlock()
ok(rw:try_lock_shared() == true, "rwlock try_lock_shared on free lock")
ok(rw:try_lock_shared() == true, "rwlock second shared reader allowed")
-- exclusive must fail while readers hold the shared side.
ok(rw:try_lock_exclusive() == false, "rwlock exclusive blocked while shared held")
rw:unlock_shared()
rw:unlock_shared()
ok(rw:try_lock_exclusive() == true, "rwlock exclusive after readers released")
-- another exclusive must fail while writer holds it.
ok(rw:try_lock_exclusive() == false, "rwlock second exclusive blocked")
-- shared must fail while writer holds it.
ok(rw:try_lock_shared() == false, "rwlock shared blocked while exclusive held")
rw:unlock_exclusive()
ok(rw:try_lock_exclusive() == true, "rwlock exclusive reacquirable after release")
rw:unlock_exclusive()

-- blocking forms acquire a free lock.
rw:lock_shared(); ok(true, "lock_shared on free lock did not error"); rw:unlock_shared()
rw:lock_exclusive(); ok(true, "lock_exclusive on free lock did not error"); rw:unlock_exclusive()

-- address round-trip aliasing into the same SRWLOCK.
local a = rw:address()
ok(type(a) == "number", "rwlock address() is a number")
local view = mutex.rwlock_from_address(a)
ok(view:try_lock_exclusive() == true, "aliased rwlock view can lock")
-- the original sees the lock held via the alias.
ok(rw:try_lock_exclusive() == false, "original sees exclusive held via aliased view")
view:unlock_exclusive()
ok(rw:try_lock_exclusive() == true, "original can lock after aliased view released")
rw:unlock_exclusive()

-- ===== with_lock helper (rwlock = exclusive side) =====
local rw2 = mutex.rwlock()
local r = mutex.with_lock(rw2, function(x, y) return x + y end, 3, 4)
ok(r == 7, "with_lock(rwlock) returns first value")
-- with_lock releases even on error and re-raises.
local perr = pcall(mutex.with_lock, rw2, function() error("boom") end)
ok(perr == false, "with_lock re-raises callee error")
-- lock is released after the error path, so we can re-acquire.
ok(rw2:try_lock_exclusive() == true, "rwlock released after with_lock error path")
rw2:unlock_exclusive()

-- unsupported lock type errors.
ok(pcall(mutex.with_lock, { _kind = "weird" }, function() end) == false,
   "with_lock rejects unknown lock kind")

-- ===== formerly-broken HANDLE/CRITICAL_SECTION paths (now regression tests) =
-- Regression (MUTEX-CS-SIZEOF-001): ffi.sizeof("CRITICAL_SECTION") used to
-- return 0, so mutex.mutex() did malloc(0) then InitializeCriticalSection()
-- corrupted the heap. We probe the root cause (sizeof) rather than instantiate
-- the (formerly) crashing object.
ok(ffi.sizeof("CRITICAL_SECTION") ~= 0,
   "ffi.sizeof('CRITICAL_SECTION') is non-zero so mutex.mutex() allocates enough (regression MUTEX-CS-SIZEOF-001)")
-- Regression (MUTEX-KERNEL-HANDLE-001): ffi.new("HANDLE[1]", handle) used to
-- reject the cdata ("cdata kind 4 does not match target kind 5"), breaking the
-- HANDLE-based constructors. kernel_mutex() hits that path directly.
local kok = pcall(function() return mutex.kernel_mutex() end)
ok(kok, "mutex.kernel_mutex() constructs without an ffi.new cdata-kind error (regression MUTEX-KERNEL-HANDLE-001)")
-- Regression (MUTEX-OPENKERNEL-NULLCMP-001): open_kernel() on a MISSING name
-- must return cleanly; a null HANDLE used not to compare == nil in this FFI,
-- so it fell through to the ffi.new("HANDLE[1]", null) error.
local ook = pcall(function() return mutex.open_kernel("CLua_test_no_such_mutex_zzz_42") end)
ok(ook, "open_kernel(missing) returns cleanly (null HANDLE compares == nil) (regression MUTEX-OPENKERNEL-NULLCMP-001)")

if fails == 0 then print("[+] PASS test_mutex") os.exit(0) else os.exit(1) end
