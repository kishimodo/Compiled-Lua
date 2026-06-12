-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- cab -- Microsoft Cabinet archive reader via setupapi.dll.
--
-- Why setupapi rather than cabinet.dll / FDI:
--   FDI (cabinet.dll) is the full streaming API but it requires the
--   caller to plumb six function-pointer callbacks (alloc / free / open
--   / read / write / close / seek) into a FDIContext. setupapi wraps
--   that into SetupIterateCabinet which takes a single PSP_FILE_CALLBACK
--   that fires for each member -- much easier to drive from Lua.
--
-- The callback receives a "notification" code:
--   SPFILENOTIFY_CABINETINFO       = 0x0010  -- once at archive open
--   SPFILENOTIFY_FILEINCABINET     = 0x0011  -- once per member (LIST or EXTRACT)
--   SPFILENOTIFY_NEEDNEWCABINET    = 0x0012  -- multi-CAB span ask
--   SPFILENOTIFY_FILEEXTRACTED     = 0x0013  -- once per extracted file
-- Return value:
--   FILEOP_DOIT  = 1   -- proceed with extraction
--   FILEOP_SKIP  = 2   -- skip this file
--   FILEOP_ABORT = 0   -- bail out
--
-- Public surface:
--   cab.is_available()                 -> bool
--   cab.list(path)                     -> array of { name, size, attribs, mtime }
--   cab.extract(path, dest_dir)        -> array of extracted file paths
--   cab.read(path, member_name)        -> bytes  (extracts into a temp dir, then reads)

local ffi = ffi

local M = {}

ffi.cdef[[
typedef int                cab_BOOL;
typedef unsigned int       cab_UINT;
typedef unsigned short     cab_WORD;
typedef unsigned long      cab_DWORD;
typedef unsigned long long cab_UINT_PTR;
typedef void              *cab_PVOID;
typedef void              *cab_HMODULE;
typedef const char        *cab_LPCSTR;
typedef char              *cab_LPSTR;

cab_HMODULE LoadLibraryA(cab_LPCSTR);
cab_HMODULE GetModuleHandleA(cab_LPCSTR);
cab_PVOID   GetProcAddress(cab_HMODULE, cab_LPCSTR);
cab_BOOL    FreeLibrary(cab_HMODULE);
cab_DWORD   GetLastError(void);

/* FILE_IN_CABINET_INFO_A -- the payload for SPFILENOTIFY_FILEINCABINET.
   Layout per the Windows SDK header SetupAPI.h: the three DOS stamp
   fields are WORD (16-bit), which puts FullTargetName at offset 22. */
typedef struct _cab_FILE_IN_CABINET_INFO_A {
    cab_LPCSTR NameInCabinet;        /* relative path inside cab */
    cab_DWORD  FileSize;             /* uncompressed size */
    cab_DWORD  Win32Error;           /* set on extraction */
    cab_WORD   DosDate;
    cab_WORD   DosTime;
    cab_WORD   DosAttribs;
    char       FullTargetName[260];  /* MAX_PATH; we write here on EXTRACT */
} cab_FILE_IN_CABINET_INFO_A;

/* CABINET_INFO_A -- delivered with SPFILENOTIFY_CABINETINFO. */
typedef struct _cab_CABINET_INFO_A {
    cab_LPCSTR CabinetPath;
    cab_LPCSTR CabinetFile;
    cab_LPCSTR DiskName;
    cab_UINT   SetId;
    cab_UINT   CabinetNumber;
} cab_CABINET_INFO_A;

/* FILEPATHS_A -- delivered with SPFILENOTIFY_FILEEXTRACTED. */
typedef struct _cab_FILEPATHS_A {
    cab_LPCSTR Target;
    cab_LPCSTR Source;
    cab_UINT   Win32Error;
    cab_DWORD  Flags;
} cab_FILEPATHS_A;

/* SDK signature: Param1/Param2 are UINT_PTR -- Param1 carries a POINTER
   (e.g. FILE_IN_CABINET_INFO_A *) for most notifications. Declaring them
   32-bit truncates the pointer on x64. */
typedef cab_UINT (*cab_PSP_FILE_CALLBACK_A)(
    cab_PVOID Context, cab_UINT Notification,
    cab_UINT_PTR Param1, cab_UINT_PTR Param2);

typedef cab_BOOL (*cab_PSetupIterateCabinetA)(
    cab_LPCSTR CabinetFile, cab_DWORD Reserved,
    cab_PSP_FILE_CALLBACK_A MsgHandler, cab_PVOID Context);
]]

local C = ffi.C

local SPFILENOTIFY_CABINETINFO     = 0x0010
local SPFILENOTIFY_FILEINCABINET   = 0x0011
local SPFILENOTIFY_NEEDNEWCABINET  = 0x0012
local SPFILENOTIFY_FILEEXTRACTED   = 0x0013

local FILEOP_ABORT = 0
local FILEOP_DOIT  = 1
local FILEOP_SKIP  = 2

-- DOS timestamp decode -- same scheme as zip.
local function unpack_dos_time(dos_time, dos_date)
    local year  = bit.rshift(dos_date, 9) + 1980
    local month = bit.band(bit.rshift(dos_date, 5), 0x0F)
    local day   = bit.band(dos_date, 0x1F)
    local hour  = bit.rshift(dos_time, 11)
    local min   = bit.band(bit.rshift(dos_time, 5), 0x3F)
    local sec   = bit.band(dos_time, 0x1F) * 2
    -- Defend against zero/garbage; os.time bails on invalid date tables.
    if month < 1 or month > 12 or day < 1 or day > 31 then return 0 end
    return os.time({ year = year, month = month, day = day,
                     hour = hour, min = min, sec = sec })
end

-- ===== setupapi lookup ===================================================

local _state -- nil = unprobed, false = unavailable, table = loaded

local function probe()
    if _state ~= nil then return _state end
    local h = C.GetModuleHandleA("setupapi.dll")
    if h == nil then h = C.LoadLibraryA("setupapi.dll") end
    if h == nil then
        _state = false
        return false
    end
    local fn = C.GetProcAddress(h, "SetupIterateCabinetA")
    if fn == nil then
        _state = false
        return false
    end
    _state = {
        hmod = h,
        iterate = ffi.cast("cab_PSetupIterateCabinetA", fn),
    }
    return _state
end

function M.is_available()
    return probe() ~= false
end

local function require_state()
    local st = probe()
    if st == false then
        error("cab: setupapi.dll / SetupIterateCabinetA unavailable")
    end
    return st
end

-- ===== Win32 file-path helpers ===========================================
-- We need a temp dir for cab.read() and for ensure-dir on extract().

ffi.cdef[[
cab_DWORD GetTempPathA(cab_DWORD, cab_LPSTR);
cab_UINT  GetTempFileNameA(cab_LPCSTR, cab_LPCSTR, cab_UINT, cab_LPSTR);
cab_BOOL  CreateDirectoryA(cab_LPCSTR, cab_PVOID);
cab_BOOL  DeleteFileA(cab_LPCSTR);
cab_BOOL  RemoveDirectoryA(cab_LPCSTR);
]]

local function get_temp_dir()
    local buf = ffi.new("char[?]", 260)
    local n = C.GetTempPathA(260, buf)
    if n == 0 then return os.getenv("TEMP") or "." end
    return ffi.string(buf, n)
end

local function make_temp_subdir()
    local base = get_temp_dir()
    -- Unique dir name. GetTempFileName creates a file we don't want, so
    -- combine PID + tick count + os.time for a path string we use to
    -- create a fresh directory.
    local tag = string.format("cab_%d_%d", os.time(), math.random(1, 1e9))
    local path = base .. tag
    if C.CreateDirectoryA(path, nil) == 0 then
        -- Already existed (vanishingly unlikely) -- caller proceeds anyway.
    end
    return path
end

local function ensure_dir(path)
    if path == nil or path == "" or path == "." then return end
    -- Walk parents and create each. Use Win32 directly to avoid relying
    -- on os.execute (which spawns a shell -- noisy).
    local norm = path:gsub("\\", "/")
    local parts = {}
    for p in norm:gmatch("[^/]+") do parts[#parts + 1] = p end
    local accum = ""
    for i, p in ipairs(parts) do
        if i == 1 and p:match("^[A-Za-z]:$") then
            accum = p
        else
            accum = (accum == "" and p) or (accum .. "/" .. p)
            -- Win32 needs backslashes for CreateDirectoryA reliably.
            C.CreateDirectoryA(accum:gsub("/", "\\"), nil)
        end
    end
end

-- ===== iterate driver =====================================================
-- iter_kind: "list" or "extract" or "read_one"
-- For "extract", dest_dir is required.
-- For "read_one", only_name is the member to grab, extracted to a temp dir.

local function iterate(path, iter_kind, dest_dir, only_name)
    local st = require_state()
    local results = {}
    local target_for_read
    -- The callback is invoked from native code under SetupIterateCabinet.
    -- We MUST keep the cb alive (via the local var) until iterate returns;
    -- otherwise the GC could reclaim the trampoline.
    local cb = ffi.cast("cab_PSP_FILE_CALLBACK_A", function(_ctx, notif, p1, _p2)
        if notif == SPFILENOTIFY_FILEINCABINET then
            local info = ffi.cast("cab_FILE_IN_CABINET_INFO_A *", p1)
            local name = ffi.string(info.NameInCabinet)
            if iter_kind == "list" then
                results[#results + 1] = {
                    name    = name,
                    size    = tonumber(info.FileSize),
                    attribs = tonumber(info.DosAttribs),
                    mtime   = unpack_dos_time(tonumber(info.DosTime),
                                              tonumber(info.DosDate)),
                }
                return FILEOP_SKIP
            elseif iter_kind == "extract" then
                -- Containment check (Zip-Slip / CWE-22): NameInCabinet is
                -- attacker-controlled. Refuse absolute paths, drive prefixes,
                -- or any ".." segment so a crafted .cab cannot write outside
                -- dest_dir. (read_one already neutralizes separators via "_";
                -- the extract path historically preserved "..", so skip it.)
                local norm = name:gsub("\\", "/")
                local unsafe = (norm:sub(1, 1) == "/") or (norm:match("^%a:") ~= nil)
                if not unsafe then
                    for seg in (norm .. "/"):gmatch("([^/]*)/") do
                        if seg == ".." then unsafe = true; break end
                    end
                end
                if unsafe then return FILEOP_SKIP end
                local target = (dest_dir:gsub("[/\\]+$", "")) .. "\\" .. name:gsub("/", "\\")
                ensure_dir(target:match("^(.+)[/\\][^/\\]+$") or "")
                -- Write target into FullTargetName (size-limited to 260).
                if #target >= 260 then return FILEOP_SKIP end
                ffi.copy(info.FullTargetName, target, #target + 1)
                results[#results + 1] = target
                return FILEOP_DOIT
            elseif iter_kind == "read_one" then
                if name == only_name then
                    local target = (dest_dir:gsub("[/\\]+$", "")) .. "\\" .. name:gsub("[/\\]", "_")
                    ensure_dir(dest_dir)
                    if #target >= 260 then return FILEOP_ABORT end
                    ffi.copy(info.FullTargetName, target, #target + 1)
                    target_for_read = target
                    return FILEOP_DOIT
                end
                return FILEOP_SKIP
            end
            return FILEOP_SKIP
        end
        -- Every non-FILEINCABINET notification (CABINETINFO, FILEEXTRACTED,
        -- NEEDNEWCABINET) expects NO_ERROR (0) to continue; the FILEOP_*
        -- codes only apply to FILEINCABINET. Returning FILEOP_DOIT (1) here
        -- is interpreted as Win32 error 1 and aborts the whole iteration.
        return 0
    end)
    local ok = st.iterate(path, 0, cb, nil)
    local lasterr = (ok == 0) and C.GetLastError() or 0
    cb:free()
    if ok == 0 then
        error(string.format("cab: SetupIterateCabinetA failed for %s (Win32 error %d)",
                            tostring(path), tonumber(lasterr)))
    end
    if iter_kind == "read_one" then
        if target_for_read == nil then
            error("cab.read: member not found: " .. tostring(only_name))
        end
        local f = io.open(target_for_read, "rb")
        if not f then error("cab.read: could not open extracted file") end
        local body = f:read("*a")
        f:close()
        -- Clean up the temp file (best effort).
        C.DeleteFileA(target_for_read)
        return body
    end
    return results
end

-- ===== public API =========================================================

function M.list(path)
    return iterate(path, "list", nil, nil)
end

function M.extract(path, dest_dir)
    if type(dest_dir) ~= "string" or dest_dir == "" then
        error("cab.extract: dest_dir required")
    end
    ensure_dir(dest_dir)
    return iterate(path, "extract", dest_dir, nil)
end

function M.read(path, member_name)
    local tmp = make_temp_subdir()
    local ok, body = pcall(iterate, path, "read_one", tmp, member_name)
    -- Best-effort temp cleanup; the dir may still contain extracted file
    -- if the read errored before we deleted it.
    C.RemoveDirectoryA(tmp)
    if not ok then error(body) end
    return body
end

-- ===== extract_to_memory =================================================
-- Extracts every member into a temp dir, slurps the bytes, then deletes
-- the temp files. Returns { name = bytes, ... } mapping cab-internal path
-- (with forward slashes) to its uncompressed payload.

function M.extract_to_memory(path)
    local tmp = make_temp_subdir()
    local extracted = iterate(path, "extract", tmp, nil)
    local out = {}
    for _, target in ipairs(extracted) do
        local f = io.open(target, "rb")
        if f then
            -- Recover the in-cab name by stripping the tmp prefix.
            local rel = target:sub(#tmp + 2):gsub("\\", "/")
            out[rel] = f:read("*a")
            f:close()
        end
        C.DeleteFileA(target)
    end
    -- Best-effort dir cleanup (only succeeds when empty).
    C.RemoveDirectoryA(tmp)
    return out
end

-- ===== FCI creator (cabinet.dll) =========================================
-- Drives FCI via cabinet.dll to produce a single-cabinet archive from a
-- list of in-memory entries or disk paths. The FCI API needs eight C
-- callbacks (alloc / free / open / read / write / close / seek / delete /
-- temp-file / get-next-cabinet / progress / get-open-info / status); we
-- wire minimum-viable trampolines that satisfy each contract.

ffi.cdef[[
typedef int            cab_INT;
typedef long           cab_LONG;
typedef unsigned long  cab_ULONG;
typedef long           cab_INT_PTR;
typedef unsigned short cab_USHORT;
typedef unsigned long  cab_FCI_DWORD;
typedef int            cab_off_t;

typedef struct _cab_ERF {
    cab_INT erfOper;
    cab_INT erfType;
    cab_INT fError;
} cab_ERF;

typedef struct _cab_CCAB {
    cab_ULONG cb;             /* max size of cabinet file */
    cab_ULONG cbFolderThresh; /* folder size threshold */
    cab_ULONG cbReserveCFHeader;
    cab_ULONG cbReserveCFFolder;
    cab_ULONG cbReserveCFData;
    cab_INT   iCab;
    cab_INT   iDisk;
    cab_INT   fFailOnIncompressible;
    cab_USHORT setID;
    char      szDisk[256];
    char      szCab[256];
    char      szCabPath[256];
} cab_CCAB;

typedef void *(*cab_PFNFCIALLOC)(cab_ULONG);
typedef void  (*cab_PFNFCIFREE)(void *);
typedef cab_INT_PTR (*cab_PFNFCIOPEN)(const char *, cab_INT, cab_INT, cab_INT *, void *);
typedef cab_ULONG   (*cab_PFNFCIREAD)(cab_INT_PTR, void *, cab_ULONG, cab_INT *, void *);
typedef cab_ULONG   (*cab_PFNFCIWRITE)(cab_INT_PTR, void *, cab_ULONG, cab_INT *, void *);
typedef cab_INT     (*cab_PFNFCICLOSE)(cab_INT_PTR, cab_INT *, void *);
typedef cab_LONG    (*cab_PFNFCISEEK)(cab_INT_PTR, cab_LONG, cab_INT, cab_INT *, void *);
typedef cab_INT     (*cab_PFNFCIDELETE)(const char *, cab_INT *, void *);
typedef cab_INT     (*cab_PFNFCIGETTEMPFILE)(char *, cab_INT, void *);
typedef cab_INT     (*cab_PFNFCIGETNEXTCABINET)(cab_CCAB *, cab_ULONG, void *);
typedef cab_LONG    (*cab_PFNFCISTATUS)(cab_ULONG, cab_ULONG, cab_ULONG, void *);
typedef cab_INT_PTR (*cab_PFNFCIGETOPENINFO)(const char *, unsigned short *, unsigned short *, unsigned short *, cab_INT *, void *);

typedef void *cab_HFCI;

typedef cab_INT (*cab_PFNFCIFILEPLACED)(cab_CCAB *, char *, cab_ULONG, void *);

typedef cab_HFCI (*cab_PFCICreate)(cab_ERF *,
    cab_PFNFCIFILEPLACED,
    cab_PFNFCIALLOC, cab_PFNFCIFREE,
    cab_PFNFCIOPEN, cab_PFNFCIREAD, cab_PFNFCIWRITE,
    cab_PFNFCICLOSE, cab_PFNFCISEEK, cab_PFNFCIDELETE,
    cab_PFNFCIGETTEMPFILE, cab_CCAB *, void *);
typedef cab_INT (*cab_PFCIAddFile)(cab_HFCI, char *, char *, cab_INT,
    cab_PFNFCIGETNEXTCABINET, cab_PFNFCISTATUS,
    cab_PFNFCIGETOPENINFO, cab_USHORT);
typedef cab_INT (*cab_PFCIFlushCabinet)(cab_HFCI, cab_INT,
    cab_PFNFCIGETNEXTCABINET, cab_PFNFCISTATUS);
typedef cab_INT (*cab_PFCIDestroy)(cab_HFCI);

/* Generic file ops used by the I/O trampolines. The msvcrt versions are
   exposed by the windows package's ffi.load("msvcrt") preload. */
int  _open  (const char *, int, int);
int  _close (int);
int  _read  (int, void *, unsigned int);
int  _write (int, const void *, unsigned int);
long _lseek (int, long, int);
int  _unlink(const char *);
void *malloc(unsigned long long);
void  free(void *);
]]

-- Compression type code -- tCompTYPE_MSZIP = 1 (the standard, ships in
-- every Windows). LZX modes exist but require extra plumbing.
local TCOMP_MSZIP = 1

-- msvcrt hosts _open/_read/_close used by the FCI callbacks. ffi.load
-- is idempotent so calling this even if a previous package loaded it
-- is safe.
pcall(ffi.load, "msvcrt")

local _fci_state -- nil = unprobed, false = absent, table = loaded

local function probe_fci()
    if _fci_state ~= nil then return _fci_state end
    local h = C.GetModuleHandleA("cabinet.dll")
    if h == nil then h = C.LoadLibraryA("cabinet.dll") end
    if h == nil then _fci_state = false; return false end
    local function look(name)
        local p = C.GetProcAddress(h, name)
        if p == nil then return nil end
        return p
    end
    local p_create  = look("FCICreate")
    local p_add     = look("FCIAddFile")
    local p_flush   = look("FCIFlushCabinet")
    local p_destroy = look("FCIDestroy")
    if not (p_create and p_add and p_flush and p_destroy) then
        _fci_state = false
        return false
    end
    _fci_state = {
        hmod     = h,
        f_create = ffi.cast("cab_PFCICreate",       p_create),
        f_add    = ffi.cast("cab_PFCIAddFile",      p_add),
        f_flush  = ffi.cast("cab_PFCIFlushCabinet", p_flush),
        f_destroy= ffi.cast("cab_PFCIDestroy",      p_destroy),
    }
    return _fci_state
end

function M.fci_available()
    return probe_fci() ~= false
end

function M.create(cab_path, files, opts)
    if type(cab_path) ~= "string" then
        error("cab.create: cab_path required")
    end
    if type(files) ~= "table" then
        error("cab.create: files must be an array of { name=, bytes= } or paths")
    end
    opts = opts or {}
    local st = probe_fci()
    if st == false then
        error("cab.create: cabinet.dll FCI exports unavailable")
    end
    -- Stage every entry on disk -- FCI insists on reading from real files
    -- via its open/read/close callbacks. Doing the staging here keeps the
    -- Lua callback footprint tiny and avoids reentrancy traps.
    local tmp_dir = make_temp_subdir()
    local staged = {}
    for i, entry in ipairs(files) do
        local src, name
        if type(entry) == "string" then
            src = entry
            name = entry:match("([^/\\]+)$") or entry
        elseif type(entry) == "table" then
            name = entry.name or ("file" .. i)
            if entry.bytes then
                src = tmp_dir .. "\\" .. name:gsub("[/\\]", "_")
                local f = io.open(src, "wb")
                if not f then error("cab.create: cannot stage " .. src) end
                f:write(entry.bytes); f:close()
            elseif entry.path then
                src = entry.path
            else
                error("cab.create: entry needs `bytes` or `path`")
            end
        else
            error("cab.create: entry must be string path or table")
        end
        staged[#staged + 1] = { src = src, name = name }
    end
    -- Set up CCAB.
    local ccab = ffi.new("cab_CCAB")
    ccab.cb = opts.max_size or 0x7FFFFFFF
    ccab.cbFolderThresh = opts.folder_thresh or 0x7FFFFFFF
    ccab.iCab = 1
    ccab.iDisk = 0
    ccab.setID = opts.set_id or 0
    -- Split cab_path into directory + filename for FCI's CCAB.
    local norm = cab_path:gsub("/", "\\")
    local dir  = norm:match("^(.+)\\[^\\]+$") or "."
    local name = norm:match("([^\\]+)$") or norm
    if not dir:match("\\$") then dir = dir .. "\\" end
    ffi.copy(ccab.szCabPath, dir, math.min(#dir + 1, 256))
    ffi.copy(ccab.szCab,     name, math.min(#name + 1, 256))
    -- Callbacks.
    local erf = ffi.new("cab_ERF")
    local cbs = {}
    cbs.fnAlloc = ffi.cast("cab_PFNFCIALLOC", function(n)
        return ffi.C.malloc(n)
    end)
    cbs.fnFree = ffi.cast("cab_PFNFCIFREE", function(p)
        ffi.C.free(p)
    end)
    cbs.fnOpen = ffi.cast("cab_PFNFCIOPEN", function(path, oflag, pmode, err, _)
        local fd = ffi.C._open(ffi.string(path), oflag, pmode)
        if fd < 0 then err[0] = 1; return -1 end
        return fd
    end)
    cbs.fnRead = ffi.cast("cab_PFNFCIREAD", function(fd, buf, cb, err, _)
        local got = ffi.C._read(fd, buf, cb)
        if got < 0 then err[0] = 1; return 0 end
        return got
    end)
    cbs.fnWrite = ffi.cast("cab_PFNFCIWRITE", function(fd, buf, cb, err, _)
        local put = ffi.C._write(fd, buf, cb)
        if put < 0 then err[0] = 1; return 0 end
        return put
    end)
    cbs.fnClose = ffi.cast("cab_PFNFCICLOSE", function(fd, err, _)
        if ffi.C._close(fd) < 0 then err[0] = 1; return -1 end
        return 0
    end)
    cbs.fnSeek = ffi.cast("cab_PFNFCISEEK", function(fd, dist, seektype, err, _)
        local pos = ffi.C._lseek(fd, dist, seektype)
        if pos < 0 then err[0] = 1; return -1 end
        return pos
    end)
    cbs.fnDelete = ffi.cast("cab_PFNFCIDELETE", function(path, err, _)
        if ffi.C._unlink(ffi.string(path)) < 0 then err[0] = 1; return -1 end
        return 0
    end)
    cbs.fnTempFile = ffi.cast("cab_PFNFCIGETTEMPFILE", function(buf, cb, _)
        local tmp = string.format("%scabtmp_%d_%d.tmp", tmp_dir .. "\\",
                                  os.time(), math.random(1, 1e9))
        if #tmp >= cb then return 0 end
        ffi.copy(buf, tmp, #tmp + 1)
        return 1
    end)
    cbs.fnFilePlaced = ffi.cast("cab_PFNFCIFILEPLACED",
        function(_a, _b, _c, _d) return 0 end)
    cbs.fnGetNext = ffi.cast("cab_PFNFCIGETNEXTCABINET", function(_, _, _) return 1 end)
    cbs.fnStatus  = ffi.cast("cab_PFNFCISTATUS", function(_, _, _, _) return 0 end)
    cbs.fnGetOpenInfo = ffi.cast("cab_PFNFCIGETOPENINFO",
        function(path, pdate, ptime, pattr, err, _)
            local fd = ffi.C._open(ffi.string(path), 0, 0)  -- O_RDONLY
            if fd < 0 then err[0] = 1; return -1 end
            pdate[0] = 0
            ptime[0] = 0
            pattr[0] = 0x20  -- FILE_ATTRIBUTE_ARCHIVE
            return fd
        end)
    -- Drive FCICreate.
    local hfci = st.f_create(erf, cbs.fnFilePlaced,
        cbs.fnAlloc, cbs.fnFree, cbs.fnOpen, cbs.fnRead, cbs.fnWrite,
        cbs.fnClose, cbs.fnSeek, cbs.fnDelete, cbs.fnTempFile, ccab, nil)
    if hfci == nil then
        error(string.format("cab.create: FCICreate failed (erfOper=%d erfType=%d)",
                            tonumber(erf.erfOper), tonumber(erf.erfType)))
    end
    -- Add each staged file.
    for _, ent in ipairs(staged) do
        local src_buf = ffi.new("char[?]", #ent.src + 1); ffi.copy(src_buf, ent.src)
        local nm_buf  = ffi.new("char[?]", #ent.name + 1); ffi.copy(nm_buf,  ent.name)
        local ok = st.f_add(hfci, src_buf, nm_buf, 0,
                            cbs.fnGetNext, cbs.fnStatus, cbs.fnGetOpenInfo,
                            TCOMP_MSZIP)
        if ok == 0 then
            st.f_destroy(hfci)
            error("cab.create: FCIAddFile failed for " .. ent.name)
        end
    end
    -- Flush + destroy.
    st.f_flush(hfci, 0, cbs.fnGetNext, cbs.fnStatus)
    st.f_destroy(hfci)
    -- Release the cdata callbacks so they can be GC'd.
    for _, v in pairs(cbs) do v:free() end
    -- Tear down staged temp files.
    for _, ent in ipairs(staged) do
        if ent.src:find(tmp_dir, 1, true) then
            C.DeleteFileA(ent.src)
        end
    end
    C.RemoveDirectoryA(tmp_dir)
    return cab_path
end

return M
