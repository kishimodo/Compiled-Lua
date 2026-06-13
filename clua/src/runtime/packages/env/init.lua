-- env -- Windows environment-variable wrapper.
--
-- All operations go through the Win32 process environment block (the W
-- variants -- UTF-16). UTF-8 strings come in/out at the Lua boundary
-- because CLua scripts are byte-strings by convention.
--
-- Public surface:
--   env.get(name)          -> value or nil
--   env.set(name, value)   -> ok, err            (value=nil deletes too)
--   env.unset(name)        -> ok, err
--   env.expand(s)          -> string             (ExpandEnvironmentStringsW)
--   env.list()             -> { name = value, ... }
--   env.with(t, fn, ...)   -> fn's return values (vars set during fn, restored after;
--                             use env.UNSET as a value to delete a var for the scope)

local W = require "windows"

ffi.cdef[[
DWORD SetEnvironmentVariableW(LPCWSTR lpName, LPCWSTR lpValue);
DWORD ExpandEnvironmentStringsW(LPCWSTR lpSrc, LPWSTR lpDst, DWORD nSize);
LPWSTR GetEnvironmentStringsW(void);
DWORD FreeEnvironmentStringsW(LPWSTR penv);
]]

local C = ffi.C
local M = {}

-- ===== get / set / unset =================================================

-- Two-call sizing dance is avoided per the m13b note in windows/init.lua:
-- size the scratch buffer once at 8 KB (covers every env var I've ever
-- seen in the wild; PATH on dev boxes rarely cracks 4 KB).
local SCRATCH_WCHARS = 8192

function M.get(name)
    local wname = W.ToWide(name)
    local buf = ffi.new("unsigned short[?]", SCRATCH_WCHARS)
    local n = C.GetEnvironmentVariableW(wname, buf, SCRATCH_WCHARS)
    if n == 0 then return nil end
    -- result might need a bigger buffer; n is the required size including null
    if n >= SCRATCH_WCHARS then
        local bigger = ffi.new("unsigned short[?]", n + 1)
        n = C.GetEnvironmentVariableW(wname, bigger, n + 1)
        if n == 0 then return nil end
        return W.FromWide(bigger)
    end
    return W.FromWide(buf)
end

function M.set(name, value)
    local wname = W.ToWide(name)
    local wvalue
    if value == nil then
        wvalue = nil  -- deletes the variable per Win32 docs
    else
        wvalue = W.ToWide(value)
    end
    if C.SetEnvironmentVariableW(wname, wvalue) == 0 then
        return false, "SetEnvironmentVariableW failed: " .. tonumber(C.GetLastError())
    end
    return true
end

function M.unset(name)
    return M.set(name, nil)
end

-- ===== expand ============================================================

function M.expand(s)
    local wsrc = W.ToWide(s)
    local buf = ffi.new("unsigned short[?]", SCRATCH_WCHARS)
    local n = C.ExpandEnvironmentStringsW(wsrc, buf, SCRATCH_WCHARS)
    if n == 0 then
        return nil, "ExpandEnvironmentStringsW failed: " .. tonumber(C.GetLastError())
    end
    if n > SCRATCH_WCHARS then
        local bigger = ffi.new("unsigned short[?]", n + 1)
        if C.ExpandEnvironmentStringsW(wsrc, bigger, n + 1) == 0 then
            return nil, "ExpandEnvironmentStringsW failed: " .. tonumber(C.GetLastError())
        end
        return W.FromWide(bigger)
    end
    return W.FromWide(buf)
end

-- ===== list ==============================================================

-- GetEnvironmentStringsW returns a double-null-terminated block:
--   NAME1=VALUE1\0NAME2=VALUE2\0...\0\0
-- We walk it as UTF-16 until the empty entry, splitting on '=' per entry.

local function wide_block_to_pairs(wptr)
    local out = {}
    local i = 0  -- WCHAR offset
    while true do
        -- find the next null terminator
        local start = i
        while wptr[i] ~= 0 do i = i + 1 end
        local wlen = i - start
        if wlen == 0 then break end  -- empty entry = end of block
        -- extract a Lua UTF-16 substring then convert
        local sub = ffi.new("unsigned short[?]", wlen + 1)
        ffi.copy(sub, wptr + start, wlen * 2)
        sub[wlen] = 0
        local line = W.FromWide(sub)
        -- split at first '='; some entries start with '=' (drive-letter
        -- cwd entries like "=C:=C:\Users\..." -- preserve them as-is)
        local eq = line:find("=", 2, true)
        if eq then
            local k = line:sub(1, eq - 1)
            local v = line:sub(eq + 1)
            out[k] = v
        end
        i = i + 1  -- skip the null we stopped on
    end
    return out
end

function M.list()
    local block = C.GetEnvironmentStringsW()
    if block == nil then
        return nil, "GetEnvironmentStringsW failed"
    end
    local ok, result = pcall(wide_block_to_pairs, block)
    C.FreeEnvironmentStringsW(block)
    if not ok then error(result) end
    return result
end

-- ===== scoped overrides ==================================================
--
-- with({HOME = "x", DEBUG = env.UNSET}, fn, ...) snapshots the listed vars,
-- applies the overrides, calls fn, then restores -- even on error. Use the
-- sentinel env.UNSET as a value to remove a var for the duration (a literal
-- `nil` cannot be stored in a Lua table, so it would simply be absent from
-- `overrides` and do nothing).

-- Sentinel meaning "delete this variable for the scope".
M.UNSET = setmetatable({}, { __tostring = function() return "env.UNSET" end })

function M.with(overrides, fn, ...)
    if type(overrides) ~= "table" then
        error("env.with: first arg must be a table of name=value pairs")
    end
    -- Snapshot every touched key as an explicit {key, prev} pair: a plain
    -- saved[k]=nil would be dropped from the table, so a var that was ABSENT
    -- before would never get removed on restore (it would leak the override).
    local snapshot = {}
    for k in pairs(overrides) do
        snapshot[#snapshot + 1] = { k, M.get(k) }
    end
    -- apply (env.UNSET deletes for the duration)
    for k, v in pairs(overrides) do
        if v == M.UNSET then M.unset(k) else M.set(k, v) end
    end
    -- run
    local results = { pcall(fn, ...) }
    -- restore (always): set back to prior value, or unset if it was absent
    for i = #snapshot, 1, -1 do
        local k, prev = snapshot[i][1], snapshot[i][2]
        if prev == nil then M.unset(k) else M.set(k, prev) end
    end
    -- re-raise if fn threw
    if not results[1] then error(results[2]) end
    return table.unpack(results, 2)
end

return M
