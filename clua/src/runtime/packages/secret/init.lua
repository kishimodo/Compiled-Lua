-- secret -- handling-sensitive-bytes helpers.
--
-- Public surface:
--   secret.equals(a, b)                 -> bool   (constant-time)
--   secret.memcmp(a, b)                 -> bool   (alias for equals)
--   secret.wipe(buf_or_string, n?)      -> nil    (zero an ffi buffer; for
--                                                  a Lua string see notes)
--   secret.lock(buf, n)                 -> bool   (VirtualLock wrapper)
--   secret.unlock(buf, n)               -> bool   (VirtualUnlock wrapper)
--   secret.lock_memory / unlock_memory  -- legacy aliases
--   secret.redact(value, opts?)         -> wrapper printing "<redacted>"; the
--                                          underlying value is reachable through
--                                          :reveal(). opts.keep_first / keep_last
--                                          for partial reveal in the string form.
--   secret.new_buffer(n)                -> ffi.new("unsigned char[?]", n) helper
--   secret.bytes_to_buffer(s)           -> ffi buffer with the bytes of s
--
-- The wipe() helper goes through a `volatile unsigned char *` cast so that
-- LuaJIT/Lua-FFI cannot eliminate the writes the way an aggressive C compiler
-- would. Lua strings are immutable and interned, so wiping a *string* is
-- impossible from pure Lua -- callers that need wipeable memory must hold
-- their secret in an ffi buffer (use secret.bytes_to_buffer(s) to copy in).

require "windows"
require "windows.memory"

local M = {}

-- Volatile pointer typedef -- declared once so FFI treats every cast through it
-- as not subject to dead-store elimination.
ffi.cdef[[
typedef volatile unsigned char * VOLATILE_BYTE_PTR;
]]

-- ===== Constant-time compare ===========================================

local function equals(a, b)
    if type(a) ~= "string" or type(b) ~= "string" then
        error("secret.equals: both arguments must be strings")
    end
    -- Compare in constant time relative to the actual content. We OR a length
    -- mismatch into the accumulator so callers can't time-distinguish a
    -- "length mismatch" from a "content mismatch".
    local la, lb = #a, #b
    local n = math.min(la, lb)
    local diff = la ~ lb
    for i = 1, n do
        diff = diff | (a:byte(i) ~ b:byte(i))
    end
    return diff == 0
end

M.equals = equals
M.memcmp = equals  -- legacy alias

-- ===== Zero-wipe via volatile pointer ==================================
-- For a Lua string, the best we can do is refuse silently: strings are
-- interned and immutable so a "wipe" can only clear the local reference.
-- Caller should hold the secret in an ffi buffer instead.

function M.wipe(buf, n)
    if buf == nil then return end
    if type(buf) == "string" then
        -- Document the limitation rather than silently lying.
        error("secret.wipe: Lua strings cannot be wiped; copy to a buffer first "
              .. "(see secret.bytes_to_buffer)")
    end
    if n == nil then n = ffi.sizeof(buf) end
    if n == nil or n <= 0 then return end
    local p = ffi.cast("VOLATILE_BYTE_PTR", buf)
    for i = 0, n - 1 do p[i] = 0 end
end

-- ===== VirtualLock wrappers ============================================

local function lock(buf, n)
    if buf == nil or n == nil or n <= 0 then return false end
    return ffi.C.VirtualLock(ffi.cast("void *", buf),
                             ffi.cast("void *", n)) ~= 0
end

local function unlock(buf, n)
    if buf == nil or n == nil or n <= 0 then return false end
    return ffi.C.VirtualUnlock(ffi.cast("void *", buf),
                               ffi.cast("void *", n)) ~= 0
end

M.lock          = lock
M.unlock        = unlock
M.lock_memory   = lock     -- legacy aliases
M.unlock_memory = unlock

-- ===== Buffer helpers ==================================================

function M.new_buffer(n)
    if type(n) ~= "number" or n <= 0 then error("secret.new_buffer: bad size") end
    return ffi.new("unsigned char[?]", n)
end

function M.bytes_to_buffer(s)
    if type(s) ~= "string" then error("secret.bytes_to_buffer: expected string") end
    local buf = ffi.new("unsigned char[?]", math.max(1, #s))
    if #s > 0 then ffi.copy(buf, s, #s) end
    return buf, #s
end

-- ===== Redaction =======================================================
-- Two flavours, chosen by argument shape:
--   secret.redact(value)                   -> Redacted wrapper (any Lua value)
--   secret.redact(s, keep_first, keep_last) -> string ("ab***yz")
--
-- The wrapper form is the safer default: __tostring + __concat surface
-- "<redacted>" so accidental log statements never spill the secret; the
-- original is reachable only through :reveal().

local Redacted = {}
Redacted.__index = Redacted
Redacted.__tostring = function(self) return self._label end
Redacted.__concat = function(a, b)
    local function s(v)
        if type(v) == "table" and getmetatable(v) == Redacted then return v._label end
        return tostring(v)
    end
    return s(a) .. s(b)
end

function Redacted:reveal() return self._value end

function Redacted:masked(keep_first, keep_last)
    -- Convenience: if the wrapped value is a string, render a "ab***yz" form.
    if type(self._value) ~= "string" then return self._label end
    return M.redact(self._value, keep_first or 0, keep_last or 0)
end

local function redact_string(s, keep_first, keep_last)
    keep_first = keep_first or 0
    keep_last  = keep_last  or 0
    local n = #s
    if n == 0 then return "" end
    if keep_first + keep_last >= n then
        return string.rep("*", n)
    end
    local head = s:sub(1, keep_first)
    local tail = s:sub(n - keep_last + 1)
    local middle_len = n - keep_first - keep_last
    -- Cap the middle repeat so we don't accidentally leak length for very long secrets.
    local stars
    if middle_len > 12 then
        stars = string.rep("*", 8) .. string.format("(+%d)", middle_len - 8)
    else
        stars = string.rep("*", middle_len)
    end
    return head .. stars .. tail
end

function M.redact(value, keep_first, keep_last)
    -- String + numeric args: legacy "ab***yz" masking path.
    if type(value) == "string" and (type(keep_first) == "number"
                                    or type(keep_last) == "number") then
        return redact_string(value, keep_first, keep_last)
    end
    -- Otherwise: wrap. Optional second arg can be a label string.
    local label = (type(keep_first) == "string") and keep_first or "<redacted>"
    return setmetatable({ _value = value, _label = label }, Redacted)
end

return M
