-- mutex -- recursive mutex + slim reader-writer lock + named kernel mutex.
--
-- Public surface:
--   mutex.mutex()                       -> recursive mutex (CRITICAL_SECTION)
--   mutex.rwlock()                      -> SRWLOCK-backed reader-writer lock
--   mutex.kernel_mutex(name?, initial?) -> named cross-process kernel mutex
--   mutex.open_kernel(name)             -> open an existing named kernel mutex
--   mutex.with_lock(m, fn, ...)         -> RAII-style lock + call + unlock
--
-- Recursive mutex methods:
--   :lock(timeout_ms?)  -> bool          block until held; nil = INFINITE
--   :try_lock()         -> bool          non-blocking
--   :unlock()                            release one acquisition
--
-- Reader-writer methods:
--   :lock_shared()                        acquire reader (shared)
--   :unlock_shared()                      release reader
--   :lock_exclusive()                     acquire writer
--   :unlock_exclusive()                   release writer
--   :try_lock_shared()    -> bool         non-blocking shared
--   :try_lock_exclusive() -> bool         non-blocking exclusive
--
-- Kernel mutex methods (same shape as recursive but with abandoned
-- detection on inherited locks):
--   :lock(timeout_ms?)  -> bool, abandoned?
--   :try_lock()
--   :unlock()
--
-- Why two user-space backings?
--   * CRITICAL_SECTION is recursive (one thread can re-enter) and lives
--     entirely in user space until contention forces a kernel transition.
--     The lightest option for short critical sections.
--   * SRWLOCK is NOT recursive but supports shared (reader) acquisition.
--     8 bytes, no kernel object until contention; reads stay user-mode
--     even under contention.
--   * Named kernel mutex backs the cross-process variant; only that one
--     can be opened by another process via mutex.open_kernel(name).
--
-- The CRITICAL_SECTION variant exposes a timeout via EnterCriticalSection
-- + spin loop emulation (Win32 has no native CS timeout). For true timed
-- semantics use the kernel mutex variant.

local W  = require "windows"
local WT = require "windows.threading"

local C = ffi.C
local M = {}

local INFINITE       = 0xFFFFFFFF
local WAIT_OBJECT_0  = 0
local WAIT_ABANDONED = 0x80
local WAIT_TIMEOUT   = 0x102

-- ===== CRITICAL_SECTION-backed recursive mutex ==================
--
-- We allocate the CRITICAL_SECTION on the C heap rather than as a
-- Lua-managed cdata because the address must remain stable for the
-- mutex's lifetime (callers may share it across threads).

local mutex_mt = { __index = {} }
local mutex_methods = mutex_mt.__index

local function destroy_cs(cs)
    C.DeleteCriticalSection(cs)
    C.free(cs)
end

function M.mutex()
    local cs = ffi.cast("CRITICAL_SECTION *", C.malloc(ffi.sizeof("CRITICAL_SECTION")))
    if cs == nil then error("mutex.mutex: malloc failed") end
    -- Spin count of 4000 matches what MSVC's std::mutex uses on
    -- contended paths. Under low contention the lock stays user-mode.
    if C.InitializeCriticalSectionAndSpinCount(cs, 4000) == 0 then
        C.free(cs)
        error("mutex.mutex: InitializeCriticalSection failed: " .. tonumber(C.GetLastError()))
    end
    return setmetatable({
        cs    = ffi.gc(cs, destroy_cs),
        _kind = "cs",
    }, mutex_mt)
end

-- :lock(timeout_ms?). Win32 has no native CS timeout, so we emulate by
-- TryEnter in a short spin then small Sleep up to the deadline. nil =
-- block indefinitely (single EnterCriticalSection call).
function mutex_methods:lock(timeout_ms)
    if timeout_ms == nil then
        C.EnterCriticalSection(self.cs)
        return true
    end
    if timeout_ms <= 0 then
        return C.TryEnterCriticalSection(self.cs) ~= 0
    end
    -- Cheap spin first; back off to Sleep once we exceed a few microseconds
    -- of pure-CPU waiting. Tick granularity is 1ms so we round up.
    local deadline = tonumber(C.GetTickCount()) + timeout_ms
    while true do
        if C.TryEnterCriticalSection(self.cs) ~= 0 then return true end
        local now = tonumber(C.GetTickCount())
        if now >= deadline then return false end
        C.Sleep(1)
    end
end

function mutex_methods:unlock()
    C.LeaveCriticalSection(self.cs)
end

function mutex_methods:try_lock()
    return C.TryEnterCriticalSection(self.cs) ~= 0
end

-- Address-exposed so cross-thread sharing works: pass :address() through
-- a channel and reattach with mutex.from_address(addr). The receiving
-- side must NOT gc-destroy the cs (the original owns it).
function mutex_methods:address()
    return tonumber(ffi.cast("intptr_t", self.cs))
end

function M.from_address(addr)
    return setmetatable({
        cs    = ffi.cast("CRITICAL_SECTION *", addr),
        _kind = "cs",
        _ref  = true,    -- no finalizer; caller owns the storage
    }, mutex_mt)
end

-- ===== SRWLOCK-backed reader-writer lock ========================
--
-- SRWLOCK is the slim reader-writer lock added in Vista. 8 bytes per
-- lock, no kernel object until contention forces a wait, N readers can
-- enter the shared side simultaneously. Trade-off: no recursion.

local rw_mt = { __index = {} }
local rw_methods = rw_mt.__index

local function destroy_srw(srw)
    -- SRWLOCK has no Destroy* entry point: the docs say it's safe to
    -- abandon (no kernel resources unless a wait was pending). Just free.
    C.free(srw)
end

function M.rwlock()
    local srw = ffi.cast("SRWLOCK *", C.malloc(ffi.sizeof("SRWLOCK")))
    if srw == nil then error("mutex.rwlock: malloc failed") end
    C.InitializeSRWLock(srw)
    return setmetatable({
        srw   = ffi.gc(srw, destroy_srw),
        _kind = "rw",
    }, rw_mt)
end

function rw_methods:lock_shared()      C.AcquireSRWLockShared(self.srw) end
function rw_methods:unlock_shared()    C.ReleaseSRWLockShared(self.srw) end
function rw_methods:lock_exclusive()   C.AcquireSRWLockExclusive(self.srw) end
function rw_methods:unlock_exclusive() C.ReleaseSRWLockExclusive(self.srw) end

function rw_methods:try_lock_shared()    return C.TryAcquireSRWLockShared(self.srw) ~= 0 end
function rw_methods:try_lock_exclusive() return C.TryAcquireSRWLockExclusive(self.srw) ~= 0 end

function rw_methods:address()
    return tonumber(ffi.cast("intptr_t", self.srw))
end

function M.rwlock_from_address(addr)
    return setmetatable({
        srw   = ffi.cast("SRWLOCK *", addr),
        _kind = "rw",
        _ref  = true,
    }, rw_mt)
end

-- ===== named kernel mutex =======================================
--
-- For cross-process synchronization. Backed by a kernel mutex object
-- (CreateMutexW with a name in the Local\ or Global\ namespace).
-- Prefix the name with "Global\\" to make it visible across
-- terminal-server sessions.

local kernel_mt = { __index = {} }
local kernel_methods = kernel_mt.__index

local function widen(s)
    -- Convert UTF-8 / ASCII Lua string to UTF-16 for the W-suffix APIs.
    if s == nil then return nil end
    local CP_UTF8 = 65001
    local len = C.MultiByteToWideChar(CP_UTF8, 0, s, -1, nil, 0)
    if len <= 0 then return nil end
    local wbuf = ffi.new("unsigned short[?]", len)
    C.MultiByteToWideChar(CP_UTF8, 0, s, -1, wbuf, len)
    return wbuf
end

local function close_kernel(handle_holder)
    local h = handle_holder[0]
    if h ~= nil then C.CloseHandle(h) end
end

function M.kernel_mutex(name, initial_owner)
    local wname = name and widen(name) or nil
    -- CreateMutexW returns a handle even if the name already exists; the
    -- subsequent GetLastError tells us whether we're the creator or a
    -- follower. ERROR_ALREADY_EXISTS is fine -- we get a usable handle
    -- either way.
    local h = C.CreateMutexW(nil,
                             initial_owner and 1 or 0,
                             wname and ffi.cast("LPWSTR", wname) or nil)
    if h == nil then
        error("mutex.kernel_mutex: CreateMutexW failed: " .. tonumber(C.GetLastError()))
    end
    local holder = ffi.new("HANDLE[1]", h)
    return setmetatable({
        handle = ffi.gc(holder, close_kernel),
        _kind  = "kernel",
        named  = name ~= nil,
    }, kernel_mt)
end

-- Open an existing named mutex without creating one. Useful when the
-- creator is in a different process and you want to fail fast if it
-- isn't running yet.
function M.open_kernel(name)
    local wname = widen(name)
    -- 0x1F0001 = MUTEX_ALL_ACCESS
    local h = C.OpenMutexW(0x1F0001, 0, ffi.cast("LPWSTR", wname))
    if h == nil then
        return nil, "OpenMutexW failed: " .. tonumber(C.GetLastError())
    end
    local holder = ffi.new("HANDLE[1]", h)
    return setmetatable({
        handle = ffi.gc(holder, close_kernel),
        _kind  = "kernel",
        named  = true,
    }, kernel_mt)
end

function kernel_methods:lock(timeout_ms)
    local r = tonumber(C.WaitForSingleObject(self.handle[0], timeout_ms or INFINITE))
    -- WAIT_ABANDONED: the previous holder died without releasing. The
    -- mutex IS ours now but the state it was guarding may be inconsistent.
    -- Surface this so the caller can decide whether to rebuild.
    if r == WAIT_OBJECT_0 then return true end
    if r == WAIT_ABANDONED then return true, "abandoned" end
    if r == WAIT_TIMEOUT then return false, "timeout" end
    return false, "wait failed: " .. r
end

function kernel_methods:try_lock()
    return self:lock(0)
end

function kernel_methods:unlock()
    if C.ReleaseMutex(self.handle[0]) == 0 then
        return false, "ReleaseMutex failed: " .. tonumber(C.GetLastError())
    end
    return true
end

function kernel_methods:raw_handle()
    return self.handle[0]
end

function kernel_methods:close()
    if self.handle[0] ~= nil then
        C.CloseHandle(self.handle[0])
        self.handle[0] = nil
    end
end

-- ===== with_lock helper ========================================
--
-- RAII-style. The protected pcall ensures we always unlock even on
-- error; we re-raise the captured error after release so the caller's
-- frame sees it. Multi-return up to 4 values matches what most callers
-- need without paying for varargs marshaling.
--
-- Recognizes:
--   * recursive mutex -- lock / unlock
--   * rwlock          -- defaults to exclusive (write-side)
--   * kernel mutex    -- lock / unlock with abandoned-pass-through

function M.with_lock(m, fn, ...)
    if m._kind == "rw" then
        C.AcquireSRWLockExclusive(m.srw)
        local ok, r1, r2, r3, r4 = pcall(fn, ...)
        C.ReleaseSRWLockExclusive(m.srw)
        if not ok then error(r1, 0) end
        return r1, r2, r3, r4
    elseif m._kind == "cs" then
        C.EnterCriticalSection(m.cs)
        local ok, r1, r2, r3, r4 = pcall(fn, ...)
        C.LeaveCriticalSection(m.cs)
        if not ok then error(r1, 0) end
        return r1, r2, r3, r4
    elseif m._kind == "kernel" then
        local got, abandoned = m:lock()
        if not got then error(abandoned or "kernel lock failed", 0) end
        local ok, r1, r2, r3, r4 = pcall(fn, ...)
        m:unlock()
        if not ok then error(r1, 0) end
        return r1, r2, r3, r4
    else
        error("mutex.with_lock: unsupported lock type", 0)
    end
end

return M
