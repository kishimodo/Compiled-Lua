-- atomic -- atomic integer / pointer / flag cells via Win32 Interlocked* intrinsics.
--
-- Public surface:
--   atomic.int(initial?)        -> atomic int32 cell
--   atomic.int64(initial?)      -> atomic int64 cell
--   atomic.pointer(initial?)    -> atomic void* cell
--   atomic.flag()               -> atomic 0/1 cell
--   atomic.fence()              -> process-wide memory barrier
--
-- All cells expose:
--   :get()                       -> snapshot read (sequentially consistent)
--   :set(v)                                       full-fence store
--   :swap(v)                     -> old           atomic exchange
--   :cas(expected, new)          -> bool          compare-and-swap (true on success)
--
-- int / int64 cells also expose:
--   :add(delta)                  -> new           fetch-and-add (POST-add value)
--   :sub(delta)                  -> new           fetch-and-sub (POST-sub value)
--   :inc()                       -> new           +1
--   :dec()                       -> new           -1
--   :and_(mask)                  -> new           bitwise AND
--   :or_(mask)                   -> new           bitwise OR
--
-- The flag cell is a specialized int with :test_and_set() / :clear() shortcuts.
--
-- Cells expose :address() returning the raw int address; this lets a
-- single cell back atomic operations performed from multiple OS threads:
-- one thread creates the cell, sends address() over a channel, the other
-- side recreates a view via atomic.int_from_address(addr).
--
-- Memory ordering: every Interlocked* on x64 carries a LOCK prefix, which
-- gives sequentially consistent semantics. atomic.fence() forces a
-- FlushProcessWriteBuffers for the rare case where you need a barrier
-- around non-Interlocked publish steps.

local W  = require "windows"
local WT = require "windows.threading"

-- Lua 5.4 + FFI: the parser is stock Lua 5.4 so suffixes like 0LL aren't
-- accepted. Use ffi.cast'd zero constants instead.
local I64_ZERO = ffi.cast("int64_t", 0)

ffi.cdef[[
LONG     InterlockedExchangeAdd(LONG volatile *Addend, LONG Value);
LONGLONG InterlockedExchangeAdd64(LONGLONG volatile *Addend, LONGLONG Value);
LONG     InterlockedExchange(LONG volatile *Target, LONG Value);
LONGLONG InterlockedExchange64(LONGLONG volatile *Target, LONGLONG Value);
LONG     InterlockedCompareExchange(LONG volatile *Dest, LONG Exchange, LONG Comp);
LONGLONG InterlockedCompareExchange64(LONGLONG volatile *Dest, LONGLONG Exchange, LONGLONG Comp);
void   * InterlockedExchangePointer(void * volatile *Target, void *Value);
void   * InterlockedCompareExchangePointer(void * volatile *Dest, void *Exchange, void *Comp);
LONG     InterlockedIncrement(LONG volatile *Addend);
LONG     InterlockedDecrement(LONG volatile *Addend);
LONGLONG InterlockedIncrement64(LONGLONG volatile *Addend);
LONGLONG InterlockedDecrement64(LONGLONG volatile *Addend);
LONG     InterlockedOr(LONG volatile *Dest, LONG Value);
LONGLONG InterlockedOr64(LONGLONG volatile *Dest, LONGLONG Value);
LONG     InterlockedAnd(LONG volatile *Dest, LONG Value);
LONGLONG InterlockedAnd64(LONGLONG volatile *Dest, LONGLONG Value);
]]

local C = ffi.C
local M = {}

-- ===== shared helpers =====

local function intptr_addr(cell)
    return tonumber(ffi.cast("intptr_t", cell))
end

-- ===== int32 cell =================================================

local int32_mt = { __index = {} }
local int32_methods = int32_mt.__index

local function new_int32_cell(initial)
    local cell = ffi.new("int32_t[1]")
    cell[0] = initial or 0
    return cell
end

function M.int(initial)
    return setmetatable({
        cell  = new_int32_cell(initial),
        _kind = "int",
    }, int32_mt)
end

function M.int_from_address(addr)
    return setmetatable({
        cell  = ffi.cast("int32_t *", addr),
        _kind = "int",
        _ref  = true,
    }, int32_mt)
end

function int32_methods:address()      return intptr_addr(self.cell) end
function int32_methods:get()          return tonumber(C.InterlockedOr(self.cell, 0)) end
function int32_methods:set(v)         C.InterlockedExchange(self.cell, v) end
function int32_methods:swap(v)        return tonumber(C.InterlockedExchange(self.cell, v)) end

function int32_methods:cas(expected, new)
    local old = C.InterlockedCompareExchange(self.cell, new, expected)
    return tonumber(old) == expected, tonumber(old)
end

function int32_methods:add(delta)
    local old = tonumber(C.InterlockedExchangeAdd(self.cell, delta))
    return old + delta
end

function int32_methods:sub(delta)
    local old = tonumber(C.InterlockedExchangeAdd(self.cell, -delta))
    return old - delta
end

function int32_methods:inc() return tonumber(C.InterlockedIncrement(self.cell)) end
function int32_methods:dec() return tonumber(C.InterlockedDecrement(self.cell)) end

function int32_methods:and_(mask)
    local old = tonumber(C.InterlockedAnd(self.cell, mask))
    return old & mask
end

function int32_methods:or_(mask)
    local old = tonumber(C.InterlockedOr(self.cell, mask))
    return old | mask
end

-- ===== int64 cell =================================================

local int64_mt = { __index = {} }
local int64_methods = int64_mt.__index

-- We back the cell with a separate ffi.new("int64_t[1]") rather than
-- embedding the int64_t directly in the userdata table because LuaJIT's
-- FFI guarantees an int64_t[1] is 8-byte aligned, which the Interlocked*
-- ops require.
local function new_int64_cell(initial)
    local cell = ffi.new("int64_t[1]")
    cell[0] = initial or 0
    return cell
end

function M.int64(initial)
    return setmetatable({
        cell  = new_int64_cell(initial),
        _kind = "int64",
    }, int64_mt)
end

function M.int64_from_address(addr)
    return setmetatable({
        cell  = ffi.cast("int64_t *", addr),
        _kind = "int64",
        _ref  = true,
    }, int64_mt)
end

function int64_methods:address()      return intptr_addr(self.cell) end

function int64_methods:get()
    -- Plain aligned 64-bit loads are atomic on x64; OR-with-zero is the
    -- canonical "atomic load" pattern when no LoadAcquire is available.
    return tonumber(C.InterlockedOr64(self.cell, I64_ZERO))
end

function int64_methods:set(v)         C.InterlockedExchange64(self.cell, v) end
function int64_methods:swap(v)        return tonumber(C.InterlockedExchange64(self.cell, v)) end

function int64_methods:cas(expected, new)
    local old = C.InterlockedCompareExchange64(self.cell, new, expected)
    return tonumber(old) == expected, tonumber(old)
end

function int64_methods:add(delta)
    local old = tonumber(C.InterlockedExchangeAdd64(self.cell, delta))
    return old + delta
end

function int64_methods:sub(delta)
    local old = tonumber(C.InterlockedExchangeAdd64(self.cell, -delta))
    return old - delta
end

function int64_methods:inc() return tonumber(C.InterlockedIncrement64(self.cell)) end
function int64_methods:dec() return tonumber(C.InterlockedDecrement64(self.cell)) end

function int64_methods:and_(mask)
    local old = tonumber(C.InterlockedAnd64(self.cell, mask))
    return old & mask
end

function int64_methods:or_(mask)
    local old = tonumber(C.InterlockedOr64(self.cell, mask))
    return old | mask
end

-- ===== pointer cell ==============================================

local ptr_mt = { __index = {} }
local ptr_methods = ptr_mt.__index

function M.pointer(initial)
    local cell = ffi.new("void *[1]")
    if initial ~= nil then
        cell[0] = ffi.cast("void *", initial)
    end
    return setmetatable({ cell = cell, _kind = "ptr" }, ptr_mt)
end

function M.pointer_from_address(addr)
    return setmetatable({
        cell  = ffi.cast("void * *", addr),
        _kind = "ptr",
        _ref  = true,
    }, ptr_mt)
end

function ptr_methods:address() return intptr_addr(self.cell) end

function ptr_methods:get()
    -- Aligned pointer reads on x64 are atomic; the cdata assignment
    -- copy performs that aligned load.
    return self.cell[0]
end

function ptr_methods:set(v)
    C.InterlockedExchangePointer(self.cell, ffi.cast("void *", v))
end

function ptr_methods:swap(v)
    return C.InterlockedExchangePointer(self.cell, ffi.cast("void *", v))
end

function ptr_methods:cas(expected, new)
    local exp_cast = ffi.cast("void *", expected)
    local old = C.InterlockedCompareExchangePointer(self.cell,
                    ffi.cast("void *", new), exp_cast)
    return old == exp_cast, old
end

-- ===== flag cell =================================================
--
-- A 0/1 atomic bool. Implemented as an int32 cell with two convenience
-- methods that match the std::atomic_flag idiom: test_and_set returns
-- the previous value, clear stores 0.

local flag_mt = { __index = {} }
local flag_methods = flag_mt.__index

function M.flag()
    return setmetatable({
        cell  = new_int32_cell(0),
        _kind = "flag",
    }, flag_mt)
end

function flag_methods:address() return intptr_addr(self.cell) end
function flag_methods:get()     return tonumber(C.InterlockedOr(self.cell, 0)) end
function flag_methods:set(v)    C.InterlockedExchange(self.cell, v and 1 or 0) end
function flag_methods:swap(v)
    return tonumber(C.InterlockedExchange(self.cell, v and 1 or 0))
end

function flag_methods:cas(expected, new)
    local e = expected and 1 or 0
    local n = new and 1 or 0
    local old = C.InterlockedCompareExchange(self.cell, n, e)
    return tonumber(old) == e
end

-- atomic_flag style: returns the PREVIOUS value, sets to 1.
function flag_methods:test_and_set()
    return tonumber(C.InterlockedExchange(self.cell, 1)) ~= 0
end

function flag_methods:clear()
    C.InterlockedExchange(self.cell, 0)
end

-- ===== fences ====================================================

-- Process-wide full memory barrier. Forces a serializing instruction
-- so all earlier loads/stores are visible before any later one. Useful
-- around lock-free hand-offs that don't naturally carry a barrier
-- (e.g. publishing a freshly-built object pointer).
function M.fence()
    C.FlushProcessWriteBuffers()
end

return M
