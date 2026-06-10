-- cpu -- processor identification, topology and utilization.
--
-- Public surface:
--   cpu.info()                            -> { vendor, brand, family, model, stepping,
--                                              cores_physical, cores_logical, threads_per_core,
--                                              frequency_mhz, cache={L1d,L1i,L2,L3},
--                                              features={...}, architecture }
--   cpu.count()                           -> logical core count
--   cpu.count_physical()                  -> physical core count
--   cpu.utilization(interval_ms?)         -> aggregate percentage [0,100]
--   cpu.per_core_utilization(interval_ms?) -> list of percentages, one per logical core
--   cpu.frequency()                       -> nominal MHz (CPUID brand or WMI MaxClockSpeed)
--   cpu.temperature()                     -> degrees Celsius (best-effort WMI MSAcpi_ThermalZoneTemperature)
--   cpu.topology()                        -> { numa_nodes={...}, caches={...}, cores={...}, packages={...} }
--
-- Notes:
--   * Frequency reporting is intentionally "nominal" (the rated clock from
--     the brand string or WMI MaxClockSpeed). Boost / per-core actuals
--     require performance counters and are out of scope here.
--   * Temperature comes from WMI's root\wmi MSAcpi_ThermalZoneTemperature
--     and frequently requires admin -- we just return nil if it isn't
--     available rather than throwing.

local W = require "windows"

ffi.cdef[[
void  GetSystemInfo(SYSTEM_INFO *);
void  GetNativeSystemInfo(SYSTEM_INFO *);
BOOL  GetSystemTimes(FILETIME *, FILETIME *, FILETIME *);
BOOL  GetLogicalProcessorInformationEx(DWORD, void *, DWORD *);

typedef struct _SYSTEM_INFO_CPU {
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
} SYSTEM_INFO_CPU;

/* NtQuerySystemInformation -- SystemProcessorPerformanceInformation = 8.
   The per-CPU record: KERNEL/USER/IDLE 64-bit times in 100ns units. */
typedef struct _SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION_CPU {
    LONGLONG IdleTime;
    LONGLONG KernelTime;
    LONGLONG UserTime;
    LONGLONG DpcTime;
    LONGLONG InterruptTime;
    ULONG    InterruptCount;
} SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION_CPU;
]]

local C = ffi.C
local M = {}

-- ===== architecture decode =================================================

local function arch_string(wArch)
    if wArch == 0      then return "x86"
    elseif wArch == 5  then return "arm"
    elseif wArch == 6  then return "ia64"
    elseif wArch == 9  then return "x86_64"
    elseif wArch == 12 then return "arm64"
    end
    return "unknown"
end

-- ===== GetSystemTimes sampling =============================================

local function ft_to_u64(ft)
    return ft.dwLowDateTime + (ft.dwHighDateTime * 4294967296.0)
end

local function sample_system_times()
    local idle = ffi.new("FILETIME[1]")
    local kern = ffi.new("FILETIME[1]")
    local user = ffi.new("FILETIME[1]")
    if C.GetSystemTimes(idle, kern, user) == 0 then
        return nil
    end
    return ft_to_u64(idle[0]), ft_to_u64(kern[0]), ft_to_u64(user[0])
end

local function sleep_ms(ms)
    C.Sleep(ms)
end

function M.utilization(interval_ms)
    interval_ms = interval_ms or 200
    local i0, k0, u0 = sample_system_times()
    if not i0 then return 0 end
    sleep_ms(interval_ms)
    local i1, k1, u1 = sample_system_times()
    local d_idle = i1 - i0
    local d_busy = (k1 - k0) + (u1 - u0) - d_idle
    -- kernel includes idle; subtract to get just busy.
    local total = (k1 - k0) + (u1 - u0)
    if total <= 0 then return 0 end
    local pct = (d_busy / total) * 100
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    return pct
end

-- ===== per-core utilization (NtQuerySystemInformation) =====================

local SystemProcessorPerformanceInformation = 8

local function sample_per_core(n)
    local elem = ffi.sizeof("SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION_CPU")
    local buf  = ffi.new("SYSTEM_PROCESSOR_PERFORMANCE_INFORMATION_CPU[?]", n)
    local ret  = ffi.new("ULONG[1]")
    local status = C.NtQuerySystemInformation(
        SystemProcessorPerformanceInformation,
        buf, elem * n, ret)
    if status ~= 0 then return nil end
    return buf
end

function M.per_core_utilization(interval_ms)
    interval_ms = interval_ms or 200
    local n = M.count()
    local s0 = sample_per_core(n)
    if not s0 then return {} end
    -- Snapshot the kernel/idle pair (clone via copy since the next call
    -- overwrites the same buffer's source).
    local cap = {}
    for i = 0, n - 1 do
        cap[i] = {
            idle = tonumber(s0[i].IdleTime),
            kern = tonumber(s0[i].KernelTime),
            user = tonumber(s0[i].UserTime),
        }
    end
    sleep_ms(interval_ms)
    local s1 = sample_per_core(n)
    if not s1 then return {} end
    local out = {}
    for i = 0, n - 1 do
        local d_idle = tonumber(s1[i].IdleTime) - cap[i].idle
        local d_kern = tonumber(s1[i].KernelTime) - cap[i].kern
        local d_user = tonumber(s1[i].UserTime)   - cap[i].user
        local total  = d_kern + d_user
        local busy   = total - d_idle
        local pct = 0
        if total > 0 then pct = (busy / total) * 100 end
        if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
        out[i + 1] = pct
    end
    return out
end

-- ===== counts ==============================================================

local _si_cache
local function get_sysinfo()
    if _si_cache then return _si_cache end
    local si = ffi.new("SYSTEM_INFO_CPU[1]")
    C.GetNativeSystemInfo(ffi.cast("SYSTEM_INFO *", si))
    _si_cache = si[0]
    return _si_cache
end

function M.count()
    return tonumber(get_sysinfo().dwNumberOfProcessors)
end

-- ===== topology via GetLogicalProcessorInformationEx =======================
--
-- The Ex variant returns variable-size records of type
-- SYSTEM_LOGICAL_PROCESSOR_INFORMATION_EX. We walk the buffer manually
-- (the size field at offset 4 tells us how big each record is) and only
-- decode the relationship + the bits we actually expose.

local RelationProcessorCore = 0
local RelationNumaNode      = 1
local RelationCache         = 2
local RelationProcessorPackage = 3
local RelationGroup         = 4
local RelationAll           = 0xFFFF

local function read_dword(buf, off)
    return tonumber(ffi.cast("DWORD *", buf + off)[0])
end
local function read_word(buf, off)
    return tonumber(ffi.cast("WORD *", buf + off)[0])
end
local function read_byte(buf, off)
    return tonumber(ffi.cast("BYTE *", buf + off)[0])
end

local function query_logical_proc_info_ex(rel)
    local len = ffi.new("DWORD[1]", 0)
    C.GetLogicalProcessorInformationEx(rel, nil, len)
    if len[0] == 0 then return nil end
    local buf = ffi.new("char[?]", len[0])
    if C.GetLogicalProcessorInformationEx(rel, buf, len) == 0 then
        return nil
    end
    return buf, len[0]
end

-- Count physical cores by walking RelationProcessorCore records.
local function count_physical_cores()
    local buf, len = query_logical_proc_info_ex(RelationProcessorCore)
    if not buf then return nil end
    local n = 0
    local off = 0
    while off < len do
        local rec_size = read_dword(buf, off + 4)
        if rec_size == 0 then break end
        n = n + 1
        off = off + rec_size
    end
    return n
end

function M.count_physical()
    local n = count_physical_cores()
    return n or M.count()
end

-- topology() yields a structured view with numa_nodes, caches, cores, packages.
function M.topology()
    local buf, len = query_logical_proc_info_ex(RelationAll)
    if not buf then return { numa_nodes = {}, caches = {}, cores = {}, packages = {} } end
    local out = { numa_nodes = {}, caches = {}, cores = {}, packages = {} }
    local off = 0
    while off < len do
        local rel = read_dword(buf, off + 0)
        local sz  = read_dword(buf, off + 4)
        if sz == 0 then break end
        local payload = off + 8  -- skip Relationship + Size header
        if rel == RelationProcessorCore then
            local flags  = read_byte(buf, payload + 0)
            local effcls = read_byte(buf, payload + 1)
            local groups = read_word(buf, payload + 2)
            out.cores[#out.cores + 1] = {
                smt              = (flags % 2) == 1,    -- LTP_PC_SMT
                efficiency_class = effcls,
                group_count      = groups,
            }
        elseif rel == RelationNumaNode then
            local node = read_dword(buf, payload + 0)
            out.numa_nodes[#out.numa_nodes + 1] = { node = node }
        elseif rel == RelationCache then
            local level   = read_byte(buf, payload + 0)
            local assoc   = read_byte(buf, payload + 1)
            local linesz  = read_word(buf, payload + 2)
            local cachesz = read_dword(buf, payload + 4)
            local ctype   = read_dword(buf, payload + 8)
            local cnames  = { [0]="unified", [1]="instruction", [2]="data", [3]="trace" }
            out.caches[#out.caches + 1] = {
                level         = level,
                associativity = assoc,
                line_size     = linesz,
                size          = cachesz,
                type          = cnames[ctype] or "unknown",
            }
        elseif rel == RelationProcessorPackage then
            out.packages[#out.packages + 1] = { index = #out.packages + 1 }
        end
        off = off + sz
    end
    return out
end

-- ===== frequency (nominal) =================================================

local function freq_from_brand(brand)
    -- Brand strings often end with "@ 3.20GHz" / "3.40 GHz" / "1.80 GHz" etc.
    local g = brand:match("(%d+%.?%d*)%s*GHz")
    if g then return math.floor(tonumber(g) * 1000 + 0.5) end
    local m = brand:match("(%d+%.?%d*)%s*MHz")
    if m then return math.floor(tonumber(m) + 0.5) end
    return nil
end

local _wmi_cpu_cache
local function wmi_processor_record()
    if _wmi_cpu_cache ~= nil then return _wmi_cpu_cache end
    local ok, wmi = pcall(require, "wmi")
    if not ok then _wmi_cpu_cache = false; return nil end
    local ok2, rows = pcall(wmi.processors)
    if not ok2 or not rows or #rows == 0 then
        _wmi_cpu_cache = false; return nil
    end
    _wmi_cpu_cache = rows[1]
    return _wmi_cpu_cache
end

function M.frequency()
    -- Prefer CPUID brand parsing for accuracy on Intel; fall back to WMI.
    local ok, cpuid = pcall(require, "cpuid")
    if ok then
        local b = cpuid.brand()
        local f = b and freq_from_brand(b) or nil
        if f then return f end
    end
    local rec = wmi_processor_record()
    if rec and rec.MaxClockSpeed then return rec.MaxClockSpeed end
    return nil
end

-- ===== temperature (best-effort) ==========================================

function M.temperature()
    local ok, wmi = pcall(require, "wmi")
    if not ok then return nil end
    local svc, err = wmi.connect("root\\wmi")
    if not svc then return nil end
    local ok2, rows = pcall(function()
        return svc:query_all("SELECT CurrentTemperature FROM MSAcpi_ThermalZoneTemperature")
    end)
    svc:close()
    if not ok2 or not rows or #rows == 0 then return nil end
    local r = rows[1]
    if not r.CurrentTemperature then return nil end
    -- MSAcpi_ThermalZoneTemperature reports tenths of degrees Kelvin.
    return (r.CurrentTemperature / 10) - 273.15
end

-- ===== info() ==============================================================

local function feature_list(features)
    if not features then return {} end
    local names = {}
    for name, on in pairs(features) do
        if on == true then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

function M.info()
    local si = get_sysinfo()
    local logical = tonumber(si.dwNumberOfProcessors)
    local physical = M.count_physical()
    if not physical or physical < 1 then physical = logical end
    local tpc = math.max(1, math.floor(logical / physical))

    local out = {
        vendor           = nil,
        brand            = nil,
        family           = nil,
        model            = nil,
        stepping         = nil,
        cores_physical   = physical,
        cores_logical    = logical,
        threads_per_core = tpc,
        frequency_mhz    = M.frequency(),
        cache            = { L1d = nil, L1i = nil, L2 = nil, L3 = nil },
        features         = {},
        architecture     = arch_string(si.wProcessorArchitecture),
    }

    local ok, cpuid = pcall(require, "cpuid")
    if ok then
        out.vendor   = cpuid.vendor()
        out.brand    = cpuid.brand()
        out.family   = cpuid.family()
        out.model    = cpuid.model()
        out.stepping = cpuid.stepping()
        out.features = feature_list(cpuid.features())
        local ci     = cpuid.cache_info()
        out.cache.L1d = ci.l1d
        out.cache.L1i = ci.l1i
        out.cache.L2  = ci.l2
        out.cache.L3  = ci.l3
    end

    if not out.vendor or out.vendor == "" then
        -- WMI fallback for non-x86 / cpuid-unavailable hosts.
        local rec = wmi_processor_record()
        if rec then
            out.vendor = rec.Manufacturer
            out.brand  = rec.Name
        end
    end

    return out
end

return M
