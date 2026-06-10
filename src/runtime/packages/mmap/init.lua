-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- mmap -- memory-mapped files.
--
-- Public surface:
--   mmap.open(path, mode?) -> mmap_obj | nil, err
--     mode = "r"             read-only (default)
--            "rw"            read + write (modifies backing file)
--            "copy_on_write" maps with PAGE_WRITECOPY (changes private)
--
--   m:size()                -> bytes
--   m:read(off, len)        -> Lua string slice
--   m:write(off, bytes)     -> true | nil, err (rw / cow only)
--   m:slice(off, len)       -> cdata "unsigned char *" pointing into the view
--                              (bounds-checked at call time)
--   m:flush(off?, len?)     -> true | nil, err  (FlushViewOfFile)
--   m:as_string()           -> entire view as one Lua string (copies)
--   m:close()               -> true
--
-- Garbage-collected: if the object is collected, the view + handles are
-- released via a __gc metamethod.

local W   = require "windows"
local _FSW = require "windows.filesystem"
local _MEM = require "windows.memory"
local path = require "path"

local C   = ffi.C
local M   = {}

-- ===== Local cdefs (avoid clashing with windows.filesystem / memory) =====

ffi.cdef[[
typedef struct _mmap_OVERLAPPED {
    ULONGLONG  Internal;
    ULONGLONG  InternalHigh;
    ULONGLONG  Offset;
    HANDLE     hEvent;
} mmap_OVERLAPPED;

HANDLE   CreateFileMappingW(HANDLE, SECURITY_ATTRIBUTES *, DWORD, DWORD, DWORD, unsigned short *);
void *   MapViewOfFile(HANDLE, DWORD, DWORD, DWORD, void *);
BOOL     UnmapViewOfFile(void *);
BOOL     FlushViewOfFile(void *, void *);
BOOL     CloseHandle(HANDLE);
HANDLE   CreateFileW(unsigned short *, DWORD, DWORD, SECURITY_ATTRIBUTES *, DWORD, DWORD, HANDLE);
BOOL     GetFileSizeEx(HANDLE, long long *);
DWORD    GetLastError(void);
]]

-- ===== Constants ========================================================

local GENERIC_READ          = 0x80000000
local GENERIC_WRITE         = 0x40000000
local FILE_SHARE_READ       = 0x00000001
local FILE_SHARE_WRITE      = 0x00000002
local OPEN_EXISTING         = 3
local INVALID_HANDLE_VALUE  = ffi.cast("HANDLE", -1)

local PAGE_READONLY         = 0x02
local PAGE_READWRITE        = 0x04
local PAGE_WRITECOPY        = 0x08

local FILE_MAP_READ         = 0x0004
local FILE_MAP_WRITE        = 0x0002    -- write also grants read
local FILE_MAP_COPY         = 0x0001

-- ===== UTF-8 -> wide ====================================================

local function wide_path(p)
    -- Apply long-path prefix when absolute and over ~MAX_PATH.
    local q = p
    if #p > 240 and path.is_absolute(p) then q = path.long_prefix(p) end
    local cp_utf8 = 65001
    local need = C.MultiByteToWideChar(cp_utf8, 0, q, -1, nil, 0)
    if need <= 0 then return nil, "MultiByteToWideChar failed sizing" end
    if need > 32768 then return nil, "path too long" end
    local buf = ffi.new("unsigned short[?]", need)
    if C.MultiByteToWideChar(cp_utf8, 0, q, -1, buf, need) <= 0 then
        return nil, "MultiByteToWideChar failed"
    end
    return buf
end

local function last_err(action)
    return string.format("%s failed (Win32 error %d)", action, C.GetLastError())
end

-- ===== Object metatable ================================================

local mt = { __index = {} }

function mt.__index:size()
    return tonumber(self._size)
end

local function check_range(self, off, len)
    if off < 0 then return false, "mmap: negative offset" end
    if len < 0 then return false, "mmap: negative length" end
    if off + len > tonumber(self._size) then
        return false, "mmap: out of bounds (off=" .. off ..
                      " len=" .. len .. " size=" .. tonumber(self._size) .. ")"
    end
    return true
end

function mt.__index:read(off, len)
    if self._closed then return nil, "mmap: closed" end
    local ok, e = check_range(self, off, len)
    if not ok then return nil, e end
    local base = ffi.cast("char *", self._view)
    return ffi.string(base + off, len)
end

function mt.__index:write(off, bytes)
    if self._closed then return nil, "mmap: closed" end
    if self._mode == "r" then return nil, "mmap: not writable" end
    if type(bytes) ~= "string" then return nil, "mmap: bytes must be a string" end
    local len = #bytes
    local ok, e = check_range(self, off, len)
    if not ok then return nil, e end
    local base = ffi.cast("char *", self._view)
    ffi.copy(base + off, bytes, len)
    return true
end

function mt.__index:slice(off, len)
    if self._closed then error("mmap: closed", 2) end
    local ok, e = check_range(self, off, len)
    if not ok then error(e, 2) end
    local base = ffi.cast("unsigned char *", self._view)
    return base + off
end

function mt.__index:flush(off, len)
    if self._closed then return nil, "mmap: closed" end
    local base = ffi.cast("char *", self._view)
    local addr = base + (off or 0)
    local n = len or (tonumber(self._size) - (off or 0))
    -- FlushViewOfFile signature: BOOL FlushViewOfFile(void *, SIZE_T).
    -- SIZE_T is 64-bit on x64; we cast `n` to a void * to satisfy the cdef.
    local sz = ffi.cast("void *", ffi.cast("uintptr_t", n))
    if C.FlushViewOfFile(addr, sz) == 0 then
        return nil, last_err("FlushViewOfFile")
    end
    return true
end

function mt.__index:as_string()
    return self:read(0, tonumber(self._size))
end

function mt.__index:close()
    if self._closed then return true end
    if self._view ~= nil then
        C.UnmapViewOfFile(self._view)
        self._view = nil
    end
    if self._map ~= nil then
        C.CloseHandle(self._map)
        self._map = nil
    end
    if self._file ~= nil and self._file ~= INVALID_HANDLE_VALUE then
        C.CloseHandle(self._file)
        self._file = nil
    end
    self._closed = true
    return true
end

mt.__gc = function(self) self:close() end

-- ===== open() ===========================================================

function M.open(p, mode_or_opts)
    -- Accept either the legacy "r"/"rw"/"copy_on_write" string mode or
    -- the modern opts table {mode=, size=, offset=}.
    local mode, want_size, offset
    if type(mode_or_opts) == "table" then
        mode = mode_or_opts.mode or "r"
        want_size = mode_or_opts.size
        offset = mode_or_opts.offset or 0
        -- Accept "ro" alias.
        if mode == "ro" then mode = "r" end
    else
        mode = mode_or_opts or "r"
        if mode == "ro" then mode = "r" end
        offset = 0
    end
    if mode ~= "r" and mode ~= "rw" and mode ~= "copy_on_write" then
        return nil, "mmap.open: unknown mode '" .. tostring(mode) .. "'"
    end

    local wp, werr = wide_path(p)
    if not wp then return nil, werr end

    local access, share, page_prot, map_prot
    if mode == "r" then
        access    = GENERIC_READ
        share     = bit.bor(FILE_SHARE_READ, FILE_SHARE_WRITE)
        page_prot = PAGE_READONLY
        map_prot  = FILE_MAP_READ
    elseif mode == "rw" then
        access    = bit.bor(GENERIC_READ, GENERIC_WRITE)
        share     = FILE_SHARE_READ
        page_prot = PAGE_READWRITE
        map_prot  = FILE_MAP_WRITE
    else  -- copy_on_write
        access    = GENERIC_READ
        share     = bit.bor(FILE_SHARE_READ, FILE_SHARE_WRITE)
        page_prot = PAGE_WRITECOPY
        map_prot  = FILE_MAP_COPY
    end

    local h_file = C.CreateFileW(wp, access, share, nil, OPEN_EXISTING, 0, nil)
    if h_file == INVALID_HANDLE_VALUE then
        return nil, last_err("CreateFileW")
    end

    -- Size.
    local sz_box = ffi.new("long long[1]")
    if C.GetFileSizeEx(h_file, sz_box) == 0 then
        C.CloseHandle(h_file)
        return nil, last_err("GetFileSizeEx")
    end
    local file_size = tonumber(sz_box[0])
    if file_size == 0 then
        C.CloseHandle(h_file)
        return nil, "mmap.open: cannot map a zero-byte file"
    end
    local size = want_size or (file_size - offset)
    if size <= 0 then
        C.CloseHandle(h_file)
        return nil, "mmap.open: requested size <= 0 after offset"
    end

    -- Create file mapping object (max size = file size, both halves 0 = use file size).
    local h_map = C.CreateFileMappingW(h_file, nil, page_prot, 0, 0, nil)
    if h_map == nil or h_map == INVALID_HANDLE_VALUE then
        local e = last_err("CreateFileMappingW")
        C.CloseHandle(h_file)
        return nil, e
    end

    -- MapViewOfFile splits the 64-bit offset into two DWORDs.
    local off_lo = bit.band(offset, 0xFFFFFFFF)
    local off_hi = math.floor(offset / 0x100000000)
    local view = C.MapViewOfFile(h_map, map_prot, off_hi, off_lo, ffi.cast("void *", ffi.cast("uintptr_t", size)))
    if view == nil then
        local e = last_err("MapViewOfFile")
        C.CloseHandle(h_map)
        C.CloseHandle(h_file)
        return nil, e
    end

    local obj = setmetatable({
        _file   = h_file,
        _map    = h_map,
        _view   = view,
        _size   = ffi.cast("uint64_t", size),
        _mode   = mode,
        _closed = false,
        _path   = p,
        _offset = offset,
    }, mt)

    return obj
end

-- ===== Modern object methods (additive) =================================

-- :ptr() -- raw view pointer (unsigned char *) for FFI use.
function mt.__index:ptr()
    if self._closed then return nil end
    return ffi.cast("unsigned char *", self._view)
end

-- :bytes(off?, len?) -- alias for :read(off?, len?) but with defaults
-- so :bytes() returns the entire view.
function mt.__index:bytes(off, len)
    if self._closed then return nil, "mmap: closed" end
    off = off or 0
    len = len or (tonumber(self._size) - off)
    return self:read(off, len)
end

-- ===== anonymous(size) ===================================================
--
-- Page-aligned anonymous (file-backed by the system pagefile) mapping.
-- Useful as a large RW buffer that's shared between threads / processes
-- when given a name. Single-process anonymous mappings use NULL name.

-- CreateFileMappingW is already cdef'd above; GetCurrentProcess lives
-- in the windows package. anonymous() reuses the existing symbols.

function M.anonymous(size, opts)
    opts = opts or {}
    if not size or size <= 0 then return nil, "mmap.anonymous: size must be > 0" end

    -- INVALID_HANDLE_VALUE as the file handle = back the mapping with the
    -- system pagefile.
    local hi = math.floor(size / 0x100000000)
    local lo = bit.band(size, 0xFFFFFFFF)
    local INVALID = ffi.cast("HANDLE", -1)
    local h_map = C.CreateFileMappingW(INVALID, nil, PAGE_READWRITE, hi, lo, nil)
    if h_map == nil or h_map == INVALID then
        return nil, last_err("CreateFileMappingW")
    end
    local view = C.MapViewOfFile(h_map, FILE_MAP_WRITE, 0, 0, ffi.cast("void *", ffi.cast("uintptr_t", size)))
    if view == nil then
        local e = last_err("MapViewOfFile")
        C.CloseHandle(h_map)
        return nil, e
    end
    return setmetatable({
        _file   = nil,
        _map    = h_map,
        _view   = view,
        _size   = ffi.cast("uint64_t", size),
        _mode   = "rw",
        _closed = false,
        _path   = "<anonymous>",
        _offset = 0,
    }, mt)
end

return M
