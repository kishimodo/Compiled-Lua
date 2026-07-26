-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- memory_info -- system and per-process memory reporting.
--
-- Public surface:
--   memory_info.system()                  -> { total_mb, available_mb, used_mb,
--                                              free_pct, total_pagefile_mb,
--                                              available_pagefile_mb, total_virtual_mb,
--                                              available_virtual_mb, memory_load }
--   memory_info.process(pid?)             -> { working_set_mb, peak_working_set_mb,
--                                              page_faults, pagefile_usage_mb,
--                                              peak_pagefile_mb, private_bytes_mb,
--                                              private_working_set_mb }
--   memory_info.working_set_detail(pid?)  -> { { address, attributes, shared, valid,
--                                                share_count, win32protection,
--                                                node, locked, large_page }, ... }
--   memory_info.page_size()               -> int (bytes)

local W = require "windows"
require "windows.psapi"

ffi.cdef[[
BOOL GlobalMemoryStatusEx(MEMORYSTATUSEX *);

typedef struct _PROCESS_MEMORY_COUNTERS_EX {
    DWORD     cb;
    DWORD     PageFaultCount;
    ULONGLONG PeakWorkingSetSize;
    ULONGLONG WorkingSetSize;
    ULONGLONG QuotaPeakPagedPoolUsage;
    ULONGLONG QuotaPagedPoolUsage;
    ULONGLONG QuotaPeakNonPagedPoolUsage;
    ULONGLONG QuotaNonPagedPoolUsage;
    ULONGLONG PagefileUsage;
    ULONGLONG PeakPagefileUsage;
    ULONGLONG PrivateUsage;
} PROCESS_MEMORY_COUNTERS_EX;

BOOL GetProcessMemoryInfo(HANDLE, PROCESS_MEMORY_COUNTERS_EX *, DWORD);

typedef struct _MEMORYSTATUSEX_LOCAL {
    DWORD     dwLength;
    DWORD     dwMemoryLoad;
    ULONGLONG ullTotalPhys;
    ULONGLONG ullAvailPhys;
    ULONGLONG ullTotalPageFile;
    ULONGLONG ullAvailPageFile;
    ULONGLONG ullTotalVirtual;
    ULONGLONG ullAvailVirtual;
    ULONGLONG ullAvailExtendedVirtual;
} MEMORYSTATUSEX_LOCAL;

/* PSAPI_WORKING_SET_EX_INFORMATION is per-page; we pass it as an array. */
typedef struct _PSAPI_WORKING_SET_EX_INFORMATION {
    void     *VirtualAddress;
    ULONGLONG VirtualAttributes;
} PSAPI_WORKING_SET_EX_INFORMATION;

BOOL QueryWorkingSetEx(HANDLE hProcess, void *pv, DWORD cb);

/* GetSystemInfo for page size */
void GetSystemInfo(SYSTEM_INFO *);
typedef struct _SYSTEM_INFO_MEM {
    WORD   wProcessorArchitecture;
    WORD   wReserved;
    DWORD  dwPageSize;
    void  *lpMinimumApplicationAddress;
    void  *lpMaximumApplicationAddress;
    void  *dwActiveProcessorMask;
    DWORD  dwNumberOfProcessors;
    DWORD  dwProcessorType;
    DWORD  dwAllocationGranularity;
    WORD   wProcessorLevel;
    WORD   wProcessorRevision;
} SYSTEM_INFO_MEM;
]]

local C = ffi.C
local M = {}

local MB = 1024 * 1024

local _page_size
function M.page_size()
    if _page_size then return _page_size end
    local si = ffi.new("SYSTEM_INFO_MEM[1]")
    C.GetSystemInfo(ffi.cast("SYSTEM_INFO *", si))
    _page_size = tonumber(si[0].dwPageSize)
    return _page_size
end

-- ===== system() ============================================================

function M.system()
    local ms = ffi.new("MEMORYSTATUSEX_LOCAL[1]")
    ms[0].dwLength = ffi.sizeof("MEMORYSTATUSEX_LOCAL")
    if C.GlobalMemoryStatusEx(ffi.cast("MEMORYSTATUSEX *", ms)) == 0 then
        error("memory_info.system: GlobalMemoryStatusEx failed")
    end
    local total = tonumber(ms[0].ullTotalPhys)
    local avail = tonumber(ms[0].ullAvailPhys)
    local used  = total - avail
    return {
        total_mb              = math.floor(total / MB),
        available_mb          = math.floor(avail / MB),
        used_mb               = math.floor(used / MB),
        free_pct              = total > 0 and (avail / total) * 100 or 0,
        memory_load           = tonumber(ms[0].dwMemoryLoad),
        total_pagefile_mb     = math.floor(tonumber(ms[0].ullTotalPageFile) / MB),
        available_pagefile_mb = math.floor(tonumber(ms[0].ullAvailPageFile) / MB),
        total_virtual_mb      = math.floor(tonumber(ms[0].ullTotalVirtual) / MB),
        available_virtual_mb  = math.floor(tonumber(ms[0].ullAvailVirtual) / MB),
    }
end

-- ===== process(pid?) =======================================================
--
-- pid = nil  -> current process (pseudo-handle)
-- pid set    -> open with PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_VM_READ.

local PROCESS_QUERY_INFORMATION = 0x0400
local PROCESS_VM_READ           = 0x0010

local function open_proc(pid)
    if pid == nil then return C.GetCurrentProcess(), false end
    local h = C.OpenProcess(
        bit.bor(PROCESS_QUERY_INFORMATION, PROCESS_VM_READ),
        false, pid)
    if h == nil then
        error("memory_info: OpenProcess(" .. tostring(pid) .. ") failed")
    end
    return h, true
end

function M.process(pid)
    local h, owned = open_proc(pid)
    local cnt = ffi.new("PROCESS_MEMORY_COUNTERS_EX[1]")
    cnt[0].cb = ffi.sizeof("PROCESS_MEMORY_COUNTERS_EX")
    local psapi = pcall(ffi.load, "psapi") and ffi.load("psapi") or C
    local ok = psapi.GetProcessMemoryInfo(h,
        ffi.cast("PROCESS_MEMORY_COUNTERS_EX *", cnt),
        ffi.sizeof("PROCESS_MEMORY_COUNTERS_EX"))
    if ok == 0 then
        if owned then C.CloseHandle(h) end
        error("memory_info.process: GetProcessMemoryInfo failed")
    end

    local out = {
        working_set_mb         = math.floor(tonumber(cnt[0].WorkingSetSize) / MB),
        peak_working_set_mb    = math.floor(tonumber(cnt[0].PeakWorkingSetSize) / MB),
        page_faults            = tonumber(cnt[0].PageFaultCount),
        pagefile_usage_mb      = math.floor(tonumber(cnt[0].PagefileUsage) / MB),
        peak_pagefile_mb       = math.floor(tonumber(cnt[0].PeakPagefileUsage) / MB),
        private_bytes_mb       = math.floor(tonumber(cnt[0].PrivateUsage) / MB),
        private_working_set_mb = nil,  -- filled below from working_set_detail
    }

    -- private_working_set: sum of pages whose Shared bit is 0.
    -- Cost-bounded: only do this if pid wasn't supplied or fewer than
    -- ~256 MB resident, to stay cheap.
    if tonumber(cnt[0].WorkingSetSize) <= 256 * MB then
        local pages = M.working_set_detail(pid)
        if pages then
            local priv = 0
            local ps = M.page_size()
            for _, p in ipairs(pages) do
                if p.valid and not p.shared then
                    priv = priv + ps
                end
            end
            out.private_working_set_mb = math.floor(priv / MB)
        end
    end

    if owned then C.CloseHandle(h) end
    return out
end

-- ===== working_set_detail(pid?) ===========================================
--
-- VirtualAttributes bit layout (PSAPI_WORKING_SET_EX_BLOCK):
--   bit 0       : Valid
--   bits 1..3   : ShareCount
--   bits 4..14  : Win32Protection
--   bit 15      : Shared
--   bits 16..21 : Node
--   bit 22      : Locked
--   bit 23      : LargePage
--   bit 24..28  : Reserved
--   bit 29      : Bad
--   bits 30..63 : Reserved
--
-- We surface the bits people actually care about.

local function decode_attrs(attr)
    local a = tonumber(attr)
    if a == nil then return { valid = false } end
    return {
        valid           = (a % 2) == 1,
        share_count     = math.floor(a / 2) % 8,
        win32protection = math.floor(a / 16) % 2048,
        shared          = math.floor(a / 32768) % 2 == 1,
        node            = math.floor(a / 65536) % 64,
        locked          = math.floor(a / 4194304) % 2 == 1,
        large_page      = math.floor(a / 8388608) % 2 == 1,
    }
end

function M.working_set_detail(pid)
    local h, owned = open_proc(pid)
    -- Walk the process address space via VirtualQueryEx-style iteration is
    -- expensive; instead, query the working set in one shot. The proper
    -- approach is QueryWorkingSet (PSAPI_WORKING_SET_INFORMATION) -> the
    -- list of VAs, then QueryWorkingSetEx on that list. That requires a
    -- two-call sizing dance; keep things bounded by capping the page list.
    --
    -- Bound: 64 K pages = 256 MB at 4 K pages. Beyond that we truncate.
    local MAX_PAGES = 65536
    local arr = ffi.new("PSAPI_WORKING_SET_EX_INFORMATION[?]", MAX_PAGES)
    -- Walk MEMORY_BASIC_INFORMATION regions to enumerate committed pages.
    local ps = M.page_size()
    local addr = 0
    local count = 0
    local mbi = ffi.new("MEMORY_BASIC_INFORMATION[1]")
    while count < MAX_PAGES do
        local got = C.VirtualQuery(
            ffi.cast("LPCVOID", addr), mbi, ffi.sizeof("MEMORY_BASIC_INFORMATION"))
        if got == 0 then break end
        local base = tonumber(ffi.cast("UINT_PTR", mbi[0].BaseAddress))
        local size = tonumber(mbi[0].RegionSize)
        local state = tonumber(mbi[0].State)
        if state == 0x1000 then  -- MEM_COMMIT
            local n = math.floor(size / ps)
            if n > MAX_PAGES - count then n = MAX_PAGES - count end
            for j = 0, n - 1 do
                arr[count + j].VirtualAddress = ffi.cast("void *", base + j * ps)
                arr[count + j].VirtualAttributes = 0
            end
            count = count + n
        end
        -- Progress must be measured against the address we QUERIED, not against
        -- the base VirtualQuery handed back. Those differ at the top of the x64
        -- user address space: querying 0x7fffffff0000 returns a region whose
        -- base+size lands back on 0x7fffffff0000, so `addr` stops advancing.
        -- Comparing to `base` did not catch that, and because `count` also stops
        -- growing once there are no further MEM_COMMIT regions, `count <
        -- MAX_PAGES` never became false -- an infinite loop. Measured before this
        -- fix: addr frozen at 0x7fffffff0000 and count frozen at 7,992 across
        -- 400,000 iterations. It was invisible because test_memory_info skipped
        -- for want of a MEMORYSTATUSEX typedef and so never ran this path.
        local next_addr = base + size
        if next_addr <= addr then break end
        addr = next_addr
    end

    if count == 0 then
        if owned then C.CloseHandle(h) end
        return {}
    end

    local psapi = pcall(ffi.load, "psapi") and ffi.load("psapi") or C
    local ok = psapi.QueryWorkingSetEx(h, arr,
        count * ffi.sizeof("PSAPI_WORKING_SET_EX_INFORMATION"))
    if ok == 0 then
        if owned then C.CloseHandle(h) end
        return {}
    end

    local out = {}
    for i = 0, count - 1 do
        local d = decode_attrs(arr[i].VirtualAttributes)
        d.address = tonumber(ffi.cast("UINT_PTR", arr[i].VirtualAddress))
        out[i + 1] = d
    end

    if owned then C.CloseHandle(h) end
    return out
end

return M
