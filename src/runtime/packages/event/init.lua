-- event -- Win32 kernel-event wrappers (CreateEventW) for cross-thread
-- / cross-process signalling.
--
-- Public surface:
--   event.manual(initial?)        -> manual-reset event
--   event.auto(initial?)          -> auto-reset event
--   event.named(name, opts?)      -> kernel-named event (cross-process)
--                                    opts = { manual=true|false, initial=bool }
--   event.open(name)              -> open existing named event
--   event.wait_any(events, t?)    -> idx, abandoned? | nil, err
--   event.wait_all(events, t?)    -> true | nil, err
--
-- Event methods:
--   :wait(timeout_ms?)  -> bool          true = signalled, false = timeout
--   :set()                              signal
--   :reset()                            clear (manual-reset only)
--   :pulse()                            briefly signal then auto-reset
--   :raw_handle()       -> HANDLE        kernel handle (for shared use)
--   :close()                            explicit close
--
-- Reset semantics:
--   manual = N waiters wake on :set, stays signalled until :reset
--   auto   = single waiter wakes on :set, signal consumed automatically
--   pulse  = release all currently-waiting threads then auto-reset
--            (uses PulseEvent which is documented as unreliable for new
--             waiters; only use this when you control all wait sites and
--             they're already pending)

local W  = require "windows"
local WT = require "windows.threading"

ffi.cdef[[
BOOL PulseEvent(HANDLE hEvent);
]]

local C = ffi.C
local M = {}

local INFINITE       = 0xFFFFFFFF
local WAIT_OBJECT_0  = 0
local WAIT_ABANDONED = 0x80
local WAIT_TIMEOUT   = 0x102
local WAIT_FAILED    = 0xFFFFFFFF
local MAXIMUM_WAIT_OBJECTS = 64    -- WaitForMultipleObjects cap

local function widen(s)
    if s == nil then return nil end
    local CP_UTF8 = 65001
    local len = C.MultiByteToWideChar(CP_UTF8, 0, s, -1, nil, 0)
    if len <= 0 then return nil end
    local wbuf = ffi.new("unsigned short[?]", len)
    C.MultiByteToWideChar(CP_UTF8, 0, s, -1, wbuf, len)
    return wbuf
end

local event_mt = { __index = {} }
local methods  = event_mt.__index

local function close_holder(holder)
    if holder[0] ~= nil then C.CloseHandle(holder[0]) end
end

local function wrap(h, manual_reset, named)
    local holder = ffi.new("HANDLE[1]", h)
    return setmetatable({
        handle       = ffi.gc(holder, close_holder),
        manual_reset = manual_reset,
        named        = named or false,
    }, event_mt)
end

local function make_event(manual_reset, initial, name)
    local mr = manual_reset and 1 or 0
    local ini = initial and 1 or 0
    local wname = name and widen(name) or nil
    local h = C.CreateEventW(nil, mr, ini,
                             wname and ffi.cast("LPWSTR", wname) or nil)
    if h == nil then
        error("event: CreateEventW failed: " .. tonumber(C.GetLastError()))
    end
    return wrap(h, manual_reset, name ~= nil)
end

function M.manual(initial) return make_event(true, initial == true, nil) end
function M.auto(initial)   return make_event(false, initial == true, nil) end

function M.named(name, opts)
    opts = opts or {}
    local manual_reset = opts.manual ~= false and opts.manual ~= nil
    -- nil opts.manual defaults to false (auto-reset) to match unnamed
    -- shorthand symmetry. Pass opts.manual = true explicitly when you
    -- want a manual-reset named event.
    if opts.manual == nil then manual_reset = false end
    return make_event(manual_reset, opts.initial == true, name)
end

function M.open(name)
    local wname = widen(name)
    -- 0x1F0003 = EVENT_ALL_ACCESS
    local h = C.OpenEventW(0x1F0003, 0, ffi.cast("LPWSTR", wname))
    if h == nil then
        return nil, "OpenEventW failed: " .. tonumber(C.GetLastError())
    end
    return wrap(h, nil, true)
end

function methods:wait(timeout_ms)
    local r = tonumber(C.WaitForSingleObject(self.handle[0], timeout_ms or INFINITE))
    if r == WAIT_OBJECT_0 then return true end
    if r == WAIT_TIMEOUT  then return false end
    return false, "wait failed: " .. r
end

function methods:set()
    if C.SetEvent(self.handle[0]) == 0 then
        return false, "SetEvent failed: " .. tonumber(C.GetLastError())
    end
    return true
end

function methods:reset()
    if C.ResetEvent(self.handle[0]) == 0 then
        return false, "ResetEvent failed: " .. tonumber(C.GetLastError())
    end
    return true
end

-- :pulse() releases threads currently waiting on the event then
-- immediately resets it. New waiters that arrive after PulseEvent is
-- called but before they hit WaitForSingleObject are NOT released --
-- MSDN documents this as a "do not use unless you control timing"
-- primitive. Useful for broadcast-then-quiesce idioms where you know
-- all waiters are already parked.
function methods:pulse()
    if C.PulseEvent(self.handle[0]) == 0 then
        return false, "PulseEvent failed: " .. tonumber(C.GetLastError())
    end
    return true
end

function methods:raw_handle()
    return self.handle[0]
end

function methods:close()
    if self.handle[0] ~= nil then
        C.CloseHandle(self.handle[0])
        self.handle[0] = nil
    end
end

-- ===== multi-wait helpers =======================================

local function build_handle_array(events)
    local n = #events
    if n == 0 then error("event: wait list is empty") end
    if n > MAXIMUM_WAIT_OBJECTS then
        error("event: more than " .. MAXIMUM_WAIT_OBJECTS .. " events; chunk and chain instead")
    end
    local arr = ffi.new("HANDLE[?]", n)
    for i = 1, n do
        local ev = events[i]
        -- Accept either a wrapped event (has .handle) or a raw HANDLE
        -- (e.g. produced by another package and surfaced as cdata) so
        -- mixing with the `thread` package's join-handle is ergonomic.
        if type(ev) == "table" and ev.handle then
            arr[i - 1] = ev.handle[0]
        else
            arr[i - 1] = ffi.cast("HANDLE", ev)
        end
    end
    return arr, n
end

function M.wait_any(events, timeout_ms)
    local arr, n = build_handle_array(events)
    local r = tonumber(C.WaitForMultipleObjects(n, arr, 0, timeout_ms or INFINITE))
    if r >= WAIT_OBJECT_0 and r < WAIT_OBJECT_0 + n then
        return r - WAIT_OBJECT_0 + 1
    end
    if r >= WAIT_ABANDONED and r < WAIT_ABANDONED + n then
        return r - WAIT_ABANDONED + 1, "abandoned"
    end
    if r == WAIT_TIMEOUT then return nil, "timeout" end
    return nil, "wait failed: " .. r
end

function M.wait_all(events, timeout_ms)
    local arr, n = build_handle_array(events)
    local r = tonumber(C.WaitForMultipleObjects(n, arr, 1, timeout_ms or INFINITE))
    if r >= WAIT_OBJECT_0 and r < WAIT_OBJECT_0 + n then return true end
    if r == WAIT_TIMEOUT then return nil, "timeout" end
    return nil, "wait failed: " .. r
end

return M
