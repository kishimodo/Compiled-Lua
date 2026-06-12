-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- fs -- filesystem operations.
--
-- All paths are Lua strings (UTF-8). They get converted to UTF-16 at the
-- syscall boundary. Long paths (>MAX_PATH) get the "\\\\?\\" prefix
-- automatically before being handed to the kernel.
--
-- Errors: every fallible function returns nil, err_string on failure.
-- err_string includes the Win32 error code and a human description where
-- possible.

local W    = require "windows"
local FSW  = require "windows.filesystem"
local path = require "path"

local C    = ffi.C
local M    = {}

-- ===== Constants (named for clarity) ====================================

local GENERIC_READ    = 0x80000000
local GENERIC_WRITE   = 0x40000000
local FILE_SHARE_READ = 0x00000001
local FILE_SHARE_WRITE= 0x00000002
local FILE_SHARE_DELETE = 0x00000004
local OPEN_EXISTING   = 3
local CREATE_ALWAYS   = 2
local OPEN_ALWAYS     = 4
local INVALID_HANDLE_VALUE = ffi.cast("HANDLE", -1)

local FILE_ATTRIBUTE_DIRECTORY    = 0x00000010
local FILE_ATTRIBUTE_REPARSE_POINT= 0x00000400
local FILE_ATTRIBUTE_READONLY     = 0x00000001
local INVALID_FILE_ATTRIBUTES     = 0xFFFFFFFF
local FILE_FLAG_BACKUP_SEMANTICS  = 0x02000000
local FILE_FLAG_OPEN_REPARSE_POINT= 0x00200000

local MOVEFILE_REPLACE_EXISTING = 0x00000001
local MOVEFILE_COPY_ALLOWED     = 0x00000002

-- IO_REPARSE_TAG_SYMLINK indicates an actual symlink (vs other reparse
-- types like mount points). It's surfaced by GetFileAttributes via the
-- combination of REPARSE_POINT + IsReparseTagNameSurrogate; we keep
-- it simple by reporting any reparse point as a symlink for is_symlink().

-- ===== Helpers ==========================================================

local function last_error_str(action)
    local code = C.GetLastError()
    return string.format("%s failed (Win32 error %d)", action, code)
end

-- Convert a Lua UTF-8 string to a UTF-16LE buffer, handling long paths.
-- Always wide-character on Windows -- the W APIs are mandatory.
local function wide_path(p)
    -- Long-prefix if the path is >= MAX_PATH-ish.
    local q = p
    if #p > 240 and path.is_absolute(p) then
        q = path.long_prefix(p)
    end
    -- Need a UTF-8 -> UTF-16LE conversion. windows.ToWide caps at 2048
    -- WCHARs; for long paths we size dynamically.
    local cp_utf8 = 65001
    local need = C.MultiByteToWideChar(cp_utf8, 0, q, -1, nil, 0)
    if need <= 0 then
        return nil, "MultiByteToWideChar failed sizing"
    end
    -- Cap at 32k WCHARs (NTFS limit even with long-path).
    if need > 32768 then return nil, "path too long" end
    local buf = ffi.new("unsigned short[?]", need)
    local n = C.MultiByteToWideChar(cp_utf8, 0, q, -1, buf, need)
    if n <= 0 then return nil, "MultiByteToWideChar failed" end
    return buf
end

-- FILETIME (two DWORDs) -> Unix epoch seconds (float).
local function filetime_to_unix(ft)
    -- FILETIME counts 100ns intervals since 1601-01-01; Unix epoch is
    -- 1970-01-01 (offset 116444736000000000 of those units). The two fields are
    -- 32-bit DWORDs that marshal to Lua integers, so combine them with Lua's own
    -- 64-bit integer arithmetic -- this FFI does not implement arithmetic on
    -- uint64_t cdata (the old ffi.cast("uint64_t",..)*.. raised "attempt to
    -- perform arithmetic on a ffi.cdata.mt value", breaking fs.stat entirely).
    local high = tonumber(ft.dwHighDateTime) or 0
    local low  = tonumber(ft.dwLowDateTime) or 0
    local total = (high * 0x100000000) + low      -- fits a signed 64-bit Lua int
    local offset = 116444736000000000
    if total < offset then return 0 end
    local diff = total - offset
    -- 10_000_000 100ns units per second.
    return (diff // 10000000) + ((diff % 10000000) / 1e7)
end

-- BY_HANDLE_FILE_INFORMATION-shaped struct expected by ffi
ffi.cdef[[
typedef struct _fs_BY_HANDLE_FILE_INFORMATION {
    DWORD dwFileAttributes;
    FILETIME ftCreationTime;
    FILETIME ftLastAccessTime;
    FILETIME ftLastWriteTime;
    DWORD dwVolumeSerialNumber;
    DWORD nFileSizeHigh;
    DWORD nFileSizeLow;
    DWORD nNumberOfLinks;
    DWORD nFileIndexHigh;
    DWORD nFileIndexLow;
} fs_BY_HANDLE_FILE_INFORMATION;

typedef struct _fs_WIN32_FIND_DATAW {
    DWORD dwFileAttributes;
    FILETIME ftCreationTime;
    FILETIME ftLastAccessTime;
    FILETIME ftLastWriteTime;
    DWORD nFileSizeHigh;
    DWORD nFileSizeLow;
    DWORD dwReserved0;
    DWORD dwReserved1;
    unsigned short cFileName[260];
    unsigned short cAlternateFileName[14];
} fs_WIN32_FIND_DATAW;

typedef struct _fs_WIN32_FILE_ATTRIBUTE_DATA {
    DWORD dwFileAttributes;
    FILETIME ftCreationTime;
    FILETIME ftLastAccessTime;
    FILETIME ftLastWriteTime;
    DWORD nFileSizeHigh;
    DWORD nFileSizeLow;
} fs_WIN32_FILE_ATTRIBUTE_DATA;

BOOL GetFileInformationByHandle(HANDLE, fs_BY_HANDLE_FILE_INFORMATION *);
HANDLE FindFirstFileW(unsigned short *, fs_WIN32_FIND_DATAW *);
BOOL FindNextFileW(HANDLE, fs_WIN32_FIND_DATAW *);
BOOL GetFileAttributesExW(unsigned short *, int, void *);
DWORD GetFileAttributesW(unsigned short *);
BOOL SetFileAttributesW(unsigned short *, DWORD);
BOOL DeleteFileW(unsigned short *);
BOOL CreateDirectoryW(unsigned short *, SECURITY_ATTRIBUTES *);
BOOL RemoveDirectoryW(unsigned short *);
BOOL MoveFileExW(unsigned short *, unsigned short *, DWORD);
BOOL CopyFileW(unsigned short *, unsigned short *, BOOL);
DWORD GetTempPathW(DWORD, unsigned short *);
HANDLE CreateFileW(unsigned short *, DWORD, DWORD, SECURITY_ATTRIBUTES *, DWORD, DWORD, HANDLE);
BOOL GetFileSizeEx(HANDLE, long long *);
BOOL ReadFile(HANDLE, void *, DWORD, DWORD *, OVERLAPPED *);
BOOL WriteFile(HANDLE, const void *, DWORD, DWORD *, OVERLAPPED *);
BOOL CloseHandle(HANDLE);
BOOL FindClose(HANDLE);
]]

-- ===== exists / attribute queries =======================================

-- Returns (attributes, nil) or (nil, err) -- caller checks attributes.
local function get_attrs(p)
    local wp, err = wide_path(p)
    if not wp then return nil, err end
    local attrs = C.GetFileAttributesW(wp)
    if attrs == INVALID_FILE_ATTRIBUTES then
        return nil, last_error_str("GetFileAttributesW")
    end
    return attrs
end

function M.exists(p)
    local wp, err = wide_path(p)
    if not wp then return false, err end
    local attrs = C.GetFileAttributesW(wp)
    return attrs ~= INVALID_FILE_ATTRIBUTES
end

function M.is_file(p)
    local attrs, _ = get_attrs(p)
    if not attrs then return false end
    if bit.band(attrs, FILE_ATTRIBUTE_DIRECTORY) ~= 0 then return false end
    return true
end

function M.is_dir(p)
    local attrs, _ = get_attrs(p)
    if not attrs then return false end
    return bit.band(attrs, FILE_ATTRIBUTE_DIRECTORY) ~= 0
end

function M.is_symlink(p)
    local attrs, _ = get_attrs(p)
    if not attrs then return false end
    return bit.band(attrs, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0
end

-- ===== stat =============================================================

function M.stat(p)
    local wp, werr = wide_path(p)
    if not wp then return nil, werr end
    -- GetFileAttributesExW with GetFileExInfoStandard = 0
    local fad = ffi.new("fs_WIN32_FILE_ATTRIBUTE_DATA")
    if C.GetFileAttributesExW(wp, 0, fad) == 0 then
        return nil, last_error_str("GetFileAttributesExW")
    end
    local attrs = fad.dwFileAttributes
    local is_dir = bit.band(attrs, FILE_ATTRIBUTE_DIRECTORY) ~= 0
    local is_link = bit.band(attrs, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0
    local size = (tonumber(fad.nFileSizeHigh) * 4294967296) + tonumber(fad.nFileSizeLow)
    local mode = bit.band(attrs, FILE_ATTRIBUTE_READONLY) ~= 0 and 0x124 or 0x1a4
    -- 0x124 = 0444 (read-only), 0x1a4 = 0644 (rw); approximation only.
    return {
        size       = size,
        mtime      = filetime_to_unix(fad.ftLastWriteTime),
        atime      = filetime_to_unix(fad.ftLastAccessTime),
        ctime      = filetime_to_unix(fad.ftCreationTime),
        mode       = mode,
        attributes = attrs,
        is_dir     = is_dir,
        is_file    = not is_dir and not is_link,
        is_symlink = is_link,
        type       = is_dir and "directory" or (is_link and "symlink" or "file"),
    }
end

-- ===== chmod ============================================================

-- We honor only the read-only bit (Windows's main equivalent to chmod).
-- mode is octal-ish; treat & 0o222 == 0 as "make read-only".
function M.chmod(p, mode)
    local wp, werr = wide_path(p)
    if not wp then return nil, werr end
    local attrs = C.GetFileAttributesW(wp)
    if attrs == INVALID_FILE_ATTRIBUTES then
        return nil, last_error_str("GetFileAttributesW")
    end
    local want_ro = bit.band(mode, 0x92) == 0   -- no write bits (0o222 = 0x92)
    if want_ro then
        attrs = bit.bor(attrs, FILE_ATTRIBUTE_READONLY)
    else
        attrs = bit.band(attrs, bit.bnot(FILE_ATTRIBUTE_READONLY))
    end
    if C.SetFileAttributesW(wp, attrs) == 0 then
        return nil, last_error_str("SetFileAttributesW")
    end
    return true
end

-- ===== mkdir / rmdir / remove / rename ==================================

function M.mkdir(p, recursive)
    if recursive then
        local norm = path.normalize(p)
        local parts = {}
        local cur = norm
        while true do
            local d, _ = path.split(cur)
            if d == "" or d == cur then break end
            -- Stop when we hit an existing directory or the anchor.
            if M.is_dir(d) then break end
            parts[#parts + 1] = cur
            cur = d
        end
        parts[#parts + 1] = nil   -- the final cur is either existing or anchor
        -- Create from outermost (last added) to innermost (norm).
        for i = #parts, 1, -1 do
            local target = parts[i]
            if not M.is_dir(target) then
                local wp, werr = wide_path(target)
                if not wp then return nil, werr end
                if C.CreateDirectoryW(wp, nil) == 0 then
                    -- 183 = ALREADY_EXISTS; ignore.
                    if C.GetLastError() ~= 183 then
                        return nil, last_error_str("CreateDirectoryW " .. target)
                    end
                end
            end
        end
        -- Final
        if not M.is_dir(norm) then
            local wp, werr = wide_path(norm)
            if not wp then return nil, werr end
            if C.CreateDirectoryW(wp, nil) == 0 then
                if C.GetLastError() ~= 183 then
                    return nil, last_error_str("CreateDirectoryW " .. norm)
                end
            end
        end
        return true
    end
    local wp, werr = wide_path(p)
    if not wp then return nil, werr end
    if C.CreateDirectoryW(wp, nil) == 0 then
        return nil, last_error_str("CreateDirectoryW")
    end
    return true
end

local function rmdir_one(p)
    local wp, werr = wide_path(p)
    if not wp then return nil, werr end
    if C.RemoveDirectoryW(wp) == 0 then
        return nil, last_error_str("RemoveDirectoryW")
    end
    return true
end

local rmdir_recursive
function M.rmdir(p, recursive)
    if not recursive then return rmdir_one(p) end
    -- Walk children first, deleting files and recursing into subdirs.
    local ok, err = rmdir_recursive(p)
    if not ok then return nil, err end
    return true
end

function M.remove(p)
    -- delete a single file (not a directory).
    local wp, werr = wide_path(p)
    if not wp then return nil, werr end
    -- Clear read-only attribute if needed (DeleteFile won't otherwise).
    local attrs = C.GetFileAttributesW(wp)
    if attrs ~= INVALID_FILE_ATTRIBUTES and bit.band(attrs, FILE_ATTRIBUTE_READONLY) ~= 0 then
        C.SetFileAttributesW(wp, bit.band(attrs, bit.bnot(FILE_ATTRIBUTE_READONLY)))
    end
    if C.DeleteFileW(wp) == 0 then
        return nil, last_error_str("DeleteFileW")
    end
    return true
end

function M.rename(old, new)
    local wold, e1 = wide_path(old)
    if not wold then return nil, e1 end
    local wnew, e2 = wide_path(new)
    if not wnew then return nil, e2 end
    local flags = bit.bor(MOVEFILE_REPLACE_EXISTING, MOVEFILE_COPY_ALLOWED)
    if C.MoveFileExW(wold, wnew, flags) == 0 then
        return nil, last_error_str("MoveFileExW")
    end
    return true
end

M.move = M.rename

function M.copy(src, dst, opts)
    opts = opts or {}
    local wsrc, e1 = wide_path(src)
    if not wsrc then return nil, e1 end
    local wdst, e2 = wide_path(dst)
    if not wdst then return nil, e2 end
    local fail_if_exists = opts.overwrite == false and 1 or 0
    if C.CopyFileW(wsrc, wdst, fail_if_exists) == 0 then
        return nil, last_error_str("CopyFileW")
    end
    return true
end

-- ===== list / walk / glob (forward declared) ============================

local function list_dir(p)
    local norm = path.normalize(p)
    local pattern = norm .. "\\*"
    local wp, werr = wide_path(pattern)
    if not wp then return nil, werr end
    local fd = ffi.new("fs_WIN32_FIND_DATAW")
    local h  = C.FindFirstFileW(wp, fd)
    if h == INVALID_HANDLE_VALUE then
        local code = C.GetLastError()
        if code == 2 or code == 3 then return {} end  -- not found / no entries
        return nil, string.format("FindFirstFileW failed (Win32 error %d)", code)
    end
    local out, n = {}, 0
    repeat
        -- cFileName is UTF-16; convert to UTF-8.
        local raw = ffi.string(ffi.cast("char *", fd.cFileName),
                               -- find null terminator within max 260 wide chars
                               (function()
                                   for i = 0, 259 do
                                       if fd.cFileName[i] == 0 then return i * 2 end
                                   end
                                   return 520
                               end)())
        -- We have UTF-16LE bytes in `raw`; decode via WideCharToMultiByte.
        local wchars = #raw / 2
        local need = C.WideCharToMultiByte(65001, 0, fd.cFileName, wchars, nil, 0, nil, nil)
        local name
        if need > 0 then
            local nb = ffi.new("char[?]", need + 1)
            C.WideCharToMultiByte(65001, 0, fd.cFileName, wchars, nb, need, nil, nil)
            name = ffi.string(nb, need)
        else
            name = ""
        end
        if name ~= "." and name ~= ".." then
            n = n + 1
            out[n] = name
        end
    until C.FindNextFileW(h, fd) == 0
    C.FindClose(h)
    return out
end

function M.list(p)
    return list_dir(p)
end

rmdir_recursive = function(p)
    if not M.is_dir(p) then
        -- Not a directory; try DeleteFile.
        return rmdir_one(p)
    end
    local names, err = list_dir(p)
    if not names then return nil, err end
    for _, name in ipairs(names) do
        local child = path.join(p, name)
        if M.is_dir(child) and not M.is_symlink(child) then
            local ok, e = rmdir_recursive(child)
            if not ok then return nil, e end
        else
            local ok, e = M.remove(child)
            if not ok then return nil, e end
        end
    end
    return rmdir_one(p)
end

-- walk: produces an iterator.
-- opts = { recursive=true, follow_symlinks=false, filter=fn(name, full_path, attrs) }
function M.walk(root, opts)
    opts = opts or {}
    local recursive = opts.recursive ~= false
    local follow    = opts.follow_symlinks == true
    local filter    = opts.filter

    -- Iterative DFS using a stack of directories to visit.
    local stack = { root }
    local pending_names, pending_dir = nil, nil
    local pending_idx = 0

    return function()
        while true do
            if pending_names and pending_idx < #pending_names then
                pending_idx = pending_idx + 1
                local name = pending_names[pending_idx]
                local full = path.join(pending_dir, name)
                local is_dir  = M.is_dir(full)
                local is_link = M.is_symlink(full)
                if filter and not filter(name, full, is_dir) then
                    -- skip
                else
                    if is_dir and recursive and (follow or not is_link) then
                        stack[#stack + 1] = full
                    end
                    return full
                end
            else
                -- Pull next directory off the stack.
                local nxt = stack[#stack]
                stack[#stack] = nil
                if not nxt then return nil end
                local names, err = list_dir(nxt)
                if not names then
                    -- yield an error via raise? we choose to silently skip
                    -- unreadable subdirectories; caller can filter beforehand.
                    pending_names = {}
                    pending_dir = nxt
                    pending_idx = 0
                else
                    pending_names = names
                    pending_dir = nxt
                    pending_idx = 0
                end
            end
        end
    end
end

-- glob: walk + match. Supports "**" for recursive descent.
function M.glob(pattern)
    local glob = require "glob"
    -- Decompose the pattern into a root + matcher. We anchor the walk at
    -- the longest literal prefix (no wildcard chars). Everything after is
    -- pure glob.
    local norm = path.to_native(pattern)
    -- Find first wildcard char.
    local first_wild
    do
        local n = #norm
        local i = 1
        while i <= n do
            local b = norm:byte(i)
            if b == 42 or b == 63 or b == 91 or b == 123 then
                first_wild = i; break
            end
            i = i + 1
        end
    end
    local root
    if not first_wild then
        -- No wildcards -- just check existence.
        return M.exists(norm) and { norm } or {}
    end
    -- Walk backward to the last separator before the wildcard.
    local sep_idx = 0
    for i = first_wild - 1, 1, -1 do
        local b = norm:byte(i)
        if b == 92 or b == 47 then sep_idx = i; break end
    end
    if sep_idx == 0 then
        root = "."
    else
        root = norm:sub(1, sep_idx - 1)
        if root == "" then root = "\\" end
    end
    local matcher = glob.compile(pattern)
    local results, n = {}, 0
    for p in M.walk(root, { recursive = true }) do
        if matcher(p) then
            n = n + 1; results[n] = p
        end
    end
    return results
end

-- ===== read / read_text / write / append ================================

local function open_read(p)
    local wp, werr = wide_path(p)
    if not wp then return nil, werr end
    local h = C.CreateFileW(wp, GENERIC_READ,
        bit.bor(FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_SHARE_DELETE),
        nil, OPEN_EXISTING, 0, nil)
    if h == INVALID_HANDLE_VALUE then
        return nil, last_error_str("CreateFileW")
    end
    return h
end

local function open_write(p, append)
    local wp, werr = wide_path(p)
    if not wp then return nil, werr end
    local disp = append and OPEN_ALWAYS or CREATE_ALWAYS
    local access = GENERIC_WRITE
    if append then access = bit.bor(access, GENERIC_READ) end
    local h = C.CreateFileW(wp, access,
        bit.bor(FILE_SHARE_READ),
        nil, disp, 0, nil)
    if h == INVALID_HANDLE_VALUE then
        return nil, last_error_str("CreateFileW")
    end
    return h
end

function M.read(p)
    local h, err = open_read(p)
    if not h then return nil, err end
    -- Query size.
    local size = ffi.new("long long[1]")
    if C.GetFileSizeEx(h, size) == 0 then
        local e = last_error_str("GetFileSizeEx")
        C.CloseHandle(h)
        return nil, e
    end
    local total = tonumber(size[0])
    if total == 0 then C.CloseHandle(h); return "" end
    if total > 0x7FFFFFFF then
        C.CloseHandle(h)
        return nil, "fs.read: file too large for single read (use mmap)"
    end
    local buf = ffi.new("char[?]", total)
    local nread = ffi.new("DWORD[1]")
    local pos = 0
    while pos < total do
        local chunk = total - pos
        if chunk > 0x10000000 then chunk = 0x10000000 end
        if C.ReadFile(h, buf + pos, chunk, nread, nil) == 0 then
            local e = last_error_str("ReadFile")
            C.CloseHandle(h)
            return nil, e
        end
        if nread[0] == 0 then break end
        pos = pos + nread[0]
    end
    C.CloseHandle(h)
    return ffi.string(buf, pos)
end

-- Encoding-aware text read.
function M.read_text(p, encoding)
    encoding = encoding or "utf8"
    local raw, err = M.read(p)
    if not raw then return nil, err end

    -- Strip BOM where present and detect overrides.
    if encoding == "utf8" then
        if #raw >= 3 and raw:byte(1) == 0xEF and raw:byte(2) == 0xBB and raw:byte(3) == 0xBF then
            return raw:sub(4)
        end
        return raw
    elseif encoding == "ascii" then
        return raw
    elseif encoding == "utf16le" or encoding == "utf16be" then
        local body = raw
        local is_be = (encoding == "utf16be")
        -- Strip BOM if present.
        if #body >= 2 then
            local b1, b2 = body:byte(1), body:byte(2)
            if b1 == 0xFF and b2 == 0xFE then
                body = body:sub(3); is_be = false
            elseif b1 == 0xFE and b2 == 0xFF then
                body = body:sub(3); is_be = true
            end
        end
        if #body % 2 ~= 0 then return nil, "fs.read_text: utf16 input has odd byte length" end
        local wchars = #body / 2
        local wbuf = ffi.new("unsigned short[?]", wchars)
        if is_be then
            for i = 0, wchars - 1 do
                wbuf[i] = body:byte(2 * i + 1) * 256 + body:byte(2 * i + 2)
            end
        else
            ffi.copy(wbuf, body, #body)
        end
        local need = C.WideCharToMultiByte(65001, 0, wbuf, wchars, nil, 0, nil, nil)
        if need <= 0 then return nil, "WideCharToMultiByte sizing failed" end
        local out = ffi.new("char[?]", need)
        C.WideCharToMultiByte(65001, 0, wbuf, wchars, out, need, nil, nil)
        return ffi.string(out, need)
    end
    return nil, "fs.read_text: unsupported encoding " .. tostring(encoding)
end

local function write_raw(h, data)
    local len = #data
    local nwritten = ffi.new("DWORD[1]")
    local pos = 0
    while pos < len do
        local chunk = len - pos
        if chunk > 0x10000000 then chunk = 0x10000000 end
        local cdata = ffi.cast("const char *", data) + pos
        if C.WriteFile(h, cdata, chunk, nwritten, nil) == 0 then
            return nil, last_error_str("WriteFile")
        end
        pos = pos + nwritten[0]
    end
    return true
end

function M.write(p, bytes)
    -- Atomic: write to temp + rename. We use a fixed ".tmp.<pid>" suffix
    -- in the same directory so the rename is on the same volume.
    if type(bytes) ~= "string" then
        return nil, "fs.write: bytes must be a string"
    end
    local dir, base = path.split(p)
    if dir == "" then dir = "." end
    local pid = tonumber(C.GetCurrentProcessId())
    -- Include nanosecond-ish counter to avoid clobbering parallel writers.
    local ctr = math.random(1, 2^31)
    local tmp = path.join(dir, "." .. base .. ".tmp." .. pid .. "." .. ctr)
    local h, err = open_write(tmp, false)
    if not h then return nil, err end
    local ok, werr = write_raw(h, bytes)
    C.CloseHandle(h)
    if not ok then
        -- Best-effort cleanup; ignore error.
        local wt = wide_path(tmp); if wt then C.DeleteFileW(wt) end
        return nil, werr
    end
    -- Atomic-replace.
    local rok, rerr = M.rename(tmp, p)
    if not rok then
        local wt = wide_path(tmp); if wt then C.DeleteFileW(wt) end
        return nil, rerr
    end
    return true
end

function M.append(p, bytes)
    if type(bytes) ~= "string" then
        return nil, "fs.append: bytes must be a string"
    end
    local h, err = open_write(p, true)
    if not h then return nil, err end
    -- Seek to end.
    local zero = ffi.new("long long[1]", 0)
    local new_ptr = ffi.new("long long[1]")
    -- SetFilePointerEx; declared inline because not yet cdef'd.
    if not M._SetFilePointerExLoaded then
        ffi.cdef[[ BOOL SetFilePointerEx(HANDLE, long long, long long *, DWORD); ]]
        M._SetFilePointerExLoaded = true
    end
    if C.SetFilePointerEx(h, 0, new_ptr, 2) == 0 then  -- FILE_END = 2
        local e = last_error_str("SetFilePointerEx")
        C.CloseHandle(h)
        return nil, e
    end
    local ok, werr = write_raw(h, bytes)
    C.CloseHandle(h)
    if not ok then return nil, werr end
    return true
end

-- ===== modern aliases / extended API ====================================
--
-- These names align with the public package contract that other code in
-- the codebase consumes (read_file/write_file/make_dir/...). They're
-- intentionally additive: the older read/write/mkdir names keep working.

-- read_file(p, opts?) -- opts.binary=false, opts.max_size=number
function M.read_file(p, opts)
    opts = opts or {}
    local data, err = M.read(p)
    if not data then return nil, err end
    if opts.max_size and #data > opts.max_size then
        return nil, string.format("fs.read_file: file exceeds max_size (%d > %d)",
                                  #data, opts.max_size)
    end
    if opts.binary == false then
        -- Best-effort UTF-8 BOM strip; matches read_text behavior.
        if #data >= 3 and data:byte(1) == 0xEF and data:byte(2) == 0xBB and data:byte(3) == 0xBF then
            data = data:sub(4)
        end
    end
    return data
end

-- write_file(p, content, opts?) -- opts.atomic=true, opts.mode=ignored on Win.
function M.write_file(p, content, opts)
    opts = opts or {}
    if type(content) ~= "string" then
        return nil, "fs.write_file: content must be a string"
    end
    if opts.atomic == false then
        -- Direct write -- no temp + rename.
        local h, err = open_write(p, false)
        if not h then return nil, err end
        local ok, werr = write_raw(h, content)
        C.CloseHandle(h)
        if not ok then return nil, werr end
        if opts.mode then M.chmod(p, opts.mode) end
        return true
    end
    local ok, err = M.write(p, content)
    if not ok then return nil, err end
    if opts.mode then M.chmod(p, opts.mode) end
    return true
end

-- append_file(p, content) -- thin alias.
function M.append_file(p, content) return M.append(p, content) end

-- make_dir(p, opts?) -- opts.parents=false (-> mkdir -p), opts.mode=ignored.
function M.make_dir(p, opts)
    opts = opts or {}
    return M.mkdir(p, opts.parents == true)
end

-- remove_dir(p, opts?) -- opts.recursive=false.
function M.remove_dir(p, opts)
    opts = opts or {}
    return M.rmdir(p, opts.recursive == true)
end

-- copy with extended options. Original M.copy(src, dst, opts) already
-- supports opts.overwrite; this preserves attrs additionally.
local _legacy_copy = M.copy
function M.copy(src, dst, opts)
    opts = opts or {}
    local ok, err = _legacy_copy(src, dst, opts)
    if not ok then return nil, err end
    if opts.preserve_attrs ~= false then
        local st = M.stat(src)
        if st and st.attributes then
            local wp = wide_path(dst)
            if wp then C.SetFileAttributesW(wp, st.attributes) end
        end
    end
    return true
end

-- realpath(p) -- resolve symlinks + return the canonical absolute path.
ffi.cdef[[
DWORD GetFinalPathNameByHandleW(HANDLE, unsigned short *, DWORD, DWORD);
]]
function M.realpath(p)
    local wp, werr = wide_path(p)
    if not wp then return nil, werr end
    local h = C.CreateFileW(wp, 0,    -- 0 access = metadata only
        bit.bor(FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_SHARE_DELETE),
        nil, OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS, nil)
    if h == INVALID_HANDLE_VALUE then
        return nil, last_error_str("CreateFileW")
    end
    local buf = ffi.new("unsigned short[?]", 32768)
    local n = C.GetFinalPathNameByHandleW(h, buf, 32768, 0)
    C.CloseHandle(h)
    if n == 0 then return nil, last_error_str("GetFinalPathNameByHandleW") end
    local need = C.WideCharToMultiByte(65001, 0, buf, n, nil, 0, nil, nil)
    if need <= 0 then return nil, "WideCharToMultiByte sizing failed" end
    local out = ffi.new("char[?]", need + 1)
    C.WideCharToMultiByte(65001, 0, buf, n, out, need, nil, nil)
    local res = ffi.string(out, need)
    -- Strip the long-path "\\?\" prefix if it was added by the kernel.
    if path.is_long_prefixed(res) then res = path.strip_long_prefix(res) end
    return res
end

-- lstat(p) -- like stat, but does NOT follow symlinks. We already use
-- GetFileAttributesExW which reports the reparse point as-is, so the
-- result is already non-following. Surface as a clear alias.
function M.lstat(p) return M.stat(p) end

-- chown -- best-effort on Windows. SetSecurityInfo / SetNamedSecurityInfo
-- live in advapi32 and require a SID, which is far heavier than this API
-- bargains for. We accept the call and silently succeed.
function M.chown(_p, _uid, _gid) return true end

-- File-time setters. atime/mtime/ctime expect Unix epoch seconds (number).
ffi.cdef[[
BOOL SetFileTime(HANDLE, FILETIME *, FILETIME *, FILETIME *);
]]
local function unix_to_filetime(t, out)
    -- FILETIME = (t * 1e7) + 116444736000000000 in 100ns units. The
    -- epoch constant is too big for a double; we route through cdata
    -- u64 math to keep precision.
    local ticks     = ffi.cast("uint64_t", t * 1e7)
    local epoch_off = ffi.cast("uint64_t", 116444736) * ffi.cast("uint64_t", 1000000000)
    local total     = ticks + epoch_off
    local lo32      = ffi.cast("uint64_t", 0x100000000)
    out.dwLowDateTime  = tonumber(total % lo32)
    out.dwHighDateTime = tonumber(total / lo32)
end

local function set_times(p, atime, mtime, ctime)
    local wp, werr = wide_path(p)
    if not wp then return nil, werr end
    local FILE_WRITE_ATTRIBUTES = 0x100
    local h = C.CreateFileW(wp, FILE_WRITE_ATTRIBUTES,
        bit.bor(FILE_SHARE_READ, FILE_SHARE_WRITE, FILE_SHARE_DELETE),
        nil, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nil)
    if h == INVALID_HANDLE_VALUE then
        return nil, last_error_str("CreateFileW")
    end
    local ft_c, ft_a, ft_m
    if ctime then ft_c = ffi.new("FILETIME"); unix_to_filetime(ctime, ft_c) end
    if atime then ft_a = ffi.new("FILETIME"); unix_to_filetime(atime, ft_a) end
    if mtime then ft_m = ffi.new("FILETIME"); unix_to_filetime(mtime, ft_m) end
    if C.SetFileTime(h, ft_c, ft_a, ft_m) == 0 then
        local e = last_error_str("SetFileTime")
        C.CloseHandle(h)
        return nil, e
    end
    C.CloseHandle(h)
    return true
end

function M.atime(p, t) return set_times(p, t, nil, nil) end
function M.mtime(p, t) return set_times(p, nil, t, nil) end
function M.ctime(p, t) return set_times(p, nil, nil, t) end
function M.set_times(p, opts)
    opts = opts or {}
    return set_times(p, opts.atime, opts.mtime, opts.ctime)
end

-- temp_file(opts?) / temp_dir(opts?) -- thin wrappers over the tempdir
-- package so fs presents a complete surface. We require it lazily to
-- avoid a hard cycle on startup (fs <-> tempdir would otherwise loop).
function M.temp_file(opts)
    local td = require "tempdir"
    return td.tempfile(opts)
end
function M.temp_dir(opts)
    local td = require "tempdir"
    return td.tempdir(opts)
end

-- lock_file(p, opts?) -- shared/exclusive byte-range lock. Returns a lock
-- object with :unlock(). opts = { exclusive=true, offset=0, length=nil,
-- create=false }.
ffi.cdef[[
typedef struct _fs_OVERLAPPED {
    ULONGLONG  Internal;
    ULONGLONG  InternalHigh;
    ULONGLONG  Offset;
    HANDLE     hEvent;
} fs_OVERLAPPED;
BOOL LockFileEx(HANDLE, DWORD, DWORD, DWORD, DWORD, fs_OVERLAPPED *);
BOOL UnlockFileEx(HANDLE, DWORD, DWORD, DWORD, fs_OVERLAPPED *);
]]

local LOCKFILE_EXCLUSIVE_LOCK   = 0x00000002
local LOCKFILE_FAIL_IMMEDIATELY = 0x00000001

local lock_mt = { __index = {} }
function lock_mt.__index:unlock()
    if self._unlocked then return true end
    self._unlocked = true
    local ov = ffi.new("fs_OVERLAPPED")
    ov.Offset = ffi.cast("uint64_t", self._offset)
    C.UnlockFileEx(self._handle, 0,
        bit.band(self._length, 0xFFFFFFFF),
        bit.rshift(self._length, 32),
        ov)
    if self._owns_handle then
        C.CloseHandle(self._handle)
        self._handle = nil
    end
    return true
end
lock_mt.__gc = function(self) pcall(self.unlock, self) end

function M.lock_file(p, opts)
    opts = opts or {}
    local wp, werr = wide_path(p)
    if not wp then return nil, werr end
    local access = GENERIC_READ
    if opts.exclusive ~= false then access = bit.bor(access, GENERIC_WRITE) end
    local disp = opts.create and OPEN_ALWAYS or OPEN_EXISTING
    local h = C.CreateFileW(wp, access,
        bit.bor(FILE_SHARE_READ, FILE_SHARE_WRITE), nil, disp, 0, nil)
    if h == INVALID_HANDLE_VALUE then
        return nil, last_error_str("CreateFileW")
    end
    local offset = opts.offset or 0
    -- Default lock length: entire 64-bit range.
    local length = opts.length or 0x7FFFFFFFFFFFFFFF
    local flags = 0
    if opts.exclusive ~= false then flags = bit.bor(flags, LOCKFILE_EXCLUSIVE_LOCK) end
    if opts.wait == false then flags = bit.bor(flags, LOCKFILE_FAIL_IMMEDIATELY) end
    local ov = ffi.new("fs_OVERLAPPED")
    ov.Offset = ffi.cast("uint64_t", offset)
    if C.LockFileEx(h, flags, 0,
            bit.band(length, 0xFFFFFFFF),
            bit.rshift(length, 32), ov) == 0 then
        local e = last_error_str("LockFileEx")
        C.CloseHandle(h)
        return nil, e
    end
    return setmetatable({
        _handle = h,
        _owns_handle = true,
        _offset = offset,
        _length = length,
        _unlocked = false,
    }, lock_mt)
end

-- iter(p) -- iterator yielding entry names in a directory (no full paths).
function M.iter(p)
    local names, err = M.list(p)
    if not names then return function() return nil, err end end
    local i = 0
    return function()
        i = i + 1
        return names[i]
    end
end

-- scandir(p) -- like list() but yields entry tables with .name + .is_dir.
function M.scandir(p)
    local norm = path.normalize(p)
    local pattern = norm .. "\\*"
    local wp, werr = wide_path(pattern)
    if not wp then return nil, werr end
    local fd = ffi.new("fs_WIN32_FIND_DATAW")
    local h  = C.FindFirstFileW(wp, fd)
    if h == INVALID_HANDLE_VALUE then
        local code = C.GetLastError()
        if code == 2 or code == 3 then return {} end
        return nil, string.format("FindFirstFileW failed (Win32 error %d)", code)
    end
    local out, n = {}, 0
    repeat
        local wchars = 0
        for i = 0, 259 do
            if fd.cFileName[i] == 0 then wchars = i; break end
        end
        if wchars > 0 then
            local need = C.WideCharToMultiByte(65001, 0, fd.cFileName, wchars, nil, 0, nil, nil)
            local name = ""
            if need > 0 then
                local nb = ffi.new("char[?]", need + 1)
                C.WideCharToMultiByte(65001, 0, fd.cFileName, wchars, nb, need, nil, nil)
                name = ffi.string(nb, need)
            end
            if name ~= "." and name ~= ".." then
                n = n + 1
                local attrs = fd.dwFileAttributes
                out[n] = {
                    name       = name,
                    path       = path.join(norm, name),
                    is_dir     = bit.band(attrs, FILE_ATTRIBUTE_DIRECTORY) ~= 0,
                    is_symlink = bit.band(attrs, FILE_ATTRIBUTE_REPARSE_POINT) ~= 0,
                    size       = (tonumber(fd.nFileSizeHigh) * 4294967296) + tonumber(fd.nFileSizeLow),
                    attributes = attrs,
                }
            end
        end
    until C.FindNextFileW(h, fd) == 0
    C.FindClose(h)
    return out
end

return M
