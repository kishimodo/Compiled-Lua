-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- mem -- cross-process memory + AOB pattern scanning.
--
-- Public surface:
--   mem.open_process(pid_or_handle, access?)  -> proc
--   mem.self()                                -> proc (pseudo-handle, current process)
--   mem.self_read(addr, n)                    -> bytes
--   mem.self_write(addr, bytes)               -> nbytes_written
--   mem.scan(proc, pattern, opts?)            -> { addr, ... }   (all matches)
--   mem.find(proc, pattern, opts?)            -> addr | nil      (first match)
--   mem.find_all(proc, pattern, opts?)        -> alias for scan
--   mem.compile_pattern(pattern)              -> { bytes={...}, mask={...} }
--
-- proc methods:
--   :read(addr, n)                  -> bytes
--   :write(addr, bytes)             -> n_written
--   :read_int8/16/32/64(addr)       -> signed integer
--   :read_uint8/16/32/64(addr)      -> unsigned integer
--   :read_float(addr) / :read_double(addr)
--   :read_string(addr, max?)        -> ASCII C-string (auto null-terminated)
--   :read_wstring(addr, max?)       -> UTF-16LE C-string decoded to UTF-8
--   :write_int8/16/32/64(addr, v)   -> bytes_written
--   :write_uint8/16/32/64(addr, v)  -> bytes_written
--   :write_float / :write_double
--   :protect(addr, size, new)       -> old_protect
--   :query(addr)                    -> MEMORY_BASIC_INFORMATION-like table
--   :regions()                      -> iterator over all committed regions
--   :alloc(size, type?, protect?)   -> base addr
--   :free(addr, size?, type?)
--   :modules()                      -> { {name, path, base, size}, ... }
--   :find_module(name)              -> { name, base, size, path } or nil
--   :scan(pattern, opts?)           -> matches
--   :scan_all(pattern, opts?)       -> all matches
--   :scan_module(name, pattern, opts?) -> matches within a module's range
--   :close()
--
-- Pattern syntax (CE-compatible):
--   "48 8B ? ? ? ? 48 89"      -- "?" or "??" or "*" = single-byte wildcard
--   "DEADBEEF"                 -- contiguous hex also accepted
--
-- Why no NtRead/NtWriteVirtualMemory: ReadProcessMemory/WriteProcessMemory
-- already wrap the syscall and handle partial reads (cross-region tears)
-- via the lpNumberOfBytesRead out-param. Going to Nt* would buy nothing
-- here but a longer cdef. (See mem.scan's chunking comment below.)

require "windows"
local W = require "windows"

ffi.cdef[[
BOOL ReadProcessMemory(HANDLE hProcess, LPCVOID lpBaseAddress, LPVOID lpBuffer,
                       ULONGLONG nSize, ULONGLONG *lpNumberOfBytesRead);
BOOL WriteProcessMemory(HANDLE hProcess, LPVOID lpBaseAddress, LPCVOID lpBuffer,
                        ULONGLONG nSize, ULONGLONG *lpNumberOfBytesWritten);
BOOL VirtualProtectEx(HANDLE hProcess, LPVOID lpAddress, ULONGLONG dwSize,
                      DWORD flNewProtect, LPDWORD lpflOldProtect);
ULONGLONG VirtualQueryEx(HANDLE hProcess, LPCVOID lpAddress,
                         MEMORY_BASIC_INFORMATION *lpBuffer, ULONGLONG dwLength);
LPVOID VirtualAllocEx(HANDLE hProcess, LPVOID lpAddress, ULONGLONG dwSize,
                      DWORD flAllocationType, DWORD flProtect);
BOOL VirtualFreeEx(HANDLE hProcess, LPVOID lpAddress, ULONGLONG dwSize, DWORD dwFreeType);
]]

local M = {}

local _ReadProcessMemory  = ffi.C.ReadProcessMemory
local _WriteProcessMemory = ffi.C.WriteProcessMemory
local _VirtualProtectEx   = ffi.C.VirtualProtectEx
local _VirtualQueryEx     = ffi.C.VirtualQueryEx
local _OpenProcess        = ffi.C.OpenProcess
local _CloseHandle        = ffi.C.CloseHandle
local _GetCurrentProcess  = ffi.C.GetCurrentProcess
local _GetLastError       = ffi.C.GetLastError

-- ===== process handle wrapper ==========================================

local Proc = {}
Proc.__index = Proc

local function wrap_handle(h, pid, owned)
    local self = setmetatable({}, Proc)
    self._h = h
    self._pid = pid
    self._owned = owned and true or false
    return self
end

function M.open_process(pid_or_handle, access)
    -- Accept either a PID (number) or an existing HANDLE cdata. When a
    -- handle is passed in we don't take ownership (caller closes it).
    if type(pid_or_handle) == "cdata" then
        return wrap_handle(pid_or_handle, nil, false)
    end
    local pid = pid_or_handle
    access = access or
        bit.bor(W.PROCESS_QUERY_INFORMATION, W.PROCESS_VM_READ,
                W.PROCESS_VM_WRITE, W.PROCESS_VM_OPERATION)
    local h = _OpenProcess(access, false, pid)
    if h == nil or tonumber(ffi.cast("UINT_PTR", h)) == 0 then
        error(string.format("mem.open_process(%d): OpenProcess failed (GLE=%d)",
            pid, tonumber(_GetLastError())))
    end
    return wrap_handle(h, pid, true)
end

function M.self()
    -- GetCurrentProcess returns a pseudo-handle (-1) -- not closeable.
    return wrap_handle(_GetCurrentProcess(), nil, false)
end

function Proc:close()
    if self._owned and self._h ~= nil then
        _CloseHandle(self._h)
        self._h = nil
    end
end

-- ===== read / write ====================================================

local _read_buf_pool = {}  -- size -> cdata buffer, reused to dodge GC churn

local function get_read_buf(n)
    -- We don't truly pool by size -- just keep the largest buffer we've
    -- seen so far around. AOB scans hit one big size repeatedly.
    local cur = _read_buf_pool[1]
    if cur and ffi.sizeof(cur) >= n then return cur end
    local buf = ffi.new("uint8_t[?]", n)
    _read_buf_pool[1] = buf
    return buf
end

function Proc:read(addr, n)
    if n <= 0 then return "" end
    local buf = ffi.new("uint8_t[?]", n)  -- don't share: caller may keep slices
    local got = ffi.new("ULONGLONG[1]")
    local ok = _ReadProcessMemory(self._h, ffi.cast("LPCVOID", addr), buf, n, got)
    if ok == 0 then
        error(string.format("mem.read(0x%X, %d): RPM failed (GLE=%d)",
            addr, n, tonumber(_GetLastError())))
    end
    return ffi.string(buf, tonumber(got[0]))
end

function Proc:write(addr, bytes)
    if type(bytes) ~= "string" then error("mem.write: bytes must be a string") end
    if #bytes == 0 then return 0 end
    local got = ffi.new("ULONGLONG[1]")
    local ok = _WriteProcessMemory(self._h, ffi.cast("LPVOID", addr),
                                   ffi.cast("LPCVOID", bytes), #bytes, got)
    if ok == 0 then
        error(string.format("mem.write(0x%X, %d): WPM failed (GLE=%d)",
            addr, #bytes, tonumber(_GetLastError())))
    end
    return tonumber(got[0])
end

function Proc:protect(addr, size, new_protect)
    local old = ffi.new("DWORD[1]")
    local ok = _VirtualProtectEx(self._h, ffi.cast("LPVOID", addr), size, new_protect, old)
    if ok == 0 then
        error(string.format("mem.protect(0x%X, %d, 0x%X): failed (GLE=%d)",
            addr, size, new_protect, tonumber(_GetLastError())))
    end
    return tonumber(old[0])
end

function Proc:query(addr)
    local mbi = ffi.new("MEMORY_BASIC_INFORMATION")
    local got = _VirtualQueryEx(self._h, ffi.cast("LPCVOID", addr),
                                mbi, ffi.sizeof("MEMORY_BASIC_INFORMATION"))
    if got == 0 then
        return nil, string.format("VirtualQueryEx GLE=%d", tonumber(_GetLastError()))
    end
    return {
        base_address      = tonumber(ffi.cast("UINT_PTR", mbi.BaseAddress)),
        allocation_base   = tonumber(ffi.cast("UINT_PTR", mbi.AllocationBase)),
        allocation_protect = tonumber(mbi.AllocationProtect),
        region_size       = tonumber(mbi.RegionSize),
        state             = tonumber(mbi.State),
        protect           = tonumber(mbi.Protect),
        type              = tonumber(mbi.Type),
    }
end

-- Iterate over all committed memory regions in the target process.
-- Yields the same shape as :query() per region.
function Proc:regions()
    local h = self._h
    local addr = 0
    return function()
        while true do
            local mbi = ffi.new("MEMORY_BASIC_INFORMATION")
            local got = _VirtualQueryEx(h, ffi.cast("LPCVOID", addr),
                                        mbi, ffi.sizeof("MEMORY_BASIC_INFORMATION"))
            if got == 0 then return nil end
            local base = tonumber(ffi.cast("UINT_PTR", mbi.BaseAddress))
            local size = tonumber(mbi.RegionSize)
            local state = tonumber(mbi.State)
            -- bump cursor before we possibly skip the region
            addr = base + size
            if state == W.MEM_COMMIT then
                return {
                    base_address    = base,
                    allocation_base = tonumber(ffi.cast("UINT_PTR", mbi.AllocationBase)),
                    region_size     = size,
                    state           = state,
                    protect         = tonumber(mbi.Protect),
                    type            = tonumber(mbi.Type),
                }
            end
            -- Sanity guard: 64-bit user-mode tops out well below 2^48 on
            -- current Windows, but ARM64 and future kernels could change
            -- that. Bail when VirtualQueryEx wraps.
            if addr >= 0x800000000000 or size == 0 then return nil end
        end
    end
end

-- ===== typed primitive reads / writes ==================================

local function read_typed(self, addr, ctype, size)
    local buf = ffi.new(ctype .. "[1]")
    local got = ffi.new("ULONGLONG[1]")
    local ok = _ReadProcessMemory(self._h, ffi.cast("LPCVOID", addr),
                                  buf, size, got)
    if ok == 0 then
        error(string.format("mem.read_%s(0x%X): RPM failed (GLE=%d)",
            ctype, addr, tonumber(_GetLastError())))
    end
    return buf[0]
end

local function write_typed(self, addr, value, ctype, size)
    local buf = ffi.new(ctype .. "[1]", value)
    local got = ffi.new("ULONGLONG[1]")
    local ok = _WriteProcessMemory(self._h, ffi.cast("LPVOID", addr),
                                   buf, size, got)
    if ok == 0 then
        error(string.format("mem.write_%s(0x%X): WPM failed (GLE=%d)",
            ctype, addr, tonumber(_GetLastError())))
    end
    return tonumber(got[0])
end

function Proc:read_int8(addr)   return tonumber(read_typed(self, addr, "int8_t", 1)) end
function Proc:read_int16(addr)  return tonumber(read_typed(self, addr, "int16_t", 2)) end
function Proc:read_int32(addr)  return tonumber(read_typed(self, addr, "int32_t", 4)) end
function Proc:read_int64(addr)  return read_typed(self, addr, "int64_t", 8) end
function Proc:read_uint8(addr)  return tonumber(read_typed(self, addr, "uint8_t", 1)) end
function Proc:read_uint16(addr) return tonumber(read_typed(self, addr, "uint16_t", 2)) end
function Proc:read_uint32(addr) return tonumber(read_typed(self, addr, "uint32_t", 4)) end
function Proc:read_uint64(addr) return read_typed(self, addr, "uint64_t", 8) end
function Proc:read_float(addr)  return tonumber(read_typed(self, addr, "float", 4)) end
function Proc:read_double(addr) return tonumber(read_typed(self, addr, "double", 8)) end

function Proc:write_int8(addr, v)   return write_typed(self, addr, v, "int8_t", 1)  end
function Proc:write_int16(addr, v)  return write_typed(self, addr, v, "int16_t", 2) end
function Proc:write_int32(addr, v)  return write_typed(self, addr, v, "int32_t", 4) end
function Proc:write_int64(addr, v)  return write_typed(self, addr, v, "int64_t", 8) end
function Proc:write_uint8(addr, v)  return write_typed(self, addr, v, "uint8_t", 1)  end
function Proc:write_uint16(addr, v) return write_typed(self, addr, v, "uint16_t", 2) end
function Proc:write_uint32(addr, v) return write_typed(self, addr, v, "uint32_t", 4) end
function Proc:write_uint64(addr, v) return write_typed(self, addr, v, "uint64_t", 8) end
function Proc:write_float(addr, v)  return write_typed(self, addr, v, "float", 4)   end
function Proc:write_double(addr, v) return write_typed(self, addr, v, "double", 8)  end

-- Read an ASCII / UTF-8 C-string. Reads in chunks until NUL or max.
function Proc:read_string(addr, max)
    max = max or 4096
    local chunk = 256
    local out = {}
    local pos = 0
    while pos < max do
        local take = math.min(chunk, max - pos)
        local ok, data = pcall(function() return self:read(addr + pos, take) end)
        if not ok or not data or #data == 0 then break end
        local nul = data:find("\0", 1, true)
        if nul then
            out[#out + 1] = data:sub(1, nul - 1)
            return table.concat(out)
        end
        out[#out + 1] = data
        pos = pos + #data
        if #data < take then break end
    end
    return table.concat(out)
end

-- Read a UTF-16LE C-string. BMP fast path only.
function Proc:read_wstring(addr, max_chars)
    max_chars = max_chars or 2048
    local raw = self:read(addr, max_chars * 2)
    local out = {}
    local i = 1
    while i + 1 <= #raw do
        local lo = raw:byte(i)
        local hi = raw:byte(i + 1)
        local c = lo + hi * 256
        if c == 0 then break end
        if c < 0x80 then
            out[#out + 1] = string.char(c)
        elseif c < 0x800 then
            out[#out + 1] = string.char(0xC0 + math.floor(c / 0x40),
                0x80 + (c % 0x40))
        else
            out[#out + 1] = string.char(0xE0 + math.floor(c / 0x1000),
                0x80 + (math.floor(c / 0x40) % 0x40),
                0x80 + (c % 0x40))
        end
        i = i + 2
    end
    return table.concat(out)
end

-- ===== alloc / free in target =========================================

function Proc:alloc(size, alloc_type, protect)
    alloc_type = alloc_type or bit.bor(W.MEM_COMMIT, W.MEM_RESERVE)
    protect = protect or W.PAGE_READWRITE
    local p = ffi.C.VirtualAllocEx(self._h, nil, size, alloc_type, protect)
    if p == nil then
        error(string.format("mem.alloc(%d): VirtualAllocEx failed (GLE=%d)",
            size, tonumber(_GetLastError())))
    end
    return tonumber(ffi.cast("UINT_PTR", p))
end

function Proc:free(addr, size, free_type)
    size = size or 0
    free_type = free_type or W.MEM_RELEASE
    local ok = ffi.C.VirtualFreeEx(self._h, ffi.cast("LPVOID", addr), size, free_type)
    if ok == 0 then
        error(string.format("mem.free(0x%X): VirtualFreeEx failed (GLE=%d)",
            addr, tonumber(_GetLastError())))
    end
    return true
end

-- ===== modules (uses Toolhelp snapshot of the underlying PID) ==========

local _toolhelp_loaded = false
local function load_toolhelp()
    if _toolhelp_loaded then return end
    require "windows.toolhelp"
    _toolhelp_loaded = true
end

ffi.cdef[[
DWORD GetProcessId(HANDLE Process);
]]

local function pid_for(self)
    if self._pid then return self._pid end
    local pid = tonumber(ffi.C.GetProcessId(self._h))
    if pid ~= 0 then self._pid = pid end
    return pid
end

function Proc:modules()
    load_toolhelp()
    local TH = require "windows.toolhelp"
    local pid = pid_for(self)
    if not pid or pid == 0 then return {} end
    local snap = ffi.C.CreateToolhelp32Snapshot(
        bit.bor(TH.TH32CS_SNAPMODULE, TH.TH32CS_SNAPMODULE32), pid)
    if snap == W.INVALID_HANDLE_VALUE then return {} end
    local out = {}
    local me = ffi.new("MODULEENTRY32W")
    me.dwSize = ffi.sizeof("MODULEENTRY32W")
    if ffi.C.Module32FirstW(snap, me) ~= 0 then
        repeat
            -- Convert UTF-16 module name (BMP fast path).
            local function wide_to_str(wbuf, maxn)
                local s = {}
                for i = 0, maxn - 1 do
                    local c = wbuf[i]
                    if c == 0 then break end
                    if c < 0x80 then s[#s + 1] = string.char(c)
                    elseif c < 0x800 then
                        s[#s + 1] = string.char(0xC0 + math.floor(c / 0x40),
                            0x80 + (c % 0x40))
                    else
                        s[#s + 1] = string.char(0xE0 + math.floor(c / 0x1000),
                            0x80 + (math.floor(c / 0x40) % 0x40),
                            0x80 + (c % 0x40))
                    end
                end
                return table.concat(s)
            end
            out[#out + 1] = {
                name = wide_to_str(me.szModule, 256),
                path = wide_to_str(me.szExePath, 260),
                base = tonumber(ffi.cast("UINT_PTR", me.modBaseAddr)),
                size = tonumber(me.modBaseSize),
            }
        until ffi.C.Module32NextW(snap, me) == 0
    end
    ffi.C.CloseHandle(snap)
    return out
end

function Proc:find_module(name)
    if not name then return nil end
    local target = name:lower()
    for _, m in ipairs(self:modules()) do
        if m.name and m.name:lower() == target then return m end
    end
    -- Allow a substring match as fallback so callers can pass just the base
    -- name without extension.
    for _, m in ipairs(self:modules()) do
        if m.name and m.name:lower():find(target, 1, true) then return m end
    end
    return nil
end

-- ===== self_* shortcuts ================================================

local _self_proc -- lazy-init
local function self_proc()
    _self_proc = _self_proc or M.self()
    return _self_proc
end

function M.self_read(addr, n)  return self_proc():read(addr, n)  end
function M.self_write(addr, b) return self_proc():write(addr, b) end

-- ===== pattern compilation =============================================

local _pat_cache = setmetatable({}, { __mode = "k" })

local function hex_nibble(c)
    if c >= 0x30 and c <= 0x39 then return c - 0x30 end
    if c >= 0x41 and c <= 0x46 then return c - 0x41 + 10 end
    if c >= 0x61 and c <= 0x66 then return c - 0x61 + 10 end
    return nil
end

function M.compile_pattern(pat)
    local cached = _pat_cache[pat]
    if cached then return cached end

    local bytes, mask = {}, {}
    local i, n = 1, #pat
    while i <= n do
        local c = pat:byte(i)
        if c == 0x20 or c == 0x09 then  -- space / tab
            i = i + 1
        elseif c == 0x3F or c == 0x2A then  -- ? or *
            bytes[#bytes + 1] = 0
            mask[#mask + 1]   = false
            -- accept "??" as a single wildcard
            if i + 1 <= n and (pat:byte(i + 1) == 0x3F or pat:byte(i + 1) == 0x2A) then
                i = i + 2
            else
                i = i + 1
            end
        else
            local hi = hex_nibble(c)
            local c2 = pat:byte(i + 1)
            local lo = c2 and hex_nibble(c2) or nil
            if not hi or not lo then
                error("mem.compile_pattern: bad hex at offset " .. tostring(i - 1))
            end
            bytes[#bytes + 1] = hi * 16 + lo
            mask[#mask + 1]   = true
            i = i + 2
        end
    end
    if #bytes == 0 then error("mem.compile_pattern: empty pattern") end
    local out = { bytes = bytes, mask = mask, len = #bytes }
    _pat_cache[pat] = out
    return out
end

-- ===== scanner =========================================================

-- Search a single Lua-string chunk for the compiled pattern, returning
-- match offsets within the chunk.
local function scan_chunk(chunk, cp)
    local len = cp.len
    local pbytes = cp.bytes
    local pmask  = cp.mask
    local clen = #chunk
    if clen < len then return {} end
    local out = {}
    -- Fast first-byte filter: if mask[1] is true we can fast-path with
    -- string.find on the first concrete byte.
    if pmask[1] then
        local first = string.char(pbytes[1])
        local pos = 1
        while true do
            local i = chunk:find(first, pos, true)
            if not i then break end
            if i + len - 1 <= clen then
                local ok = true
                for j = 2, len do
                    if pmask[j] and chunk:byte(i + j - 1) ~= pbytes[j] then
                        ok = false
                        break
                    end
                end
                if ok then out[#out + 1] = i - 1 end
            else
                break
            end
            pos = i + 1
        end
    else
        -- Wildcard-first: O(n*m) brute force. Patterns rarely start with ??.
        for i = 1, clen - len + 1 do
            local ok = true
            for j = 1, len do
                if pmask[j] and chunk:byte(i + j - 1) ~= pbytes[j] then
                    ok = false
                    break
                end
            end
            if ok then out[#out + 1] = i - 1 end
        end
    end
    return out
end

-- mem.scan options:
--   start, stop  -- limit address range
--   limit        -- stop after N matches
--   exec_only    -- only scan PAGE_EXECUTE* regions
--   readable_only -- skip PAGE_NOACCESS / PAGE_GUARD
--   chunk_size   -- read chunk size (default 64 KiB)
function M.scan(proc, pattern, opts)
    opts = opts or {}
    local cp = M.compile_pattern(pattern)
    local chunk_size = opts.chunk_size or 0x10000
    local limit = opts.limit or math.huge
    local start_addr = opts.start or 0
    local stop_addr  = opts.stop  or math.huge

    local out = {}
    for mbi in proc:regions() do
        local base = mbi.base_address
        local size = mbi.region_size
        local rend = base + size
        if rend > start_addr and base < stop_addr then
            local prot = mbi.protect
            local readable = prot and prot ~= W.PAGE_NOACCESS
                and (prot % 0x200) < 0x100  -- not PAGE_GUARD
            local exec = prot and (prot == W.PAGE_EXECUTE
                or prot == W.PAGE_EXECUTE_READ
                or prot == W.PAGE_EXECUTE_READWRITE)
            local skip = false
            if opts.readable_only ~= false and not readable then skip = true end
            if opts.exec_only and not exec then skip = true end
            if not skip then
                local rstart = math.max(base, start_addr)
                local rfinish = math.min(rend, stop_addr)
                local cur = rstart
                local carry = ""  -- last (len-1) bytes of previous chunk
                while cur < rfinish do
                    local take = math.min(chunk_size, rfinish - cur)
                    local ok, data = pcall(function() return proc:read(cur, take) end)
                    if not ok then break end
                    local probe = (#carry > 0) and (carry .. data) or data
                    local matches = scan_chunk(probe, cp)
                    for _, off in ipairs(matches) do
                        local addr = cur - #carry + off
                        if addr >= rstart and addr + cp.len - 1 < rfinish then
                            out[#out + 1] = addr
                            if #out >= limit then return out end
                        end
                    end
                    if #data >= cp.len then
                        carry = data:sub(-(cp.len - 1))
                    else
                        carry = carry .. data
                        carry = carry:sub(-(cp.len - 1))
                    end
                    cur = cur + take
                end
            end
        end
        if mbi.base_address + mbi.region_size > stop_addr then break end
    end
    return out
end

function M.find(proc, pattern, opts)
    opts = opts or {}
    opts.limit = 1
    local r = M.scan(proc, pattern, opts)
    return r[1]
end

M.find_all = M.scan

-- ===== proc-level convenience wrappers =================================

function Proc:scan(pattern, opts)
    return M.scan(self, pattern, opts)
end

Proc.scan_all = Proc.scan

function Proc:scan_module(name, pattern, opts)
    local m = self:find_module(name)
    if not m then
        error(string.format("mem.scan_module: module '%s' not found", tostring(name)))
    end
    opts = opts or {}
    local o = {}
    for k, v in pairs(opts) do o[k] = v end
    o.start = m.base
    o.stop  = m.base + m.size
    return M.scan(self, pattern, o)
end

return M
