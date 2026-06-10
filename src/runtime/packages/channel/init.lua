-- channel -- Go-style channels for cross-thread Lua-value transport.
--
-- Public surface:
--   channel.make(capacity?)      -> ch     (capacity nil => unbounded)
--   channel.select(branches)     -> chosen_index, value
--
-- ch methods:
--   :send(value, timeout_ms?)    block if bounded + full; nil = INFINITE
--                                returns true on success, false + "timeout"
--                                / false + "closed"
--   :try_send(value)             -> bool                 non-blocking
--   :receive(timeout_ms?)        -> value, ok            ok=false on closed or timeout
--   :try_receive()               -> value, ok            ok=false if empty
--   :close()                     idempotent broadcast-close
--   :len()                       -> approx slot count
--   :capacity()                  -> max | math.huge for unbounded
--   :is_closed()                 -> bool
--   :iter()                      -> iterator yielding values until closed
--
-- ===== Serializer ===============================================
--
-- Lua values cross a channel by being serialized into a contiguous byte
-- buffer that lives in process-shared (heap) memory. The buffer is owned
-- by the receive side, which deserializes back into native Lua values.
--
-- Supported types: nil, boolean, number (int64 / double), string, table.
-- Cycles in tables are handled (encoder maintains a seen-set). Userdata,
-- functions, coroutines, cdata all raise on send.
--
-- Wire format (single byte tag + payload):
--   0x00            nil
--   0x01 / 0x02     false / true
--   0x10 + i64      int64 (8 bytes LE)
--   0x11 + f64      double (8 bytes LE)
--   0x20 + u32 + N  string
--   0x30 + u32 + u32 + entries  table-begin (array_len, hash_len, then values)
--   0x40 + u32      back-ref (cycle)

local W      = require "windows"
local WT     = require "windows.threading"
local atomic = require "atomic"

local C = ffi.C
local M = {}

-- ===== binary serializer ========================================

local TAG_NIL     = 0x00
local TAG_FALSE   = 0x01
local TAG_TRUE    = 0x02
local TAG_INT     = 0x10
local TAG_FLOAT   = 0x11
local TAG_STRING  = 0x20
local TAG_TABLE   = 0x30
local TAG_BACKREF = 0x40

local _scratch = ffi.new("uint8_t[8]")
local _i64ptr  = ffi.cast("int64_t *",  _scratch)
local _f64ptr  = ffi.cast("double *",   _scratch)

local function pack_u32(buf, n, v)
    n = n + 1; buf[n] = string.char(v & 0xFF,
                                    (v >>  8) & 0xFF,
                                    (v >> 16) & 0xFF,
                                    (v >> 24) & 0xFF)
    return n
end

local function pack_i64(buf, n, v)
    _i64ptr[0] = v
    n = n + 1; buf[n] = ffi.string(_scratch, 8)
    return n
end

local function pack_f64(buf, n, v)
    _f64ptr[0] = v
    n = n + 1; buf[n] = ffi.string(_scratch, 8)
    return n
end

local function encode(value, buf, n, seen)
    local t = type(value)
    if t == "nil" then
        n = n + 1; buf[n] = string.char(TAG_NIL)
    elseif t == "boolean" then
        n = n + 1; buf[n] = string.char(value and TAG_TRUE or TAG_FALSE)
    elseif t == "number" then
        if math.type(value) == "integer" then
            n = n + 1; buf[n] = string.char(TAG_INT)
            n = pack_i64(buf, n, value)
        else
            n = n + 1; buf[n] = string.char(TAG_FLOAT)
            n = pack_f64(buf, n, value)
        end
    elseif t == "string" then
        n = n + 1; buf[n] = string.char(TAG_STRING)
        n = pack_u32(buf, n, #value)
        n = n + 1; buf[n] = value
    elseif t == "table" then
        local seen_idx = seen[value]
        if seen_idx ~= nil then
            n = n + 1; buf[n] = string.char(TAG_BACKREF)
            n = pack_u32(buf, n, seen_idx)
            return n
        end
        local my_idx = seen._count
        seen._count = my_idx + 1
        seen[value] = my_idx
        local arr_len = #value
        local hash_keys = {}
        for k in pairs(value) do
            if not (type(k) == "number" and math.type(k) == "integer"
                    and k >= 1 and k <= arr_len) then
                hash_keys[#hash_keys + 1] = k
            end
        end
        n = n + 1; buf[n] = string.char(TAG_TABLE)
        n = pack_u32(buf, n, arr_len)
        n = pack_u32(buf, n, #hash_keys)
        for i = 1, arr_len do
            n = encode(value[i], buf, n, seen)
        end
        for i = 1, #hash_keys do
            local k = hash_keys[i]
            n = encode(k,        buf, n, seen)
            n = encode(value[k], buf, n, seen)
        end
    elseif t == "userdata" then
        error("channel: cannot serialize userdata across threads", 0)
    elseif t == "function" then
        error("channel: cannot serialize function across threads", 0)
    elseif t == "thread" then
        error("channel: cannot serialize coroutine across threads", 0)
    elseif t == "cdata" then
        error("channel: cannot serialize cdata across threads", 0)
    else
        error("channel: unknown value type: " .. t, 0)
    end
    return n
end

function M.serialize(value)
    local buf = {}
    local seen = { _count = 0 }
    encode(value, buf, 0, seen)
    return table.concat(buf)
end

-- ===== deserializer =============================================

local function unpack_u32(s, pos)
    local b1, b2, b3, b4 = string.byte(s, pos, pos + 3)
    return b1 | (b2 << 8) | (b3 << 16) | (b4 << 24), pos + 4
end

local function unpack_i64(s, pos)
    ffi.copy(_scratch, s:sub(pos, pos + 7), 8)
    return _i64ptr[0], pos + 8
end

local function unpack_f64(s, pos)
    ffi.copy(_scratch, s:sub(pos, pos + 7), 8)
    return _f64ptr[0], pos + 8
end

local function decode(s, pos, seen)
    local tag = string.byte(s, pos); pos = pos + 1
    if     tag == TAG_NIL   then return nil, pos
    elseif tag == TAG_FALSE then return false, pos
    elseif tag == TAG_TRUE  then return true, pos
    elseif tag == TAG_INT then
        local v, p = unpack_i64(s, pos)
        return tonumber(v), p
    elseif tag == TAG_FLOAT then
        local v, p = unpack_f64(s, pos)
        return v, p
    elseif tag == TAG_STRING then
        local len, p = unpack_u32(s, pos)
        return s:sub(p, p + len - 1), p + len
    elseif tag == TAG_TABLE then
        local arr_len, p = unpack_u32(s, pos)
        local hash_len; hash_len, p = unpack_u32(s, p)
        local t = {}
        seen[#seen + 1] = t
        for i = 1, arr_len do
            t[i], p = decode(s, p, seen)
        end
        for _ = 1, hash_len do
            local k; k, p = decode(s, p, seen)
            local v; v, p = decode(s, p, seen)
            t[k] = v
        end
        return t, p
    elseif tag == TAG_BACKREF then
        local idx, p = unpack_u32(s, pos)
        local t = seen[idx + 1]
        if t == nil then
            error("channel: dangling back-ref " .. idx, 0)
        end
        return t, p
    else
        error("channel: bad tag " .. tag .. " at pos " .. (pos - 1), 0)
    end
end

function M.deserialize(s)
    local seen = {}
    local v = decode(s, 1, seen)
    return v
end

-- ===== channel object ===========================================
--
-- A channel is a producer/consumer FIFO of serialized blobs. The slot
-- list lives in a Lua table protected by a CRITICAL_SECTION; two events
-- coordinate blocking:
--
--   not_empty -- signalled when the queue has >=1 item (receivers wait)
--   not_full  -- signalled when the queue is below capacity (senders wait;
--                only meaningful for bounded channels)

local channel_mt = { __index = {} }
local methods    = channel_mt.__index

local INFINITE      = 0xFFFFFFFF
local WAIT_OBJECT_0 = 0
local WAIT_TIMEOUT  = 0x102

local function new_cs()
    local cs = ffi.cast("CRITICAL_SECTION *", C.malloc(ffi.sizeof("CRITICAL_SECTION")))
    if cs == nil then error("channel: malloc CRITICAL_SECTION failed") end
    C.InitializeCriticalSectionAndSpinCount(cs, 2000)
    return cs
end

local function destroy_channel(ch_priv)
    if ch_priv.cs ~= nil then
        C.DeleteCriticalSection(ch_priv.cs)
        C.free(ch_priv.cs)
        ch_priv.cs = nil
    end
    if ch_priv.not_empty ~= nil then
        C.CloseHandle(ch_priv.not_empty); ch_priv.not_empty = nil
    end
    if ch_priv.not_full ~= nil then
        C.CloseHandle(ch_priv.not_full); ch_priv.not_full = nil
    end
end

-- Zero-sized cdata whose only purpose is carrying a __gc finalizer.
ffi.cdef[[ typedef struct _channel_canary { int _; } channel_canary; ]]
local _canary_t = ffi.typeof("channel_canary")

function M.make(capacity)
    local priv = {
        cs        = new_cs(),
        -- Manual-reset events so :close() can wake all waiters at once.
        -- Receivers re-check the predicate after waking; if there's still
        -- room / data they consume it, otherwise they observe `closed`
        -- and return.
        not_empty = C.CreateEventW(nil, 1, 0, nil),
        not_full  = C.CreateEventW(nil, 1, 1, nil),
        slots     = {},   -- 1..n FIFO of serialized blobs
        head      = 1,
        tail      = 1,
        len       = 0,
        capacity  = capacity,    -- nil = unbounded
        closed    = false,
    }
    if priv.not_empty == nil or priv.not_full == nil then
        if priv.not_empty ~= nil then C.CloseHandle(priv.not_empty) end
        if priv.not_full  ~= nil then C.CloseHandle(priv.not_full)  end
        C.DeleteCriticalSection(priv.cs); C.free(priv.cs)
        error("channel.make: CreateEventW failed: " .. tonumber(C.GetLastError()))
    end
    local canary = ffi.new(_canary_t)
    ffi.gc(canary, function() destroy_channel(priv) end)
    return setmetatable({
        _priv   = priv,
        _canary = canary,
    }, channel_mt)
end

-- Back-compat alias for any earlier callers; `make` is the spec name.
M.new = M.make

function methods:capacity()
    return self._priv.capacity or math.huge
end

function methods:len()
    local p = self._priv
    C.EnterCriticalSection(p.cs)
    local n = p.len
    C.LeaveCriticalSection(p.cs)
    return n
end

function methods:is_closed()
    return self._priv.closed == true
end

-- Push a serialized blob into the FIFO. Caller MUST hold the cs.
local function enqueue(p, blob)
    p.slots[p.tail] = blob
    p.tail = p.tail + 1
    p.len = p.len + 1
end

-- Pop the head blob; caller MUST hold the cs. Returns nil if empty.
local function dequeue(p)
    if p.len == 0 then return nil end
    local blob = p.slots[p.head]
    p.slots[p.head] = nil
    p.head = p.head + 1
    p.len = p.len - 1
    -- Reset indexing when fully drained so memory doesn't grow without
    -- bound on a long-lived bounded channel.
    if p.len == 0 then
        p.head = 1; p.tail = 1
    end
    return blob
end

local function refresh_events(p)
    -- Called under cs. Updates the manual-reset events to reflect
    -- current queue state so future waiters see the right edge.
    if p.len > 0 or p.closed then C.SetEvent(p.not_empty)
    else C.ResetEvent(p.not_empty) end
    if p.capacity == nil or p.len < p.capacity or p.closed then
        C.SetEvent(p.not_full)
    else
        C.ResetEvent(p.not_full)
    end
end

function methods:try_send(value)
    if self._priv.closed then return false end
    local blob = M.serialize(value)
    local p = self._priv
    C.EnterCriticalSection(p.cs)
    if p.closed then
        C.LeaveCriticalSection(p.cs)
        return false
    end
    if p.capacity ~= nil and p.len >= p.capacity then
        C.LeaveCriticalSection(p.cs)
        return false
    end
    enqueue(p, blob)
    refresh_events(p)
    C.LeaveCriticalSection(p.cs)
    return true
end

function methods:send(value, timeout_ms)
    if self._priv.closed then return false, "closed" end
    local blob = M.serialize(value)
    local p = self._priv
    local deadline = nil
    if timeout_ms ~= nil then
        deadline = tonumber(C.GetTickCount()) + timeout_ms
    end
    while true do
        C.EnterCriticalSection(p.cs)
        if p.closed then
            C.LeaveCriticalSection(p.cs)
            return false, "closed"
        end
        if p.capacity == nil or p.len < p.capacity then
            enqueue(p, blob)
            refresh_events(p)
            C.LeaveCriticalSection(p.cs)
            return true
        end
        C.LeaveCriticalSection(p.cs)
        local wait = INFINITE
        if deadline ~= nil then
            local d = deadline - tonumber(C.GetTickCount())
            if d <= 0 then return false, "timeout" end
            wait = d
        end
        local r = tonumber(C.WaitForSingleObject(p.not_full, wait))
        if r == WAIT_TIMEOUT then return false, "timeout" end
        if r ~= WAIT_OBJECT_0 then
            return false, "send wait failed: " .. r
        end
    end
end

function methods:try_receive()
    local p = self._priv
    C.EnterCriticalSection(p.cs)
    local blob = dequeue(p)
    if blob == nil then
        local closed = p.closed
        refresh_events(p)
        C.LeaveCriticalSection(p.cs)
        if closed then return nil, false end
        return nil, false
    end
    refresh_events(p)
    C.LeaveCriticalSection(p.cs)
    return M.deserialize(blob), true
end

function methods:receive(timeout_ms)
    local p = self._priv
    local deadline = nil
    if timeout_ms ~= nil then
        deadline = tonumber(C.GetTickCount()) + timeout_ms
    end
    while true do
        C.EnterCriticalSection(p.cs)
        if p.len > 0 then
            local blob = dequeue(p)
            refresh_events(p)
            C.LeaveCriticalSection(p.cs)
            return M.deserialize(blob), true
        end
        if p.closed then
            refresh_events(p)
            C.LeaveCriticalSection(p.cs)
            return nil, false
        end
        C.LeaveCriticalSection(p.cs)
        local wait = INFINITE
        if deadline ~= nil then
            local d = deadline - tonumber(C.GetTickCount())
            if d <= 0 then return nil, false, "timeout" end
            wait = d
        end
        local r = tonumber(C.WaitForSingleObject(p.not_empty, wait))
        if r == WAIT_TIMEOUT then return nil, false, "timeout" end
        if r ~= WAIT_OBJECT_0 then
            return nil, false, "recv wait failed: " .. r
        end
    end
end

function methods:close()
    local p = self._priv
    C.EnterCriticalSection(p.cs)
    if p.closed then
        C.LeaveCriticalSection(p.cs)
        return
    end
    p.closed = true
    -- Both events go to signalled state so every waiter wakes and
    -- observes the closed flag. Manual-reset means new waiters also
    -- pass through the wait immediately.
    C.SetEvent(p.not_empty)
    C.SetEvent(p.not_full)
    C.LeaveCriticalSection(p.cs)
end

-- Iterator. for v in ch:iter() do ... end -- terminates when the channel
-- is closed AND drained.
function methods:iter()
    return function()
        local v, ok = self:receive()
        if not ok then return nil end
        return v
    end
end

-- Expose raw event handles + cs address so the same channel can be
-- shared across OS threads via the `thread` package.
function methods:descriptor()
    local p = self._priv
    return {
        cs_addr   = tonumber(ffi.cast("intptr_t", p.cs)),
        not_empty = tonumber(ffi.cast("intptr_t", p.not_empty)),
        not_full  = tonumber(ffi.cast("intptr_t", p.not_full)),
        capacity  = p.capacity,
    }
end

-- ===== select =================================================
--
-- channel.select{
--     { ch1, "send", value },          -- send `value` to ch1
--     { ch2, "receive" },              -- receive from ch2
--     default = function() ... end,    -- run if no branch ready
-- }
--
-- Returns chosen_index, value:
--   * For "receive": value is the received Lua value.
--   * For "send":    value is true (the send succeeded).
--   * For default:   chosen_index is 0, value is the fn's return.
--
-- Algorithm: poll every branch via try_send / try_receive; if any
-- succeeds, return it. If none + a default is given, fire default.
-- Otherwise block on the union of readiness events (not_empty for
-- receive-branches, not_full for send-branches). On wake, restart.

function M.select(branches)
    local default_branch = branches.default
    while true do
        for i, br in ipairs(branches) do
            local ch  = br[1]
            local op  = br[2]
            if op == "receive" or op == "recv" then
                local v, ok = ch:try_receive()
                if ok then return i, v end
            elseif op == "send" then
                if ch:try_send(br[3]) then return i, true end
            else
                error("channel.select: bad op '" .. tostring(op) .. "' (want 'send' or 'receive')", 0)
            end
        end
        if default_branch ~= nil then
            return 0, default_branch()
        end
        -- Block on union of readiness events.
        local handles = {}
        for _, br in ipairs(branches) do
            local op = br[2]
            if op == "receive" or op == "recv" then
                handles[#handles + 1] = br[1]._priv.not_empty
            elseif op == "send" then
                handles[#handles + 1] = br[1]._priv.not_full
            end
        end
        local n = #handles
        if n == 0 then
            error("channel.select: no branches and no default", 0)
        end
        if n > 64 then
            error("channel.select: too many branches (max 64)", 0)
        end
        local arr = ffi.new("HANDLE[?]", n)
        for i = 1, n do arr[i - 1] = handles[i] end
        local r = tonumber(C.WaitForMultipleObjects(n, arr, 0, INFINITE))
        if r == WAIT_TIMEOUT or r >= WAIT_OBJECT_0 + n then
            -- Spurious. Loop and re-poll.
        end
    end
end

return M
