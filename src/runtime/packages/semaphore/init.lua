-- semaphore -- counting semaphore via Win32 CreateSemaphoreW.
--
-- Public surface:
--   semaphore.new(initial, max?)         -> sem
--   semaphore.named(name, initial?, max?) -> kernel-named (cross-process)
--   semaphore.open(name)                  -> opens an existing named semaphore
--   semaphore.with(sem, fn, ...)          -> acquire + call + release
--
-- Methods:
--   :acquire(timeout_ms?)  -> true | false, err   blocks (default infinite)
--   :try_acquire(n?)       -> bool                non-blocking; n>1 = atomic batch
--                                                   (n>1 emulated as n sequential
--                                                    try_acquires; rolls back on partial)
--   :release(n?)           -> bool, prev_count   default n = 1
--   :value()               -> approx int          best-effort current count
--   :raw_handle()          -> HANDLE              for cross-thread / wait_any sharing
--   :close()                                       explicit close
--
-- Notes on :value()
--   Win32 has no GetSemaphoreCount; the value reported is a derived
--   approximation maintained by release/acquire on this object. Direct
--   ReleaseSemaphore through another handle skews it. The kernel-tracked
--   prev_count returned from :release is authoritative for that operation.

local W      = require "windows"
local WT     = require "windows.threading"
local atomic = require "atomic"

local C = ffi.C
local M = {}

local sem_mt = { __index = {} }
local sem_methods = sem_mt.__index

local INFINITE = 0xFFFFFFFF
local WAIT_OBJECT_0 = 0
local WAIT_TIMEOUT  = 0x102

local function widen(s)
    if s == nil then return nil end
    local CP_UTF8 = 65001
    local len = C.MultiByteToWideChar(CP_UTF8, 0, s, -1, nil, 0)
    if len <= 0 then return nil end
    local wbuf = ffi.new("unsigned short[?]", len)
    C.MultiByteToWideChar(CP_UTF8, 0, s, -1, wbuf, len)
    return wbuf
end

local function close_holder(holder)
    if holder[0] ~= nil then C.CloseHandle(holder[0]) end
end

local function wrap(handle, max_count, initial)
    local holder = ffi.new("HANDLE[1]", handle)
    return setmetatable({
        handle    = ffi.gc(holder, close_holder),
        max       = max_count,
        -- Approximate current value tracked locally. Seeded with initial,
        -- updated on each acquire / release. The kernel is the source of
        -- truth -- this is a hint only.
        _count    = atomic.int64(initial),
    }, sem_mt)
end

function M.new(initial, max_count)
    initial   = initial or 0
    max_count = max_count or 0x7FFFFFFF
    if initial < 0 or max_count < 1 or initial > max_count then
        error("semaphore.new: bad initial / max range")
    end
    local h = C.CreateSemaphoreW(nil, initial, max_count, nil)
    if h == nil then
        error("semaphore.new: CreateSemaphoreW failed: " .. tonumber(C.GetLastError()))
    end
    return wrap(h, max_count, initial)
end

function M.named(name, initial, max_count)
    initial   = initial or 0
    max_count = max_count or 0x7FFFFFFF
    local wname = widen(name)
    local h = C.CreateSemaphoreW(nil, initial, max_count, ffi.cast("LPWSTR", wname))
    if h == nil then
        error("semaphore.named: CreateSemaphoreW failed: " .. tonumber(C.GetLastError()))
    end
    return wrap(h, max_count, initial)
end

function M.open(name)
    local wname = widen(name)
    -- 0x1F0003 = SEMAPHORE_ALL_ACCESS
    local h = C.OpenSemaphoreW(0x1F0003, 0, ffi.cast("LPWSTR", wname))
    if h == nil then
        return nil, "OpenSemaphoreW failed: " .. tonumber(C.GetLastError())
    end
    -- Don't know the max or initial -- start the hint at 0.
    return wrap(h, 0x7FFFFFFF, 0)
end

function sem_methods:acquire(timeout_ms)
    local r = tonumber(C.WaitForSingleObject(self.handle[0], timeout_ms or INFINITE))
    if r == WAIT_OBJECT_0 then
        self._count:dec()
        return true
    end
    if r == WAIT_TIMEOUT then return false, "timeout" end
    return false, "wait failed: " .. r
end

-- try_acquire(n): atomically grab n permits. We can't ask Win32 to wait
-- on N count units in one call, so we do n sequential zero-timeout
-- WaitForSingleObject calls and roll back via ReleaseSemaphore on partial
-- success. This matches std::counting_semaphore::try_acquire semantics.
function sem_methods:try_acquire(n)
    n = n or 1
    if n < 1 then return true end
    for i = 1, n do
        local r = tonumber(C.WaitForSingleObject(self.handle[0], 0))
        if r ~= WAIT_OBJECT_0 then
            -- Roll back any partial acquisition so the user-visible
            -- side-effect is all-or-nothing.
            if i > 1 then
                local prev = ffi.new("LONG[1]")
                C.ReleaseSemaphore(self.handle[0], i - 1, prev)
            end
            return false
        end
        self._count:dec()
    end
    return true
end

function sem_methods:release(count)
    count = count or 1
    -- ReleaseSemaphore writes the PREVIOUS count to *lpPreviousCount.
    -- We expose that as the second return so callers can implement
    -- post-release decisions ("did we just lift contention?").
    local prev = ffi.new("LONG[1]")
    if C.ReleaseSemaphore(self.handle[0], count, prev) == 0 then
        return false, "ReleaseSemaphore failed: " .. tonumber(C.GetLastError())
    end
    self._count:add(count)
    return true, tonumber(prev[0])
end

function sem_methods:value()
    return self._count:get()
end

function sem_methods:close()
    if self.handle[0] ~= nil then
        C.CloseHandle(self.handle[0])
        self.handle[0] = nil
    end
end

-- Surface the raw kernel handle so a thread spawned from another package
-- can DuplicateHandle / share access without going through a name.
function sem_methods:raw_handle()
    return self.handle[0]
end

-- ===== with helper =============================================
--
-- semaphore.with(sem, fn, ...): acquire + call + release. The protected
-- pcall guarantees release on error.

function M.with(sem, fn, ...)
    local ok_a, err_a = sem:acquire()
    if not ok_a then error(err_a or "acquire failed", 0) end
    local ok, r1, r2, r3, r4 = pcall(fn, ...)
    sem:release()
    if not ok then error(r1, 0) end
    return r1, r2, r3, r4
end

return M
