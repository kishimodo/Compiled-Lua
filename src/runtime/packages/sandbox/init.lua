-- sandbox -- Job objects, restricted tokens, app containers, mitigations.
--
-- Public surface:
--   sandbox.job(opts?)                       -> job
--      job:add_process(pid_or_handle)
--      job:run(cmd, opts?)                   -> process from `process` package
--      job:terminate(exit_code?)
--      job:query()                           -> live stats (cpu time, peak mem, ...)
--      job:close()
--
--   sandbox.restricted_token(opts?)          -> handle (caller closes)
--      opts = { remove_privileges={...}, deny_sids={...}, restrict_sids={...},
--               disable_max_privilege=bool }
--
--   sandbox.app_container(name, opts?)       -> container
--      container:run(cmd, opts?)
--      container:remove()
--      container:sid()
--
--   sandbox.set_mitigations(opts?)
--      opts = { dep=true, aslr=true, cfg=true, acg=true,
--               no_child_process=true, no_dynamic_code=true,
--               no_low_label=true, no_remote_image=true,
--               disable_extension_points=true, font_disable=true }
--
-- Job objects are the workhorse here: they bound the wall-clock CPU, the
-- working-set, the process count, and (with kill_on_close) the entire
-- subtree's lifetime against the parent's. Restricted tokens drop
-- well-known SIDs; app containers add an AppContainer SID + capability
-- list so the kernel filters object-manager + file-system access.

local W       = require "windows"
local Wsec    = require "windows.security"
local process = require "process"

ffi.cdef[[
/* ===== Job objects ===== */
HANDLE CreateJobObjectW(SECURITY_ATTRIBUTES *lpJobAttributes, LPCWSTR lpName);
BOOL   AssignProcessToJobObject(HANDLE hJob, HANDLE hProcess);
BOOL   TerminateJobObject(HANDLE hJob, UINT uExitCode);
BOOL   SetInformationJobObject(HANDLE hJob, DWORD JobObjectInformationClass,
                               LPVOID lpJobObjectInformation, DWORD cbJobObjectInformationLength);
BOOL   QueryInformationJobObject(HANDLE hJob, DWORD JobObjectInformationClass,
                                 LPVOID lpJobObjectInformation, DWORD cbJobObjectInformationLength,
                                 LPDWORD lpReturnLength);

typedef struct _JOBOBJECT_BASIC_LIMIT_INFORMATION {
    LONGLONG PerProcessUserTimeLimit;
    LONGLONG PerJobUserTimeLimit;
    DWORD    LimitFlags;
    ULONGLONG MinimumWorkingSetSize;
    ULONGLONG MaximumWorkingSetSize;
    DWORD    ActiveProcessLimit;
    UINT_PTR Affinity;
    DWORD    PriorityClass;
    DWORD    SchedulingClass;
} JOBOBJECT_BASIC_LIMIT_INFORMATION;

typedef struct _IO_COUNTERS_JOB {
    ULONGLONG ReadOperationCount;
    ULONGLONG WriteOperationCount;
    ULONGLONG OtherOperationCount;
    ULONGLONG ReadTransferCount;
    ULONGLONG WriteTransferCount;
    ULONGLONG OtherTransferCount;
} IO_COUNTERS_JOB;

typedef struct _JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
    JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
    IO_COUNTERS_JOB                   IoInfo;
    ULONGLONG                         ProcessMemoryLimit;
    ULONGLONG                         JobMemoryLimit;
    ULONGLONG                         PeakProcessMemoryUsed;
    ULONGLONG                         PeakJobMemoryUsed;
} JOBOBJECT_EXTENDED_LIMIT_INFORMATION;

typedef struct _JOBOBJECT_CPU_RATE_CONTROL_INFORMATION {
    DWORD ControlFlags;
    DWORD CpuRate;  /* in 1/100% (i.e. 5000 == 50% of total CPU) */
} JOBOBJECT_CPU_RATE_CONTROL_INFORMATION;

typedef struct _JOBOBJECT_BASIC_UI_RESTRICTIONS {
    DWORD UIRestrictionsClass;
} JOBOBJECT_BASIC_UI_RESTRICTIONS;

typedef struct _JOBOBJECT_BASIC_ACCOUNTING_INFORMATION {
    LONGLONG TotalUserTime;
    LONGLONG TotalKernelTime;
    LONGLONG ThisPeriodTotalUserTime;
    LONGLONG ThisPeriodTotalKernelTime;
    DWORD    TotalPageFaultCount;
    DWORD    TotalProcesses;
    DWORD    ActiveProcesses;
    DWORD    TotalTerminatedProcesses;
} JOBOBJECT_BASIC_ACCOUNTING_INFORMATION;

/* ===== Restricted tokens ===== */
typedef struct _SID_AND_ATTRIBUTES {
    PVOID Sid;
    DWORD Attributes;
} SID_AND_ATTRIBUTES;

typedef struct _LUID_AND_ATTRIBUTES_S {
    LONGLONG Luid;
    DWORD    Attributes;
} LUID_AND_ATTRIBUTES_S;

BOOL CreateRestrictedToken(HANDLE ExistingTokenHandle, DWORD Flags,
                           DWORD DisableSidCount, SID_AND_ATTRIBUTES *SidsToDisable,
                           DWORD DeletePrivilegeCount, LUID_AND_ATTRIBUTES_S *PrivilegesToDelete,
                           DWORD RestrictedSidCount, SID_AND_ATTRIBUTES *SidsToRestrict,
                           HANDLE *NewTokenHandle);

BOOL AllocateAndInitializeSid(BYTE *pIdentifierAuthority, BYTE nSubAuthorityCount,
                              DWORD nSubAuthority0, DWORD nSubAuthority1,
                              DWORD nSubAuthority2, DWORD nSubAuthority3,
                              DWORD nSubAuthority4, DWORD nSubAuthority5,
                              DWORD nSubAuthority6, DWORD nSubAuthority7,
                              PVOID *pSid);
PVOID FreeSid(PVOID pSid);
BOOL  ConvertStringSidToSidW(LPCWSTR StringSid, PVOID *Sid);
BOOL  LocalFree_Sandbox /* alias */(HANDLE hMem);

/* ===== Mitigations ===== */
BOOL SetProcessMitigationPolicy(DWORD MitigationPolicy, PVOID lpBuffer, ULONGLONG dwLength);

/* ===== App containers ===== */
HRESULT CreateAppContainerProfile(LPCWSTR pszAppContainerName, LPCWSTR pszDisplayName,
                                  LPCWSTR pszDescription, void *pCapabilities,
                                  DWORD dwCapabilityCount, PVOID *ppSidAppContainerSid);
HRESULT DeleteAppContainerProfile(LPCWSTR pszAppContainerName);
HRESULT DeriveAppContainerSidFromAppContainerName(LPCWSTR pszAppContainerName,
                                                  PVOID *ppsidAppContainerSid);
]]

pcall(ffi.load, "kernel32")
pcall(ffi.load, "advapi32")
pcall(ffi.load, "userenv")

local C = ffi.C
local M = {}

-- ===== Job-info-class constants =======================================
M.JobObjectBasicLimitInformation       = 2
M.JobObjectBasicUIRestrictions         = 4
M.JobObjectBasicAccountingInformation  = 1
M.JobObjectExtendedLimitInformation    = 9
M.JobObjectCpuRateControlInformation   = 15

-- BasicLimit LimitFlags
M.JOB_OBJECT_LIMIT_WORKINGSET                = 0x0001
M.JOB_OBJECT_LIMIT_PROCESS_TIME              = 0x0002
M.JOB_OBJECT_LIMIT_JOB_TIME                  = 0x0004
M.JOB_OBJECT_LIMIT_ACTIVE_PROCESS            = 0x0008
M.JOB_OBJECT_LIMIT_AFFINITY                  = 0x0010
M.JOB_OBJECT_LIMIT_PRIORITY_CLASS            = 0x0020
M.JOB_OBJECT_LIMIT_PRESERVE_JOB_TIME         = 0x0040
M.JOB_OBJECT_LIMIT_SCHEDULING_CLASS          = 0x0080
M.JOB_OBJECT_LIMIT_PROCESS_MEMORY            = 0x0100
M.JOB_OBJECT_LIMIT_JOB_MEMORY                = 0x0200
M.JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION = 0x0400
M.JOB_OBJECT_LIMIT_BREAKAWAY_OK              = 0x0800
M.JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK       = 0x1000
M.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE         = 0x2000

-- CPU rate control flags
M.JOB_OBJECT_CPU_RATE_CONTROL_ENABLE = 0x1
M.JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP = 0x4

-- UI restriction class bits
M.JOB_OBJECT_UILIMIT_HANDLES        = 0x01
M.JOB_OBJECT_UILIMIT_READCLIPBOARD  = 0x02
M.JOB_OBJECT_UILIMIT_WRITECLIPBOARD = 0x04
M.JOB_OBJECT_UILIMIT_SYSTEMPARAMETERS = 0x08
M.JOB_OBJECT_UILIMIT_DISPLAYSETTINGS = 0x10
M.JOB_OBJECT_UILIMIT_GLOBALATOMS    = 0x20
M.JOB_OBJECT_UILIMIT_DESKTOP        = 0x40
M.JOB_OBJECT_UILIMIT_EXITWINDOWS    = 0x80

-- Restricted-token flags
M.DISABLE_MAX_PRIVILEGE = 0x1
M.SANDBOX_INERT         = 0x2
M.LUA_TOKEN             = 0x4
M.WRITE_RESTRICTED      = 0x8

-- ===== Job object wrapper =============================================

local Job = {}
Job.__index = Job

function Job:add_process(pid_or_handle)
    local h
    if type(pid_or_handle) == "number" then
        h = C.OpenProcess(W.PROCESS_ALL_ACCESS, false, pid_or_handle)
        if h == nil then
            error("sandbox.job:add_process: OpenProcess GLE="
                .. tonumber(C.GetLastError()))
        end
    elseif type(pid_or_handle) == "cdata" then
        h = pid_or_handle
    elseif type(pid_or_handle) == "table" and pid_or_handle.handle then
        h = pid_or_handle:handle()
    else
        error("sandbox.job:add_process: expected pid or handle")
    end
    if C.AssignProcessToJobObject(self._h, h) == 0 then
        error("sandbox.job:add_process: AssignProcessToJobObject GLE="
            .. tonumber(C.GetLastError()))
    end
    return true
end

function Job:run(cmd, opts)
    opts = opts or {}
    -- We need to assign the process to the job before it executes user code
    -- to enforce the limits from the start. CREATE_SUSPENDED handles this:
    -- spawn suspended, assign, then resume the main thread.
    local p, err = process.spawn(cmd, opts)
    if not p then return nil, err end
    -- Best-effort assign. If the OS already let the process run because the
    -- caller did not pass CREATE_SUSPENDED, the assign still applies for the
    -- remaining lifetime (and child processes if breakaway is disallowed).
    self:add_process(p:handle())
    return p
end

function Job:terminate(exit_code)
    if self._h == nil then return end
    if C.TerminateJobObject(self._h, exit_code or 1) == 0 then
        -- Already terminated: don't raise.
    end
end

function Job:query()
    if self._h == nil then return nil end
    local acct = ffi.new("JOBOBJECT_BASIC_ACCOUNTING_INFORMATION")
    local ret  = ffi.new("DWORD[1]")
    local ok = C.QueryInformationJobObject(self._h,
        M.JobObjectBasicAccountingInformation,
        acct, ffi.sizeof("JOBOBJECT_BASIC_ACCOUNTING_INFORMATION"), ret)
    if ok == 0 then return nil end
    local ext = ffi.new("JOBOBJECT_EXTENDED_LIMIT_INFORMATION")
    C.QueryInformationJobObject(self._h,
        M.JobObjectExtendedLimitInformation,
        ext, ffi.sizeof("JOBOBJECT_EXTENDED_LIMIT_INFORMATION"), ret)
    return {
        user_time_100ns   = tonumber(acct.TotalUserTime),
        kernel_time_100ns = tonumber(acct.TotalKernelTime),
        page_faults       = tonumber(acct.TotalPageFaultCount),
        total_processes   = tonumber(acct.TotalProcesses),
        active_processes  = tonumber(acct.ActiveProcesses),
        peak_proc_memory  = tonumber(ext.PeakProcessMemoryUsed),
        peak_job_memory   = tonumber(ext.PeakJobMemoryUsed),
        read_ops          = tonumber(ext.IoInfo.ReadOperationCount),
        write_ops         = tonumber(ext.IoInfo.WriteOperationCount),
    }
end

function Job:close()
    if self._h ~= nil then
        C.CloseHandle(self._h)
        self._h = nil
    end
end

function M.job(opts)
    opts = opts or {}
    local name_w = opts.name and W.ToWide(opts.name) or nil
    local h = C.CreateJobObjectW(nil, name_w)
    if h == nil then
        error("sandbox.job: CreateJobObjectW GLE=" .. tonumber(C.GetLastError()))
    end

    -- Extended limits block (covers memory + kill-on-close in one call).
    local kill_on_close = (opts.kill_on_close ~= false)
    local ext = ffi.new("JOBOBJECT_EXTENDED_LIMIT_INFORMATION")
    local flags = 0
    if kill_on_close then flags = flags + M.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE end
    if opts.die_on_unhandled then flags = flags + M.JOB_OBJECT_LIMIT_DIE_ON_UNHANDLED_EXCEPTION end
    if opts.memory_limit_mb then
        ext.JobMemoryLimit = opts.memory_limit_mb * 1024 * 1024
        flags = flags + M.JOB_OBJECT_LIMIT_JOB_MEMORY
    end
    if opts.process_memory_limit_mb then
        ext.ProcessMemoryLimit = opts.process_memory_limit_mb * 1024 * 1024
        flags = flags + M.JOB_OBJECT_LIMIT_PROCESS_MEMORY
    end
    if opts.process_count_limit then
        ext.BasicLimitInformation.ActiveProcessLimit = opts.process_count_limit
        flags = flags + M.JOB_OBJECT_LIMIT_ACTIVE_PROCESS
    end
    if opts.priority_class then
        ext.BasicLimitInformation.PriorityClass = opts.priority_class
        flags = flags + M.JOB_OBJECT_LIMIT_PRIORITY_CLASS
    end
    if opts.affinity_mask then
        ext.BasicLimitInformation.Affinity = opts.affinity_mask
        flags = flags + M.JOB_OBJECT_LIMIT_AFFINITY
    end
    ext.BasicLimitInformation.LimitFlags = flags

    if C.SetInformationJobObject(h, M.JobObjectExtendedLimitInformation,
            ext, ffi.sizeof("JOBOBJECT_EXTENDED_LIMIT_INFORMATION")) == 0 then
        C.CloseHandle(h)
        error("sandbox.job: SetInformationJobObject(ext) GLE=" .. tonumber(C.GetLastError()))
    end

    -- CPU rate cap (percentage, 1-100).
    if opts.cpu_limit_pct then
        local rate = ffi.new("JOBOBJECT_CPU_RATE_CONTROL_INFORMATION")
        rate.ControlFlags = M.JOB_OBJECT_CPU_RATE_CONTROL_ENABLE
            + M.JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP
        rate.CpuRate = math.floor(opts.cpu_limit_pct * 100)  -- 1/100 of one percent
        if C.SetInformationJobObject(h, M.JobObjectCpuRateControlInformation,
                rate, ffi.sizeof("JOBOBJECT_CPU_RATE_CONTROL_INFORMATION")) == 0 then
            C.CloseHandle(h)
            error("sandbox.job: SetInformationJobObject(cpu_rate) GLE=" .. tonumber(C.GetLastError()))
        end
    end

    -- UI restrictions
    if opts.ui_restrictions then
        local ui_flags = 0
        local r = opts.ui_restrictions
        if r.handles         then ui_flags = ui_flags + M.JOB_OBJECT_UILIMIT_HANDLES end
        if r.read_clipboard  then ui_flags = ui_flags + M.JOB_OBJECT_UILIMIT_READCLIPBOARD end
        if r.write_clipboard then ui_flags = ui_flags + M.JOB_OBJECT_UILIMIT_WRITECLIPBOARD end
        if r.system_params   then ui_flags = ui_flags + M.JOB_OBJECT_UILIMIT_SYSTEMPARAMETERS end
        if r.display_settings then ui_flags = ui_flags + M.JOB_OBJECT_UILIMIT_DISPLAYSETTINGS end
        if r.global_atoms    then ui_flags = ui_flags + M.JOB_OBJECT_UILIMIT_GLOBALATOMS end
        if r.desktop         then ui_flags = ui_flags + M.JOB_OBJECT_UILIMIT_DESKTOP end
        if r.exit_windows    then ui_flags = ui_flags + M.JOB_OBJECT_UILIMIT_EXITWINDOWS end
        if ui_flags ~= 0 then
            local uir = ffi.new("JOBOBJECT_BASIC_UI_RESTRICTIONS")
            uir.UIRestrictionsClass = ui_flags
            C.SetInformationJobObject(h, M.JobObjectBasicUIRestrictions,
                uir, ffi.sizeof("JOBOBJECT_BASIC_UI_RESTRICTIONS"))
        end
    end

    local j = setmetatable({ _h = h, _opts = opts }, Job)
    return j
end

-- ===== Restricted tokens ==============================================

-- Build a SID via AllocateAndInitializeSid for one of the common well-knowns,
-- OR via ConvertStringSidToSidW for a SDDL string like "S-1-1-0".
local function resolve_sid(spec)
    if type(spec) == "cdata" then return spec, false end
    if type(spec) == "string" then
        -- "S-1-..." textual SID -> ConvertStringSidToSidW (LocalFree to release)
        local wsid = W.ToWide(spec)
        local p = ffi.new("PVOID[1]")
        if C.ConvertStringSidToSidW(wsid, p) == 0 then
            error("sandbox.restricted_token: ConvertStringSidToSidW(" .. spec .. ") failed")
        end
        return p[0], "localfree"
    end
    error("sandbox.restricted_token: bad SID spec (need string or cdata)")
end

local function release_sid(sid, kind)
    if not sid then return end
    if kind == "localfree" then
        C.LocalFree(sid)
    elseif kind == "freesid" then
        C.FreeSid(sid)
    end
end

function M.restricted_token(opts)
    opts = opts or {}
    local current = ffi.new("HANDLE[1]")
    if C.OpenProcessToken(C.GetCurrentProcess(),
            Wsec.TOKEN_DUPLICATE + Wsec.TOKEN_QUERY + Wsec.TOKEN_ADJUST_PRIVILEGES,
            current) == 0 then
        error("sandbox.restricted_token: OpenProcessToken GLE=" .. tonumber(C.GetLastError()))
    end

    -- Resolve all SIDs / privileges up front so we can free them after.
    local deny_anchors, deny_arr, deny_count = {}, nil, 0
    if opts.deny_sids and #opts.deny_sids > 0 then
        deny_count = #opts.deny_sids
        deny_arr = ffi.new("SID_AND_ATTRIBUTES[?]", deny_count)
        for i, s in ipairs(opts.deny_sids) do
            local sid, kind = resolve_sid(s)
            deny_anchors[#deny_anchors + 1] = { sid = sid, kind = kind }
            deny_arr[i - 1].Sid = sid
            deny_arr[i - 1].Attributes = 0  -- SE_GROUP_USE_FOR_DENY_ONLY set internally
        end
    end

    local rest_anchors, rest_arr, rest_count = {}, nil, 0
    if opts.restrict_sids and #opts.restrict_sids > 0 then
        rest_count = #opts.restrict_sids
        rest_arr = ffi.new("SID_AND_ATTRIBUTES[?]", rest_count)
        for i, s in ipairs(opts.restrict_sids) do
            local sid, kind = resolve_sid(s)
            rest_anchors[#rest_anchors + 1] = { sid = sid, kind = kind }
            rest_arr[i - 1].Sid = sid
            rest_arr[i - 1].Attributes = 0
        end
    end

    local priv_arr, priv_count = nil, 0
    if opts.remove_privileges and #opts.remove_privileges > 0 then
        priv_count = #opts.remove_privileges
        priv_arr = ffi.new("LUID_AND_ATTRIBUTES_S[?]", priv_count)
        for i, name in ipairs(opts.remove_privileges) do
            local luid = ffi.new("LONGLONG[1]")
            local wn = W.ToWide(name)
            if C.LookupPrivilegeValueW(nil, wn, luid) == 0 then
                error("sandbox.restricted_token: LookupPrivilegeValueW("
                    .. name .. ") GLE=" .. tonumber(C.GetLastError()))
            end
            priv_arr[i - 1].Luid = luid[0]
            priv_arr[i - 1].Attributes = 0
        end
    end

    local flags = 0
    if opts.disable_max_privilege then flags = flags + M.DISABLE_MAX_PRIVILEGE end
    if opts.sandbox_inert         then flags = flags + M.SANDBOX_INERT end
    if opts.lua_token             then flags = flags + M.LUA_TOKEN end
    if opts.write_restricted      then flags = flags + M.WRITE_RESTRICTED end

    local new_tok = ffi.new("HANDLE[1]")
    local ok = C.CreateRestrictedToken(current[0], flags,
        deny_count, deny_arr,
        priv_count, priv_arr,
        rest_count, rest_arr,
        new_tok)

    C.CloseHandle(current[0])
    for _, a in ipairs(deny_anchors) do release_sid(a.sid, a.kind) end
    for _, a in ipairs(rest_anchors) do release_sid(a.sid, a.kind) end

    if ok == 0 then
        error("sandbox.restricted_token: CreateRestrictedToken GLE="
            .. tonumber(C.GetLastError()))
    end
    return new_tok[0]
end

-- ===== App containers =================================================

local AppContainer = {}
AppContainer.__index = AppContainer

function AppContainer:sid() return self._sid end

function AppContainer:remove()
    -- DeleteAppContainerProfile removes the profile and any associated
    -- per-user state. The SID is still alive but ineffective once the
    -- profile is gone.
    if self._name then
        local wn = W.ToWide(self._name)
        C.DeleteAppContainerProfile(wn)
        self._name = nil
    end
end

function AppContainer:run(cmd, _opts)
    -- Spawning into an app container requires UpdateProcThreadAttribute
    -- with PROC_THREAD_ATTRIBUTE_SECURITY_CAPABILITIES, which needs the
    -- STARTUPINFOEX surface. process.spawn doesn't expose that path; we
    -- error out instead of silently running outside the container.
    error("sandbox.app_container:run: not yet wired through process.spawn -- "
        .. "use sid() with a CreateProcessAsUserW caller for now")
end

function M.app_container(name, opts)
    opts = opts or {}
    local wn  = W.ToWide(name)
    local wd  = W.ToWide(opts.display_name or name)
    local wdesc = W.ToWide(opts.description or name)
    local sid = ffi.new("PVOID[1]")

    -- Try create; if it already exists, derive the SID instead.
    local hr = tonumber(C.CreateAppContainerProfile(wn, wd, wdesc, nil, 0, sid))
    if hr ~= 0 then
        local norm = hr < 0 and (hr + 0x100000000) or hr
        if norm == 0x800700B7 then  -- ERROR_ALREADY_EXISTS
            local hr2 = tonumber(C.DeriveAppContainerSidFromAppContainerName(wn, sid))
            if hr2 ~= 0 then
                error(string.format("sandbox.app_container: DeriveAppContainerSid 0x%08X", hr2 % 0x100000000))
            end
        else
            error(string.format("sandbox.app_container: CreateAppContainerProfile 0x%08X", norm))
        end
    end
    return setmetatable({
        _name = name,
        _sid  = sid[0],
    }, AppContainer)
end

-- ===== Process mitigations ============================================
--
-- Each PROCESS_MITIGATION_*_POLICY is a tiny struct (usually a single
-- DWORD-of-bits). The kernel reads (length, ptr) and validates against
-- its known layout. We build each policy on the fly when its key is set
-- in opts.

-- Policy IDs (PROCESS_MITIGATION_POLICY enum)
local POLICY = {
    DEP                 = 0,
    ASLR                = 1,
    DYNAMIC_CODE        = 2,
    STRICT_HANDLE_CHECK = 3,
    SYSTEM_CALL_DISABLE = 4,
    EXTENSION_POINT_DISABLE = 6,
    CFG                 = 7,
    BINARY_SIGNATURE    = 8,
    FONT_DISABLE        = 9,
    IMAGE_LOAD          = 10,
    SYSTEM_CALL_FILTER  = 11,
    PAYLOAD_RESTRICTION = 12,
    CHILD_PROCESS       = 13,
    SIDE_CHANNEL_ISOLATION = 14,
    USER_SHADOW_STACK   = 15,
    REDIRECTION_TRUST   = 16,
}

local function set_policy_dword(id, dword)
    local buf = ffi.new("DWORD[1]")
    buf[0] = dword
    return C.SetProcessMitigationPolicy(id, buf, ffi.sizeof("DWORD"))
end

function M.set_mitigations(opts)
    opts = opts or {}
    local applied, failed = {}, {}

    local function try(name, id, dword)
        local ok = (set_policy_dword(id, dword) ~= 0)
        if ok then applied[#applied + 1] = name
        else failed[#failed + 1] = { name = name, gle = tonumber(C.GetLastError()) } end
    end

    -- DEP (PROCESS_MITIGATION_DEP_POLICY): bit0 = Enable, bit1 = DisableAtlThunkEmulation,
    -- bit2 = Permanent.
    if opts.dep then
        try("dep", POLICY.DEP, 0x5)  -- Enable + Permanent
    end

    -- ASLR (PROCESS_MITIGATION_ASLR_POLICY): bit0=EnableBottomUpRandomization,
    -- bit1=EnableForceRelocateImages, bit2=EnableHighEntropy, bit3=DisallowStrippedImages.
    if opts.aslr then
        try("aslr", POLICY.ASLR, 0xF)
    end

    -- CFG (PROCESS_MITIGATION_CONTROL_FLOW_GUARD_POLICY): bit0=EnableControlFlowGuard,
    -- bit1=EnableExportSuppression, bit2=StrictMode.
    if opts.cfg then
        try("cfg", POLICY.CFG, 0x7)
    end

    -- ACG / Dynamic-code (PROCESS_MITIGATION_DYNAMIC_CODE_POLICY): bit0=ProhibitDynamicCode,
    -- bit1=AllowThreadOptOut, bit2=AllowRemoteDowngrade.
    if opts.acg or opts.no_dynamic_code then
        try("acg", POLICY.DYNAMIC_CODE, 0x1)
    end

    -- Child-process creation: bit0=NoChildProcessCreation, bit1=AuditNoChildProcessCreation.
    if opts.no_child_process then
        try("no_child_process", POLICY.CHILD_PROCESS, 0x1)
    end

    -- Image-load (no remote / no low-integrity-label):
    --   bit0=NoRemoteImages, bit1=NoLowMandatoryLabelImages, bit2=PreferSystem32Images.
    if opts.no_remote_image or opts.no_low_label then
        local v = 0
        if opts.no_remote_image then v = v + 0x1 end
        if opts.no_low_label    then v = v + 0x2 end
        if opts.prefer_system32 then v = v + 0x4 end
        try("image_load", POLICY.IMAGE_LOAD, v)
    end

    -- Extension-point DLLs (AppInit_DLLs, IME bypass): bit0=DisableExtensionPoints.
    if opts.disable_extension_points then
        try("disable_extension_points", POLICY.EXTENSION_POINT_DISABLE, 0x1)
    end

    -- Font loading (non-system fonts): bit0=DisableNonSystemFonts.
    if opts.font_disable then
        try("font_disable", POLICY.FONT_DISABLE, 0x1)
    end

    -- Strict handle checks: bit0=RaiseExceptionOnInvalidHandleReference,
    -- bit1=HandleExceptionsPermanentlyEnabled.
    if opts.strict_handle_check then
        try("strict_handle_check", POLICY.STRICT_HANDLE_CHECK, 0x3)
    end

    -- Payload restrictions (return-flow guard etc): bit0=EnableExportAddressFilter,
    -- bit2=EnableImportAddressFilter, bit4=EnableRopStackPivot, bit6=EnableRopCallerCheck,
    -- bit8=EnableRopSimExec.
    if opts.payload_restriction then
        try("payload_restriction", POLICY.PAYLOAD_RESTRICTION, 0x155)
    end

    return { applied = applied, failed = failed }
end

return M
