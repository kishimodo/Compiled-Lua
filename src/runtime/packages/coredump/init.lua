-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- coredump -- Windows minidump (.dmp) reader + writer.
--
-- Public surface:
--   coredump.write(path, opts?)        -> ok, err
--      opts = { pid = current_pid,
--               type = "normal"|"full"|"with_handles"|"with_threads"|<flags>,
--               exception_pointers = nil }
--   coredump.parse(path_or_bytes)      -> dump object
--
-- dump object methods:
--   :header()           -> { signature, version, n_streams, timestamp, flags }
--   :streams()          -> { {type, type_name, rva, size}, ... }
--   :system_info()      -> CPU + OS info
--   :modules()          -> { {base, size, name, timestamp, checksum}, ... }
--   :threads()          -> { {tid, suspend_count, stack=..., context=..., ...}, ... }
--   :memory_regions()   -> { {base, size, rva}, ... }  (from MemoryListStream)
--   :memory_info()      -> MemoryInfoListStream array (allocation_protect, ...)
--   :handles()          -> HandleData stream array
--   :exception()        -> exception record + thread id, or nil
--   :misc()             -> miscellaneous info
--   :read(addr, n)      -> bytes covering [addr, addr+n) from MemoryList ranges
--
-- The reader is pure Lua (no DLL needed). The writer wraps
-- dbghelp!MiniDumpWriteDump.

local M = {}

-- ===== minidump stream type constants ==================================

local STREAM_TYPES = {
    [0]  = "Unused",
    [1]  = "Reserved0",
    [2]  = "Reserved1",
    [3]  = "ThreadList",
    [4]  = "ModuleList",
    [5]  = "MemoryList",
    [6]  = "Exception",
    [7]  = "SystemInfo",
    [8]  = "ThreadExList",
    [9]  = "Memory64List",
    [10] = "CommentA",
    [11] = "CommentW",
    [12] = "HandleData",
    [13] = "FunctionTable",
    [14] = "UnloadedModuleList",
    [15] = "MiscInfo",
    [16] = "MemoryInfoList",
    [17] = "ThreadInfoList",
    [18] = "HandleOperationList",
    [19] = "TokenStream",
    [20] = "JavaScriptDataStream",
    [21] = "SystemMemoryInfoStream",
    [22] = "ProcessVmCountersStream",
    [23] = "IptTraceStream",
    [24] = "ThreadNamesStream",
}

local STREAM_NAME_TO_TYPE = {}
for k, v in pairs(STREAM_TYPES) do STREAM_NAME_TO_TYPE[v] = k end

local PROCESSOR_ARCH = {
    [0]  = "X86",  [5] = "ARM",   [6] = "IA64",
    [9]  = "AMD64",[12]= "ARM64", [0xFFFF] = "UNKNOWN",
}

local PLATFORM_ID = {
    [0] = "Win32s", [1] = "Win9x", [2] = "WinNT", [3] = "Win32_CE",
}

-- ===== binary readers ==================================================

local function u8(buf, off)  return buf:byte(off + 1) or 0 end
local function u16(buf, off)
    local b1, b2 = buf:byte(off + 1), buf:byte(off + 2)
    if not b1 or not b2 then return 0 end
    return b1 + b2 * 0x100
end
local function u32(buf, off)
    local b1, b2, b3, b4 = buf:byte(off + 1), buf:byte(off + 2),
        buf:byte(off + 3), buf:byte(off + 4)
    if not b1 or not b2 or not b3 or not b4 then return 0 end
    return b1 + b2 * 0x100 + b3 * 0x10000 + b4 * 0x1000000
end
local function u64(buf, off)
    return u32(buf, off) + u32(buf, off + 4) * 4294967296
end

-- Minidump strings are UTF-16LE, length-prefixed by a u32 byte count.
local function read_md_string(buf, off)
    if off == 0 then return "" end
    local nbytes = u32(buf, off)
    local nchars = math.floor(nbytes / 2)
    local out = {}
    for i = 0, nchars - 1 do
        local c = u16(buf, off + 4 + i * 2)
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
    end
    return table.concat(out)
end

-- ===== reader =========================================================

local Dump = {}
Dump.__index = Dump

local function load_buf(input)
    if #input >= 4 and input:sub(1, 4) == "MDMP" then
        return input
    end
    -- Treat as path.
    local f, err = io.open(input, "rb")
    if not f then error("coredump.parse: " .. tostring(err)) end
    local s = f:read("*a") or ""
    f:close()
    return s
end

function M.parse(input)
    if type(input) ~= "string" then
        error("coredump.parse: expected string path or bytes")
    end
    local buf = load_buf(input)
    if #buf < 32 or buf:sub(1, 4) ~= "MDMP" then
        error("coredump.parse: not a minidump (bad MDMP signature)")
    end

    -- MINIDUMP_HEADER: Signature(4) Version(4) NumberOfStreams(4)
    --                  StreamDirectoryRva(4) CheckSum(4) Reserved(4)
    --                  TimeDateStamp(4) Flags(8)
    local header = {
        signature    = buf:sub(1, 4),
        version      = u32(buf, 4),
        n_streams    = u32(buf, 8),
        dir_rva      = u32(buf, 12),
        checksum     = u32(buf, 16),
        timestamp    = u32(buf, 24),
        flags_low    = u32(buf, 28),
        flags_high   = u32(buf, 32),
    }

    -- MINIDUMP_DIRECTORY: StreamType(4) Location.DataSize(4) Location.Rva(4)
    local streams = {}
    local dir_off = header.dir_rva
    for i = 0, header.n_streams - 1 do
        local e = dir_off + i * 12
        local typ = u32(buf, e)
        streams[#streams + 1] = {
            type      = typ,
            type_name = STREAM_TYPES[typ] or string.format("?(0x%X)", typ),
            size      = u32(buf, e + 4),
            rva       = u32(buf, e + 8),
        }
    end

    return setmetatable({
        _buf = buf,
        _hdr = header,
        _streams = streams,
    }, Dump)
end

function Dump:header() return self._hdr end
function Dump:streams() return self._streams end

local function find_stream(self, name)
    local want = STREAM_NAME_TO_TYPE[name]
    for _, s in ipairs(self._streams) do
        if s.type == want then return s end
    end
    return nil
end

-- ----- SystemInfo ------------------------------------------------------

function Dump:system_info()
    local s = find_stream(self, "SystemInfo")
    if not s then return nil end
    local buf, off = self._buf, s.rva
    -- MINIDUMP_SYSTEM_INFO:
    --  USHORT  ProcessorArchitecture
    --  USHORT  ProcessorLevel
    --  USHORT  ProcessorRevision
    --  UCHAR   NumberOfProcessors
    --  UCHAR   ProductType
    --  ULONG   MajorVersion
    --  ULONG   MinorVersion
    --  ULONG   BuildNumber
    --  ULONG   PlatformId
    --  ULONG   CSDVersionRva
    --  ... (vendor-specific feature tail; skip)
    local arch = u16(buf, off + 0)
    local out = {
        processor_arch  = arch,
        arch_name       = PROCESSOR_ARCH[arch] or "UNKNOWN",
        processor_level = u16(buf, off + 2),
        processor_revision = u16(buf, off + 4),
        n_processors    = u8(buf, off + 6),
        product_type    = u8(buf, off + 7),
        major_version   = u32(buf, off + 8),
        minor_version   = u32(buf, off + 12),
        build_number    = u32(buf, off + 16),
        platform_id     = u32(buf, off + 20),
        platform_name   = PLATFORM_ID[u32(buf, off + 20)] or "?",
        csd_version     = read_md_string(buf, u32(buf, off + 24)),
    }
    return out
end

-- ----- ModuleList ------------------------------------------------------

function Dump:modules()
    local s = find_stream(self, "ModuleList")
    if not s then return {} end
    local buf, off = self._buf, s.rva
    local n = u32(buf, off)
    local out = {}
    -- MINIDUMP_MODULE is 108 bytes: BaseOfImage(8) SizeOfImage(4) CheckSum(4)
    --   TimeDateStamp(4) ModuleNameRva(4) VersionInfo(52: VS_FIXEDFILEINFO)
    --   CvRecord.{Size, Rva}(8) MiscRecord.{Size, Rva}(8) Reserved0(8)
    --   Reserved1(8). Total = 108.
    local rec_size = 108
    for i = 0, n - 1 do
        local e = off + 4 + i * rec_size
        out[#out + 1] = {
            base       = u64(buf, e + 0),
            size       = u32(buf, e + 8),
            checksum   = u32(buf, e + 12),
            timestamp  = u32(buf, e + 16),
            name       = read_md_string(buf, u32(buf, e + 20)),
            cv_size    = u32(buf, e + 76),
            cv_rva     = u32(buf, e + 80),
        }
    end
    return out
end

-- ----- ThreadList ------------------------------------------------------

function Dump:threads()
    local s = find_stream(self, "ThreadList")
    if not s then return {} end
    local buf, off = self._buf, s.rva
    local n = u32(buf, off)
    -- MINIDUMP_THREAD: ThreadId(4) SuspendCount(4) PriorityClass(4) Priority(4)
    --   Teb(8) Stack.{StartOfMemoryRange(8), Memory.{DataSize(4), Rva(4)}}(16)
    --   ThreadContext.{DataSize(4), Rva(4)}(8). Total = 48 bytes.
    local rec_size = 48
    local out = {}
    for i = 0, n - 1 do
        local e = off + 4 + i * rec_size
        out[#out + 1] = {
            tid           = u32(buf, e + 0),
            suspend_count = u32(buf, e + 4),
            priority_class= u32(buf, e + 8),
            priority      = u32(buf, e + 12),
            teb           = u64(buf, e + 16),
            stack_start   = u64(buf, e + 24),
            stack_size    = u32(buf, e + 32),
            stack_rva     = u32(buf, e + 36),
            context_size  = u32(buf, e + 40),
            context_rva   = u32(buf, e + 44),
        }
    end
    return out
end

-- ----- MemoryList / Memory64List --------------------------------------

local function memory_list(self)
    local s = find_stream(self, "MemoryList")
    if not s then return nil end
    local buf, off = self._buf, s.rva
    local n = u32(buf, off)
    local out = {}
    -- MINIDUMP_MEMORY_DESCRIPTOR: StartOfMemoryRange(8) Memory.{Size(4), Rva(4)}
    local rec_size = 16
    for i = 0, n - 1 do
        local e = off + 4 + i * rec_size
        out[#out + 1] = {
            base = u64(buf, e + 0),
            size = u32(buf, e + 8),
            rva  = u32(buf, e + 12),
        }
    end
    return out
end

local function memory64_list(self)
    local s = find_stream(self, "Memory64List")
    if not s then return nil end
    local buf, off = self._buf, s.rva
    local n_regions = u64(buf, off)
    local base_rva  = u64(buf, off + 8)
    -- MINIDUMP_MEMORY_DESCRIPTOR64: StartOfMemoryRange(8) DataSize(8)
    local out = {}
    local cur_rva = base_rva
    for i = 0, n_regions - 1 do
        local e = off + 16 + i * 16
        local size = u64(buf, e + 8)
        out[#out + 1] = {
            base = u64(buf, e + 0),
            size = size,
            rva  = cur_rva,
        }
        cur_rva = cur_rva + size
    end
    return out
end

function Dump:memory_regions()
    local m = memory_list(self)
    if m then return m end
    m = memory64_list(self)
    if m then return m end
    return {}
end

-- ----- MemoryInfoList -------------------------------------------------

function Dump:memory_info()
    local s = find_stream(self, "MemoryInfoList")
    if not s then return {} end
    local buf, off = self._buf, s.rva
    -- Header: SizeOfHeader(4) SizeOfEntry(4) NumberOfEntries(8)
    local hdr_size = u32(buf, off + 0)
    local ent_size = u32(buf, off + 4)
    local n        = u64(buf, off + 8)
    local out = {}
    -- MINIDUMP_MEMORY_INFO: BaseAddress(8) AllocationBase(8) AllocationProtect(4)
    --   __alignment1(4) RegionSize(8) State(4) Protect(4) Type(4) __alignment2(4)
    for i = 0, n - 1 do
        local e = off + hdr_size + i * ent_size
        out[#out + 1] = {
            base_address       = u64(buf, e + 0),
            allocation_base    = u64(buf, e + 8),
            allocation_protect = u32(buf, e + 16),
            region_size        = u64(buf, e + 24),
            state              = u32(buf, e + 32),
            protect            = u32(buf, e + 36),
            type               = u32(buf, e + 40),
        }
    end
    return out
end

-- ----- HandleData ------------------------------------------------------

function Dump:handles()
    local s = find_stream(self, "HandleData")
    if not s then return {} end
    local buf, off = self._buf, s.rva
    local hdr_size  = u32(buf, off + 0)
    local size_desc = u32(buf, off + 4)
    local n         = u32(buf, off + 8)
    local out = {}
    for i = 0, n - 1 do
        local e = off + hdr_size + i * size_desc
        -- MINIDUMP_HANDLE_DESCRIPTOR (V1): Handle(8) TypeNameRva(4) ObjectNameRva(4)
        --   Attributes(4) GrantedAccess(4) HandleCount(4) PointerCount(4)
        out[#out + 1] = {
            handle         = u64(buf, e + 0),
            type_name      = read_md_string(buf, u32(buf, e + 8)),
            object_name    = read_md_string(buf, u32(buf, e + 12)),
            attributes     = u32(buf, e + 16),
            granted_access = u32(buf, e + 20),
            handle_count   = u32(buf, e + 24),
            pointer_count  = u32(buf, e + 28),
        }
    end
    return out
end

-- ----- Exception ------------------------------------------------------

function Dump:exception()
    local s = find_stream(self, "Exception")
    if not s then return nil end
    local buf, off = self._buf, s.rva
    -- MINIDUMP_EXCEPTION_STREAM: ThreadId(4) __alignment(4)
    --   ExceptionRecord.{ ExceptionCode(4) ExceptionFlags(4) ExceptionRecord(8)
    --                     ExceptionAddress(8) NumberParameters(4) __unusedAlignment(4)
    --                     ExceptionInformation[15](8 each = 120) } -> 152 bytes
    --   ThreadContext.{DataSize(4), Rva(4)}
    local tid = u32(buf, off + 0)
    local rec_off = off + 8
    local params = {}
    local n_params = u32(buf, rec_off + 24)
    for i = 0, math.min(n_params, 15) - 1 do
        params[i + 1] = u64(buf, rec_off + 32 + i * 8)
    end
    return {
        thread_id        = tid,
        exception_code   = u32(buf, rec_off + 0),
        exception_flags  = u32(buf, rec_off + 4),
        exception_record = u64(buf, rec_off + 8),
        exception_address= u64(buf, rec_off + 16),
        parameters       = params,
        context_size     = u32(buf, off + 8 + 152),
        context_rva      = u32(buf, off + 8 + 156),
    }
end

-- ----- MiscInfo -------------------------------------------------------

function Dump:misc()
    local s = find_stream(self, "MiscInfo")
    if not s then return nil end
    local buf, off = self._buf, s.rva
    -- MINIDUMP_MISC_INFO: SizeOfInfo(4) Flags1(4) ProcessId(4) ProcessCreateTime(4)
    --                     ProcessUserTime(4) ProcessKernelTime(4) ...
    return {
        size           = u32(buf, off + 0),
        flags1         = u32(buf, off + 4),
        process_id     = u32(buf, off + 8),
        create_time    = u32(buf, off + 12),
        user_time      = u32(buf, off + 16),
        kernel_time    = u32(buf, off + 20),
    }
end

-- ----- read by virtual address ----------------------------------------

function Dump:read(addr, n)
    if n <= 0 then return "" end
    for _, r in ipairs(self:memory_regions()) do
        if addr >= r.base and addr < r.base + r.size then
            local off = r.rva + (addr - r.base)
            local take = math.min(n, r.base + r.size - addr)
            if off + take > #self._buf then take = #self._buf - off end
            if take <= 0 then return "" end
            return self._buf:sub(off + 1, off + take)
        end
    end
    return nil
end

-- ===== writer (lazy dbghelp) =========================================

local _writer_init = false
local _W
local _DBG

local function ensure_writer()
    if _writer_init then return end
    _W   = require "windows"
    _DBG = require "windows.dbghelp"
    _writer_init = true
end

local TYPE_FLAGS = {
    normal       = function() return _DBG.MiniDumpNormal end,
    full         = function() return bit.bor(_DBG.MiniDumpNormal,
        _DBG.MiniDumpWithFullMemory, _DBG.MiniDumpWithHandleData,
        _DBG.MiniDumpWithThreadInfo, _DBG.MiniDumpWithDataSegs) end,
    with_handles = function() return bit.bor(_DBG.MiniDumpNormal,
        _DBG.MiniDumpWithHandleData) end,
    with_threads = function() return bit.bor(_DBG.MiniDumpNormal,
        _DBG.MiniDumpWithThreadInfo) end,
}

function M.write(path, opts)
    opts = opts or {}
    ensure_writer()

    local pid = opts.pid or tonumber(ffi.C.GetCurrentProcessId())
    local h
    if pid == tonumber(ffi.C.GetCurrentProcessId()) then
        h = ffi.C.GetCurrentProcess()
    else
        h = ffi.C.OpenProcess(_W.PROCESS_ALL_ACCESS, false, pid)
        if h == nil or tonumber(ffi.cast("UINT_PTR", h)) == 0 then
            return nil, string.format("OpenProcess(%d) failed (GLE=%d)",
                pid, tonumber(ffi.C.GetLastError()))
        end
    end

    -- Open the output file via CreateFileW so we get a HANDLE.
    local wpath, _ = _W.ToWide(path)
    local file = ffi.C.CreateFileW(wpath,
        bit.bor(_W.GENERIC_READ, _W.GENERIC_WRITE),
        0, nil, _W.CREATE_ALWAYS, _W.FILE_ATTRIBUTE_NORMAL, nil)
    if file == _W.INVALID_HANDLE_VALUE then
        if h ~= ffi.C.GetCurrentProcess() then ffi.C.CloseHandle(h) end
        return nil, string.format("CreateFileW('%s') failed (GLE=%d)",
            path, tonumber(ffi.C.GetLastError()))
    end

    local kind = opts.type
    local flags
    if type(kind) == "number" then
        flags = kind
    elseif type(kind) == "string" and TYPE_FLAGS[kind] then
        flags = TYPE_FLAGS[kind]()
    else
        flags = _DBG.MiniDumpNormal
    end

    local ok = ffi.C.MiniDumpWriteDump(h, pid, file, flags,
        opts.exception_pointers or nil, nil, nil)
    local gle = tonumber(ffi.C.GetLastError())

    ffi.C.CloseHandle(file)
    if h ~= ffi.C.GetCurrentProcess() then ffi.C.CloseHandle(h) end

    if ok == 0 then
        return nil, string.format("MiniDumpWriteDump failed (GLE=%d)", gle)
    end
    return true
end

return M
