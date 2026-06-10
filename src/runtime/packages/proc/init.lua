-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- proc -- Windows process / thread / module / handle / token enumeration.
--
-- Public surface:
--   proc.processes()         -> { {pid, name, parent_pid, threads, exe_path?, ...}, ... }
--   proc.process_info(pid)   -> details (everything we can cheaply gather)
--   proc.modules(pid)        -> { {name, base, size, path}, ... }
--   proc.threads(pid?)       -> { {tid, base_pri, delta_pri, start_addr?}, ... }
--   proc.handles(pid?)       -> { {pid, handle, obj_addr, granted_access, type_index}, ... }
--   proc.tokens(pid)         -> { user=, groups=, privileges= }
--   proc.find_by_name(pat)   -> { pid, ... }   (Lua-pattern match against exe name)
--   proc.find_by_pid(pid)    -> process object (with method surface below) or nil
--   proc.open(pid, access?)  -> process object
--   proc.process_tree()      -> rooted forest [{pid, name, children={...}}, ...]
--
-- Process object methods (returned from proc.find_by_pid / proc.open):
--   :info()              -> info table
--   :modules()           -> module list
--   :threads()           -> thread list
--   :tokens()            -> token info
--   :command_line()      -> string or nil
--   :owner()             -> user SID string or nil
--   :kill(exit_code?)
--   :suspend()
--   :resume()
--   :close()
--
-- A note on opening processes: many calls below require at least
-- PROCESS_QUERY_LIMITED_INFORMATION. We try PROCESS_QUERY_INFORMATION first
-- (the historically common right) then fall back to LIMITED, then give up.

require "windows"
local W  = require "windows"
local TH = require "windows.toolhelp"
local NT = require "windows.ntdll"
local SEC= require "windows.security"
require "windows.psapi"

ffi.cdef[[
DWORD QueryFullProcessImageNameW(HANDLE hProcess, DWORD dwFlags, LPWSTR lpExeName, LPDWORD lpdwSize);
BOOL ReadProcessMemory(HANDLE hProcess, LPCVOID lpBaseAddress, LPVOID lpBuffer,
                       ULONGLONG nSize, ULONGLONG *lpNumberOfBytesRead);
]]

local M = {}

local _CreateSnap = ffi.C.CreateToolhelp32Snapshot
local _CloseHandle = ffi.C.CloseHandle

local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

-- ===== helpers =========================================================

local function wstring(wbuf, max_chars)
    -- Convert a stack-allocated WCHAR[N] (with embedded NUL) to Lua string.
    local out = {}
    for i = 0, max_chars - 1 do
        local c = wbuf[i]
        if c == 0 then break end
        if c < 0x80 then
            out[#out + 1] = string.char(c)
        else
            -- Encode as UTF-8 (BMP fast path).
            if c < 0x800 then
                out[#out + 1] = string.char(0xC0 + math.floor(c / 0x40))
                out[#out + 1] = string.char(0x80 + (c % 0x40))
            else
                out[#out + 1] = string.char(0xE0 + math.floor(c / 0x1000))
                out[#out + 1] = string.char(0x80 + (math.floor(c / 0x40) % 0x40))
                out[#out + 1] = string.char(0x80 + (c % 0x40))
            end
        end
    end
    return table.concat(out)
end

local function open_proc_safe(pid, access)
    -- Prefer fully-privileged QUERY_INFORMATION; fall back to LIMITED so
    -- non-admin enumerations still get a name + image path.
    local h = ffi.C.OpenProcess(access or W.PROCESS_QUERY_INFORMATION, false, pid)
    if h == nil or tonumber(ffi.cast("UINT_PTR", h)) == 0 then
        h = ffi.C.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
    end
    if h == nil or tonumber(ffi.cast("UINT_PTR", h)) == 0 then return nil end
    return h
end

local function get_image_path(h)
    local buf = ffi.new("unsigned short[1024]")
    local size = ffi.new("DWORD[1]", 1024)
    if ffi.C.QueryFullProcessImageNameW(h, 0, buf, size) == 0 then
        return nil
    end
    return wstring(buf, tonumber(size[0]))
end

-- ===== processes() =====================================================

function M.processes()
    local snap = _CreateSnap(TH.TH32CS_SNAPPROCESS, 0)
    if snap == W.INVALID_HANDLE_VALUE then
        error("proc.processes: CreateToolhelp32Snapshot failed")
    end

    local out = {}
    local pe = ffi.new("PROCESSENTRY32W")
    pe.dwSize = ffi.sizeof("PROCESSENTRY32W")
    if ffi.C.Process32FirstW(snap, pe) ~= 0 then
        repeat
            local entry = {
                pid        = tonumber(pe.th32ProcessID),
                parent_pid = tonumber(pe.th32ParentProcessID),
                threads    = tonumber(pe.cntThreads),
                name       = wstring(pe.szExeFile, 260),
            }
            -- Image path is optional -- only fill if cheap.
            local h = open_proc_safe(entry.pid)
            if h then
                entry.exe_path = get_image_path(h)
                _CloseHandle(h)
            end
            out[#out + 1] = entry
        until ffi.C.Process32NextW(snap, pe) == 0
    end
    _CloseHandle(snap)
    return out
end

function M.find_by_name(pat)
    local out = {}
    for _, p in ipairs(M.processes()) do
        if p.name:find(pat) then out[#out + 1] = p.pid end
    end
    return out
end

function M.process_tree()
    local procs = M.processes()
    local nodes = {}
    for _, p in ipairs(procs) do
        nodes[p.pid] = { pid = p.pid, name = p.name, parent_pid = p.parent_pid, children = {} }
    end
    local roots = {}
    for _, p in ipairs(procs) do
        local parent = nodes[p.parent_pid]
        if parent and parent ~= nodes[p.pid] then
            parent.children[#parent.children + 1] = nodes[p.pid]
        else
            roots[#roots + 1] = nodes[p.pid]
        end
    end
    return roots
end

-- ===== process_info() ==================================================

function M.process_info(pid)
    local info = { pid = pid }
    -- Walk the snapshot once -- avoids a second NtQuerySystemInformation.
    for _, p in ipairs(M.processes()) do
        if p.pid == pid then
            info.name = p.name
            info.parent_pid = p.parent_pid
            info.threads = p.threads
            info.exe_path = p.exe_path
            break
        end
    end
    if not info.name then return nil, "no such pid" end

    -- Modules + thread list are independent calls.
    info.modules = M.modules(pid)
    info.thread_list = M.threads(pid)
    return info
end

-- ===== modules(pid) ====================================================

function M.modules(pid)
    local snap = _CreateSnap(bit.bor(TH.TH32CS_SNAPMODULE, TH.TH32CS_SNAPMODULE32), pid)
    if snap == W.INVALID_HANDLE_VALUE then return {} end

    local out = {}
    local me = ffi.new("MODULEENTRY32W")
    me.dwSize = ffi.sizeof("MODULEENTRY32W")
    if ffi.C.Module32FirstW(snap, me) ~= 0 then
        repeat
            out[#out + 1] = {
                name = wstring(me.szModule, 256),
                path = wstring(me.szExePath, 260),
                base = tonumber(ffi.cast("UINT_PTR", me.modBaseAddr)),
                size = tonumber(me.modBaseSize),
            }
        until ffi.C.Module32NextW(snap, me) == 0
    end
    _CloseHandle(snap)
    return out
end

-- ===== threads(pid) ====================================================

ffi.cdef[[
NTSTATUS NtQueryInformationThread(HANDLE, ULONG, PVOID, ULONG, ULONG *);
HANDLE OpenThread(DWORD, BOOL, DWORD);
]]

local THREAD_QUERY_LIMITED_INFORMATION = 0x0800
local ThreadQuerySetWin32StartAddress = 9

function M.threads(pid)
    -- When pid is nil we list all system threads.
    local snap = _CreateSnap(TH.TH32CS_SNAPTHREAD, 0)
    if snap == W.INVALID_HANDLE_VALUE then return {} end

    local out = {}
    local te = ffi.new("THREADENTRY32")
    te.dwSize = ffi.sizeof("THREADENTRY32")
    if ffi.C.Thread32First(snap, te) ~= 0 then
        repeat
            local owner = tonumber(te.th32OwnerProcessID)
            if pid == nil or owner == pid then
                local tid = tonumber(te.th32ThreadID)
                local entry = {
                    tid = tid,
                    pid = owner,
                    base_pri  = tonumber(te.tpBasePri),
                    delta_pri = tonumber(te.tpDeltaPri),
                }
                local th = ffi.C.OpenThread(THREAD_QUERY_LIMITED_INFORMATION, false, tid)
                if th ~= nil and tonumber(ffi.cast("UINT_PTR", th)) ~= 0 then
                    local addr = ffi.new("ULONGLONG[1]")
                    local got = ffi.new("ULONG[1]")
                    local rc = ffi.C.NtQueryInformationThread(
                        th, ThreadQuerySetWin32StartAddress,
                        addr, ffi.sizeof("ULONGLONG"), got)
                    if rc == 0 then
                        entry.start_addr = tonumber(addr[0])
                    end
                    _CloseHandle(th)
                end
                out[#out + 1] = entry
            end
        until ffi.C.Thread32Next(snap, te) == 0
    end
    _CloseHandle(snap)
    return out
end

-- ===== handles(pid?) ===================================================
--
-- SystemHandleInformation (16) returns the system-wide handle table. The
-- entry shape (16 bytes on 32-bit, identical layout on 64-bit thanks to
-- the natural padding) is:
--   USHORT UniqueProcessId
--   USHORT CreatorBackTraceIndex
--   UCHAR  ObjectTypeIndex
--   UCHAR  HandleAttributes
--   USHORT HandleValue
--   PVOID  Object         (kernel pointer)
--   ULONG  GrantedAccess
-- Layout note: x86 = 16B, x64 = 24B (pointer alignment). Detect at runtime.

ffi.cdef[[
typedef struct _SYSTEM_HANDLE_INFORMATION_ENTRY32 {
    USHORT UniqueProcessId;
    USHORT CreatorBackTraceIndex;
    BYTE   ObjectTypeIndex;
    BYTE   HandleAttributes;
    USHORT HandleValue;
    PVOID  Object;
    ULONG  GrantedAccess;
} SYSTEM_HANDLE_INFORMATION_ENTRY32;
]]

local _is_x64 = ffi.sizeof("void *") == 8

function M.handles(pid_filter)
    -- Try sizes until NtQuerySystemInformation stops complaining.
    local size = 0x10000
    local out_size = ffi.new("ULONG[1]")
    local buf
    for _ = 1, 8 do
        buf = ffi.new("uint8_t[?]", size)
        local rc = ffi.C.NtQuerySystemInformation(NT.SystemHandleInformation, buf, size, out_size)
        if rc == 0 then break end
        -- STATUS_INFO_LENGTH_MISMATCH = 0xC0000004 (signed -> -1073741820)
        if rc ~= -1073741820 then
            error(string.format("proc.handles: NtQuerySystemInformation 0x%08X", rc))
        end
        size = math.max(size * 2, tonumber(out_size[0]) + 0x1000)
    end

    local count = ffi.cast("ULONG *", buf)[0]
    local entries_base = ffi.cast("uint8_t *", buf) + 4
    local entry_size = _is_x64 and 24 or 16
    local out = {}
    for i = 0, count - 1 do
        local e = entries_base + i * entry_size
        local upid = ffi.cast("USHORT *", e)[0]
        local obj_type = e[4]
        local attrs    = e[5]
        local handle_val = ffi.cast("USHORT *", e + 6)[0]
        local object, granted
        if _is_x64 then
            -- pad[2], then PVOID at +8, then ULONG at +16
            object  = ffi.cast("UINT_PTR *", e + 8)[0]
            granted = ffi.cast("ULONG *", e + 16)[0]
        else
            object  = ffi.cast("UINT_PTR *", e + 8)[0]
            granted = ffi.cast("ULONG *", e + 12)[0]
        end
        if pid_filter == nil or tonumber(upid) == pid_filter then
            out[#out + 1] = {
                pid = tonumber(upid),
                handle = tonumber(handle_val),
                type_index = tonumber(obj_type),
                attributes = tonumber(attrs),
                obj_addr = tonumber(object),
                granted_access = tonumber(granted),
            }
        end
    end
    return out
end

-- ===== tokens(pid) =====================================================
--
-- Decoding TOKEN_USER / TOKEN_GROUPS / TOKEN_PRIVILEGES requires walking
-- a SID variable-length structure. We do the minimum: capture the raw
-- bytes + the SID string form for the user, plus name/LUID lookups for
-- privileges. This avoids cdef'ing the whole TOKEN_* zoo.

ffi.cdef[[
BOOL ConvertSidToStringSidA(PVOID Sid, LPSTR *StringSid);
BOOL LookupPrivilegeNameW(LPCWSTR lpSystemName, LONGLONG *lpLuid,
                          LPWSTR lpName, LPDWORD cchName);
void *LocalFree(void *hMem);

typedef struct _SID_AND_ATTRIBUTES {
    PVOID Sid;
    DWORD Attributes;
} SID_AND_ATTRIBUTES;
typedef struct _TOKEN_USER {
    SID_AND_ATTRIBUTES User;
} TOKEN_USER;
typedef struct _TOKEN_GROUPS {
    DWORD GroupCount;
    SID_AND_ATTRIBUTES Groups[1];
} TOKEN_GROUPS;
typedef struct _LUID_AND_ATTRIBUTES {
    LONGLONG Luid;
    DWORD Attributes;
} LUID_AND_ATTRIBUTES;
typedef struct _TOKEN_PRIVILEGES {
    DWORD PrivilegeCount;
    LUID_AND_ATTRIBUTES Privileges[1];
} TOKEN_PRIVILEGES;
]]

local _ConvertSidToStringSidA -- lazy: advapi32 already loaded via core
local function sid_to_string(sid_ptr)
    if sid_ptr == nil then return nil end
    if not _ConvertSidToStringSidA then
        _ConvertSidToStringSidA = ffi.C.ConvertSidToStringSidA
    end
    local out = ffi.new("char *[1]")
    if _ConvertSidToStringSidA(sid_ptr, out) == 0 then return nil end
    local s = ffi.string(out[0])
    ffi.C.LocalFree(out[0])
    return s
end

local function luid_to_priv_name(luid_value)
    local luid = ffi.new("LONGLONG[1]", luid_value)
    local name = ffi.new("unsigned short[256]")
    local size = ffi.new("DWORD[1]", 256)
    if ffi.C.LookupPrivilegeNameW(nil, luid, name, size) == 0 then return nil end
    return wstring(name, tonumber(size[0]))
end

local function get_token_info(token, info_class, initial)
    local size = ffi.new("DWORD[1]", initial or 0)
    -- First call sizes; second call fills.
    ffi.C.GetTokenInformation(token, info_class, nil, 0, size)
    if tonumber(size[0]) == 0 then return nil end
    local buf = ffi.new("uint8_t[?]", size[0])
    if ffi.C.GetTokenInformation(token, info_class, buf, size[0], size) == 0 then
        return nil
    end
    return buf, tonumber(size[0])
end

function M.tokens(pid)
    local h = open_proc_safe(pid, W.PROCESS_QUERY_INFORMATION)
    if not h then return nil, "OpenProcess failed" end
    local token = ffi.new("HANDLE[1]")
    if ffi.C.OpenProcessToken(h, SEC.TOKEN_QUERY, token) == 0 then
        _CloseHandle(h)
        return nil, "OpenProcessToken failed"
    end
    _CloseHandle(h)
    token = ffi.gc(token[0], _CloseHandle)

    local out = { user = nil, groups = {}, privileges = {} }

    -- TokenUser
    local buf = get_token_info(token, SEC.TokenUser)
    if buf then
        local tu = ffi.cast("TOKEN_USER *", buf)
        out.user = {
            sid = sid_to_string(tu.User.Sid),
            attributes = tonumber(tu.User.Attributes),
        }
    end

    -- TokenGroups
    buf = get_token_info(token, SEC.TokenGroups)
    if buf then
        local tg = ffi.cast("TOKEN_GROUPS *", buf)
        for i = 0, tonumber(tg.GroupCount) - 1 do
            local g = tg.Groups[i]
            out.groups[#out.groups + 1] = {
                sid = sid_to_string(g.Sid),
                attributes = tonumber(g.Attributes),
            }
        end
    end

    -- TokenPrivileges
    buf = get_token_info(token, SEC.TokenPrivileges)
    if buf then
        local tp = ffi.cast("TOKEN_PRIVILEGES *", buf)
        for i = 0, tonumber(tp.PrivilegeCount) - 1 do
            local p = tp.Privileges[i]
            out.privileges[#out.privileges + 1] = {
                name = luid_to_priv_name(tonumber(p.Luid)),
                attributes = tonumber(p.Attributes),
                enabled = bit.band(tonumber(p.Attributes),
                    SEC.SE_PRIVILEGE_ENABLED) ~= 0,
            }
        end
    end

    return out
end

-- ===== process object surface ==========================================
--
-- A thin wrapper that holds the PID and lazily opens a fresh handle for
-- each operation that needs one. Why not cache one handle? Different ops
-- require different access masks (kill needs PROCESS_TERMINATE; reading
-- the command line needs PROCESS_VM_READ + PROCESS_QUERY_INFORMATION).
-- Open-on-demand keeps the minimum rights for each call.

ffi.cdef[[
NTSTATUS NtSuspendProcess(HANDLE ProcessHandle);
NTSTATUS NtResumeProcess(HANDLE ProcessHandle);
NTSTATUS NtQueryInformationProcess(HANDLE, ULONG, PVOID, ULONG, ULONG *);
]]

local ProcessBasicInformation = 0
local ProcessCommandLineInformation = 60

-- Approximate PEB / RTL_USER_PROCESS_PARAMETERS layout: we only need
-- ProcessParameters offset (0x20 on x64), and the CommandLine UNICODE_STRING
-- within RTL_USER_PROCESS_PARAMETERS (offset 0x70 on x64).
ffi.cdef[[
typedef struct _UNICODE_STRING_BRIEF {
    USHORT Length;
    USHORT MaximumLength;
    PVOID  Buffer;
} UNICODE_STRING_BRIEF;
typedef struct _PROCESS_BASIC_INFORMATION_BRIEF {
    ULONGLONG ExitStatus;
    PVOID     PebBaseAddress;
    ULONGLONG AffinityMask;
    ULONG     BasePriority;
    ULONG     _pad;
    ULONGLONG UniqueProcessId;
    ULONGLONG ParentProcessId;
} PROCESS_BASIC_INFORMATION_BRIEF;
]]

local Process = {}
Process.__index = Process

function M.open(pid, access)
    return setmetatable({ pid = pid, _access = access }, Process)
end

function M.find_by_pid(pid)
    for _, p in ipairs(M.processes()) do
        if p.pid == pid then
            local obj = M.open(pid)
            for k, v in pairs(p) do
                if obj[k] == nil then obj[k] = v end
            end
            return obj
        end
    end
    return nil
end

function Process:info() return M.process_info(self.pid) end
function Process:modules() return M.modules(self.pid) end
function Process:threads() return M.threads(self.pid) end
function Process:tokens() return M.tokens(self.pid) end

function Process:kill(exit_code)
    local h = open_proc_safe(self.pid, W.PROCESS_TERMINATE)
    if not h then return nil, "OpenProcess(PROCESS_TERMINATE) failed" end
    local ok = ffi.C.TerminateProcess(h, exit_code or 1)
    _CloseHandle(h)
    if ok == 0 then return nil, "TerminateProcess failed" end
    return true
end

function Process:suspend()
    local h = open_proc_safe(self.pid, W.PROCESS_SUSPEND_RESUME)
    if not h then return nil, "OpenProcess(SUSPEND_RESUME) failed" end
    local rc = ffi.C.NtSuspendProcess(h)
    _CloseHandle(h)
    if rc ~= 0 then return nil, string.format("NtSuspendProcess 0x%08X", rc) end
    return true
end

function Process:resume()
    local h = open_proc_safe(self.pid, W.PROCESS_SUSPEND_RESUME)
    if not h then return nil, "OpenProcess(SUSPEND_RESUME) failed" end
    local rc = ffi.C.NtResumeProcess(h)
    _CloseHandle(h)
    if rc ~= 0 then return nil, string.format("NtResumeProcess 0x%08X", rc) end
    return true
end

-- Command line via NtQueryInformationProcess(ProcessCommandLineInformation, ...)
-- (Win8.1+). Falls back to walking PEB->ProcessParameters on older OSes.
function Process:command_line()
    local h = open_proc_safe(self.pid,
        bit.bor(W.PROCESS_QUERY_INFORMATION, W.PROCESS_VM_READ))
    if not h then return nil end

    -- Fast path: ProcessCommandLineInformation returns a UNICODE_STRING
    -- followed by the buffer in a single allocation.
    do
        local size = ffi.new("ULONG[1]")
        ffi.C.NtQueryInformationProcess(h, ProcessCommandLineInformation, nil, 0, size)
        if tonumber(size[0]) > 0 then
            local buf = ffi.new("uint8_t[?]", size[0])
            local rc = ffi.C.NtQueryInformationProcess(h,
                ProcessCommandLineInformation, buf, size[0], size)
            if rc == 0 then
                local us = ffi.cast("UNICODE_STRING_BRIEF *", buf)
                local nchars = tonumber(us.Length) / 2
                if nchars > 0 and us.Buffer ~= nil then
                    local wbuf = ffi.cast("unsigned short *", us.Buffer)
                    local out = {}
                    for i = 0, nchars - 1 do
                        local c = wbuf[i]
                        if c < 0x80 then out[#out + 1] = string.char(c)
                        elseif c < 0x800 then
                            out[#out + 1] = string.char(0xC0 + math.floor(c / 0x40),
                                0x80 + (c % 0x40))
                        else
                            out[#out + 1] = string.char(0xE0 + math.floor(c / 0x1000),
                                0x80 + (math.floor(c / 0x40) % 0x40),
                                0x80 + (c % 0x40))
                        end
                    end
                    _CloseHandle(h)
                    return table.concat(out)
                end
            end
        end
    end

    -- Fallback: walk PEB. Layout offsets are x64-only.
    local pbi = ffi.new("PROCESS_BASIC_INFORMATION_BRIEF")
    local got = ffi.new("ULONG[1]")
    if ffi.C.NtQueryInformationProcess(h, ProcessBasicInformation,
            pbi, ffi.sizeof(pbi), got) ~= 0 then
        _CloseHandle(h)
        return nil
    end
    local peb_addr = tonumber(ffi.cast("UINT_PTR", pbi.PebBaseAddress))
    if peb_addr == 0 then _CloseHandle(h) return nil end

    -- PEB.ProcessParameters @ +0x20 on x64
    local pp_ptr = ffi.new("ULONGLONG[1]")
    local rb = ffi.new("ULONGLONG[1]")
    if ffi.C.ReadProcessMemory(h, ffi.cast("LPCVOID", peb_addr + 0x20),
            pp_ptr, 8, rb) == 0 then
        _CloseHandle(h)
        return nil
    end
    local pp_addr = tonumber(pp_ptr[0])

    -- RTL_USER_PROCESS_PARAMETERS.CommandLine UNICODE_STRING @ +0x70 on x64
    local us = ffi.new("UNICODE_STRING_BRIEF")
    if ffi.C.ReadProcessMemory(h, ffi.cast("LPCVOID", pp_addr + 0x70),
            us, ffi.sizeof(us), rb) == 0 then
        _CloseHandle(h)
        return nil
    end
    local nchars = tonumber(us.Length) / 2
    if nchars <= 0 then _CloseHandle(h) return "" end
    local wbuf = ffi.new("unsigned short[?]", nchars)
    if ffi.C.ReadProcessMemory(h, ffi.cast("LPCVOID",
            tonumber(ffi.cast("UINT_PTR", us.Buffer))),
            wbuf, nchars * 2, rb) == 0 then
        _CloseHandle(h)
        return nil
    end
    _CloseHandle(h)
    local out = {}
    for i = 0, nchars - 1 do
        local c = wbuf[i]
        if c < 0x80 then out[#out + 1] = string.char(c)
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

-- Owner: derive from the process token user SID.
function Process:owner()
    local tk = self:tokens()
    if not tk or not tk.user then return nil end
    return tk.user.sid
end

function Process:close()
    -- No state to release: we open handles on demand and close immediately.
end

return M
