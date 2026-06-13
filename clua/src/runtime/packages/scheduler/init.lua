-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- scheduler -- Windows Task Scheduler v2 wrapper via COM (taskschd.dll).
--
-- Talks to the scheduler the same way PowerShell does: by going through
-- ITaskService::Connect / NewTask / RegisterTaskDefinition. We drive each
-- object through its IDispatch vtable -- GetIDsOfNames to look up a
-- method/property DISPID, then Invoke to fire it. That avoids redeclaring
-- 200+ COM methods and keeps the cdef block small.
--
-- Public surface:
--   scheduler.create_task(opts)        -- install a task
--   scheduler.delete_task(name)
--   scheduler.list_tasks(folder?)      -> { "name", ... }
--   scheduler.run_now(name)
--   scheduler.get_status(name)         -> "running" | "ready" | "disabled" | ...
--   scheduler.disable(name)
--   scheduler.enable(name)
--
-- create_task opts (table):
--   name             string             task name (required)
--   command          string             executable path (required)
--   args             string             argument string (optional)
--   working_dir      string             cwd for the task (optional)
--   description      string             task description
--   folder           string             "\\\\Foo\\Bar" -- default "\\"
--   schedule = {
--     type           "once"|"daily"|"weekly"|"monthly"|"on_logon"|"on_boot"
--     start_time     "YYYY-MM-DDTHH:MM:SS" (ISO 8601 local time)
--     interval       integer (days for daily, weeks for weekly)
--     days           list ("monday","tuesday",...) for weekly
--                    or list of integers 1..31 for monthly
--   }
--   run_as           "user"|"system"|"interactive"  default "user"
--   run_level        "lowest"|"highest"             default "lowest"
--   enabled          boolean                        default true
--
-- All operations call CoInitialize / CoUninitialize themselves so callers
-- don't have to worry about COM apartments.

local W   = require "windows"
local COM = require "windows.com"

-- ===== minimal IDispatch surface =========================================
--
-- We don't predeclare every interface in the Task Scheduler typelib --
-- there's ~30 of them. Instead, we keep everything as IDispatch* and use
-- GetIDsOfNames + Invoke for property/method access. The cost is a couple
-- of extra COM round-trips per call, which is fine for an admin tool.

ffi.cdef[[
typedef struct sched_IDispatch     sched_IDispatch;
typedef struct sched_IDispatchVtbl sched_IDispatchVtbl;

/* 24-byte VARIANT we use only by-reference / in arrays. */
typedef struct sched_VARIANT {
    unsigned short vt;
    unsigned short wReserved1;
    unsigned short wReserved2;
    unsigned short wReserved3;
    long long      data0;
    long long      data1;
} sched_VARIANT;

typedef struct sched_DISPPARAMS {
    sched_VARIANT *rgvarg;
    long          *rgdispidNamedArgs;
    unsigned int   cArgs;
    unsigned int   cNamedArgs;
} sched_DISPPARAMS;

typedef struct sched_EXCEPINFO {
    unsigned short wCode;
    unsigned short wReserved;
    LPWSTR         bstrSource;
    LPWSTR         bstrDescription;
    LPWSTR         bstrHelpFile;
    DWORD          dwHelpContext;
    void          *pvReserved;
    void          *pfnDeferredFillIn;
    long           scode;
} sched_EXCEPINFO;

struct sched_IDispatchVtbl {
    HRESULT (__stdcall *QueryInterface)(sched_IDispatch *, GUID_W *, void **);
    ULONG   (__stdcall *AddRef)(sched_IDispatch *);
    ULONG   (__stdcall *Release)(sched_IDispatch *);
    HRESULT (__stdcall *GetTypeInfoCount)(sched_IDispatch *, unsigned int *);
    HRESULT (__stdcall *GetTypeInfo)(sched_IDispatch *, unsigned int, DWORD, void **);
    HRESULT (__stdcall *GetIDsOfNames)(sched_IDispatch *, GUID_W *, LPWSTR *,
                                       unsigned int, DWORD, long *);
    HRESULT (__stdcall *Invoke)(sched_IDispatch *, long, GUID_W *, DWORD,
                                unsigned short, sched_DISPPARAMS *,
                                sched_VARIANT *, sched_EXCEPINFO *,
                                unsigned int *);
};
struct sched_IDispatch { sched_IDispatchVtbl *lpVtbl; };

/* VariantInit / VariantClear from oleaut32 */
void  VariantInit(sched_VARIANT *pvarg);
HRESULT VariantClear(sched_VARIANT *pvarg);
]]

local C       = ffi.C
local oleaut  = ffi.load("oleaut32")

-- VARIANT types we actually emit
local VT_EMPTY    = 0
local VT_NULL     = 1
local VT_I2       = 2
local VT_I4       = 3
local VT_BSTR     = 8
local VT_DISPATCH = 9
local VT_BOOL     = 11
local VT_VARIANT  = 12
local VT_I8       = 20

-- IDispatch::Invoke flags
local DISPATCH_METHOD         = 0x1
local DISPATCH_PROPERTYGET    = 0x2
local DISPATCH_PROPERTYPUT    = 0x4
local DISPATCH_PROPERTYPUTREF = 0x8

local LOCALE_USER_DEFAULT = 0x0400
local IID_NULL = ffi.new("GUID_W")  -- zero-initialised

local CLSCTX_INPROC_SERVER = 0x1
local COINIT_APARTMENTTHREADED = 0x2

-- Task Scheduler 2.0 -- CLSID_TaskScheduler / IID_ITaskService
local function make_guid(s)
    local g = ffi.new("GUID_W")
    local d1, d2, d3, d4hi, d4lo = s:match(
        "^(%x%x%x%x%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x+)$")
    if not d1 then error("bad GUID: " .. s) end
    g.Data1 = tonumber(d1, 16)
    g.Data2 = tonumber(d2, 16)
    g.Data3 = tonumber(d3, 16)
    g.Data4[0] = tonumber(d4hi:sub(1, 2), 16)
    g.Data4[1] = tonumber(d4hi:sub(3, 4), 16)
    for i = 0, 5 do
        g.Data4[2 + i] = tonumber(d4lo:sub(i * 2 + 1, i * 2 + 2), 16)
    end
    return g
end

local CLSID_TaskScheduler = make_guid("0F87369F-A4E5-4CFC-BD3E-73E6154572DD")
local IID_ITaskService    = make_guid("2FABA4C7-4DA9-4013-9697-20CC3FD40F85")

-- ===== helpers ===========================================================

local function fail(msg) error("scheduler: " .. msg, 2) end

local function hrcheck(hr, ctx)
    if hr ~= 0 then
        local u = ffi.cast("unsigned long", hr)
        fail(string.format("%s failed (HRESULT 0x%08X)", ctx, tonumber(u)))
    end
end

-- UTF-8 -> BSTR (allocated via SysAllocString -- caller frees).
local function bstr(s)
    if s == nil then return nil end
    local w = W.ToWide(s)
    return C.SysAllocString(w)
end

-- BSTR -> Lua string (no ownership transfer; caller still owns the BSTR).
local function from_bstr(b)
    if b == nil then return nil end
    return W.FromWide(b)
end

local function release(p)
    if p ~= nil and p[0] ~= nil then
        p[0].lpVtbl.Release(p[0])
    end
end

-- ===== VARIANT helpers ===================================================

local function variant_init(v)
    oleaut.VariantInit(v)
end

local function variant_clear(v)
    oleaut.VariantClear(v)
end

-- Pack a Lua value into a sched_VARIANT slot.
-- Returns (slot, owns_bstr) where owns_bstr signals the caller to free the
-- BSTR after the Invoke call returns. (For BSTR args we keep ownership and
-- free explicitly; SysFreeString takes a BSTR not a VARIANT.)
local function pack_variant(v, val)
    variant_init(v)
    local t = type(val)
    if val == nil then
        v.vt = VT_EMPTY
    elseif t == "string" then
        v.vt = VT_BSTR
        local b = bstr(val)
        ffi.cast("LPWSTR *", v + 0)[2] = b  -- data starts at offset 8 (vt+3*WORD)
        return b
    elseif t == "number" then
        if val == math.floor(val) and val >= -2147483648 and val <= 2147483647 then
            v.vt = VT_I4
            ffi.cast("long *", v + 0)[4] = val  -- offset 8 / sizeof(long)=4
        else
            v.vt = VT_I8
            ffi.cast("long long *", v + 0)[1] = val
        end
    elseif t == "boolean" then
        v.vt = VT_BOOL
        ffi.cast("short *", v + 0)[8] = val and -1 or 0
    elseif t == "cdata" then
        -- Assume IDispatch*
        v.vt = VT_DISPATCH
        ffi.cast("void * *", v + 0)[1] = val
    else
        fail("pack_variant: unsupported Lua type " .. t)
    end
    return nil
end

-- Direct field access on sched_VARIANT is fiddly because of LuaJIT's
-- alignment; use byte-offset views instead. Layout:
--   [0..1]  vt        (unsigned short)
--   [2..7]  wReserved1/2/3
--   [8..15] payload
local function v_set_bstr(v, b)
    variant_init(v)
    v.vt = VT_BSTR
    -- Payload at byte offset 8
    local p = ffi.cast("LPWSTR *", ffi.cast("char *", v) + 8)
    p[0] = b
end

local function v_set_i4(v, n)
    variant_init(v)
    v.vt = VT_I4
    local p = ffi.cast("long *", ffi.cast("char *", v) + 8)
    p[0] = n
end

local function v_set_bool(v, b)
    variant_init(v)
    v.vt = VT_BOOL
    local p = ffi.cast("short *", ffi.cast("char *", v) + 8)
    p[0] = b and -1 or 0
end

local function v_set_dispatch(v, d)
    variant_init(v)
    v.vt = VT_DISPATCH
    local p = ffi.cast("void * *", ffi.cast("char *", v) + 8)
    p[0] = d
end

local function v_get_bstr(v)
    if v.vt ~= VT_BSTR then return nil end
    local p = ffi.cast("LPWSTR *", ffi.cast("char *", v) + 8)
    if p[0] == nil then return nil end
    return from_bstr(p[0])
end

local function v_get_dispatch(v)
    if v.vt ~= VT_DISPATCH then return nil end
    local p = ffi.cast("void * *", ffi.cast("char *", v) + 8)
    return p[0]
end

local function v_get_i4(v)
    if v.vt == VT_I4 or v.vt == VT_I2 or v.vt == VT_BOOL then
        local p = ffi.cast("long *", ffi.cast("char *", v) + 8)
        return tonumber(p[0])
    end
    return nil
end

-- ===== IDispatch call wrapper ============================================
--
-- A single helper that resolves a name to a DISPID and Invokes. Args is a
-- Lua list of Lua values (strings, numbers, booleans, IDispatch cdata).
-- IDispatch arguments must be in REVERSE order in DISPPARAMS.rgvarg.

local function disp_invoke(disp, name, flags, args)
    if disp == nil then fail("disp_invoke: nil dispatch") end
    args = args or {}
    local nargs = #args

    -- Look up DISPID for the named method/property.
    local namew = W.ToWide(name)
    local names_arr = ffi.new("LPWSTR[1]")
    names_arr[0] = ffi.cast("LPWSTR", namew)
    local dispid = ffi.new("long[1]")
    local hr = disp[0].lpVtbl.GetIDsOfNames(disp[0], IID_NULL,
        names_arr, 1, LOCALE_USER_DEFAULT, dispid)
    hrcheck(hr, "GetIDsOfNames(" .. name .. ")")

    -- Pack arguments into a VARIANT array in REVERSE order.
    local varg, bstrs
    if nargs > 0 then
        varg  = ffi.new("sched_VARIANT[?]", nargs)
        bstrs = {}
        for i, val in ipairs(args) do
            local slot = varg[nargs - i]  -- reverse
            local t = type(val)
            if val == nil then
                variant_init(slot); slot.vt = VT_EMPTY
            elseif t == "string" then
                v_set_bstr(slot, bstr(val))
                bstrs[#bstrs + 1] = ffi.cast("LPWSTR *",
                    ffi.cast("char *", slot) + 8)[0]
            elseif t == "number" then
                v_set_i4(slot, val)
            elseif t == "boolean" then
                v_set_bool(slot, val)
            elseif t == "cdata" then
                v_set_dispatch(slot, val)
            else
                fail("disp_invoke: unsupported arg type " .. t .. " for " .. name)
            end
        end
    end

    local dp = ffi.new("sched_DISPPARAMS")
    dp.cArgs = nargs
    dp.cNamedArgs = 0
    dp.rgvarg = varg ~= nil and varg or nil
    dp.rgdispidNamedArgs = nil

    -- Property-put requires the named-arg DISPID_PROPERTYPUT = -3
    local named_dispid
    if flags == DISPATCH_PROPERTYPUT or flags == DISPATCH_PROPERTYPUTREF then
        named_dispid = ffi.new("long[1]", -3)
        dp.cNamedArgs = 1
        dp.rgdispidNamedArgs = named_dispid
    end

    local result = ffi.new("sched_VARIANT")
    variant_init(result)
    local excep  = ffi.new("sched_EXCEPINFO")
    local arg_err = ffi.new("unsigned int[1]")

    hr = disp[0].lpVtbl.Invoke(disp[0], dispid[0], IID_NULL,
        LOCALE_USER_DEFAULT, flags, dp, result, excep, arg_err)

    -- Free BSTR arg payloads now (Invoke didn't take ownership)
    if bstrs then
        for _, b in ipairs(bstrs) do
            if b ~= nil then C.SysFreeString(b) end
        end
    end

    if hr ~= 0 then
        local detail = ""
        if excep.bstrDescription ~= nil then
            detail = " :: " .. from_bstr(excep.bstrDescription)
            C.SysFreeString(excep.bstrDescription)
            if excep.bstrSource ~= nil then C.SysFreeString(excep.bstrSource) end
            if excep.bstrHelpFile ~= nil then C.SysFreeString(excep.bstrHelpFile) end
        end
        local u = ffi.cast("unsigned long", hr)
        fail(string.format("Invoke(%s) failed (HRESULT 0x%08X)%s",
            name, tonumber(u), detail))
    end

    return result
end

-- Convenience wrappers around disp_invoke for common patterns.

local function call_method(disp, name, ...)
    local args = { ... }
    local r = disp_invoke(disp, name, DISPATCH_METHOD, args)
    return r
end

local function get_prop(disp, name, ...)
    local args = { ... }
    -- PROPERTYGET + METHOD per the spec (some objects expose properties as
    -- methods or vice versa; OR-ing both is what oleaut32 internally does).
    local flags = DISPATCH_PROPERTYGET + DISPATCH_METHOD
    local r = disp_invoke(disp, name, flags, args)
    return r
end

local function set_prop(disp, name, value)
    return disp_invoke(disp, name, DISPATCH_PROPERTYPUT, { value })
end

-- Take ownership of an IDispatch* returned in a VARIANT.
-- Returns a typed IDispatch** suitable for further calls.
local function dispatch_of(v)
    local raw = v_get_dispatch(v)
    if raw == nil then return nil end
    -- Don't AddRef; the VARIANT result already added ref. We do null out
    -- the variant's slot so VariantClear doesn't Release it later.
    local p = ffi.new("sched_IDispatch *[1]")
    p[0] = ffi.cast("sched_IDispatch *", raw)
    -- Clear the source variant's vt so VariantClear is a no-op
    v.vt = VT_EMPTY
    return p
end

-- ===== COM apartment management ==========================================

local function co_init()
    -- S_OK=0, S_FALSE=1 (already inited on this thread). Anything else is fatal.
    local hr = C.CoInitializeEx(nil, COINIT_APARTMENTTHREADED)
    if hr ~= 0 and hr ~= 1 then
        hrcheck(hr, "CoInitializeEx")
    end
end

local function co_uninit() C.CoUninitialize() end

-- ===== ITaskService connect ==============================================

local function connect_service()
    co_init()
    local p = ffi.new("sched_IDispatch *[1]")
    local hr = C.CoCreateInstance(CLSID_TaskScheduler, nil,
        CLSCTX_INPROC_SERVER, IID_ITaskService, ffi.cast("void **", p))
    hrcheck(hr, "CoCreateInstance(TaskScheduler)")
    -- ITaskService::Connect(serverName, user, domain, password) -- all empty
    -- means "connect to the local machine as the current user".
    call_method(p, "Connect")
    return p
end

local function get_folder(svc, path)
    path = path or "\\"
    local r = call_method(svc, "GetFolder", path)
    return dispatch_of(r)
end

-- ===== high-level operations =============================================

local DAY_MASKS = {
    sunday = 0x01, monday = 0x02, tuesday = 0x04, wednesday = 0x08,
    thursday = 0x10, friday = 0x20, saturday = 0x40,
}

local LOGON_TYPE_INTERACTIVE = 3
local LOGON_TYPE_S4U         = 2   -- run-as user, no password
local LOGON_TYPE_PASSWORD    = 1
local LOGON_TYPE_SERVICE     = 5   -- TASK_LOGON_SERVICE_ACCOUNT

local RUN_LEVEL_LOWEST  = 0
local RUN_LEVEL_HIGHEST = 1

-- TASK_CREATE_OR_UPDATE = 6
local TASK_CREATE_OR_UPDATE = 6

local TRIGGER_TYPE = {
    once    = 1,    -- TASK_TRIGGER_TIME
    daily   = 2,    -- TASK_TRIGGER_DAILY
    weekly  = 3,    -- TASK_TRIGGER_WEEKLY
    monthly = 4,    -- TASK_TRIGGER_MONTHLY
    on_logon= 9,    -- TASK_TRIGGER_LOGON
    on_boot = 8,    -- TASK_TRIGGER_BOOT
}

local STATE_NAMES = {
    [0] = "unknown",
    [1] = "disabled",
    [2] = "queued",
    [3] = "ready",
    [4] = "running",
}

-- Add a trigger of the requested type to the trigger collection.
local function add_trigger(triggers_disp, schedule)
    local ttype = TRIGGER_TYPE[schedule.type]
    if not ttype then
        fail("unknown schedule type: " .. tostring(schedule.type))
    end
    local tr = dispatch_of(call_method(triggers_disp, "Create", ttype))
    if schedule.start_time then
        set_prop(tr, "StartBoundary", schedule.start_time)
    end
    if schedule.type == "daily" then
        set_prop(tr, "DaysInterval", schedule.interval or 1)
    elseif schedule.type == "weekly" then
        set_prop(tr, "WeeksInterval", schedule.interval or 1)
        local mask = 0
        for _, d in ipairs(schedule.days or {}) do
            local m = DAY_MASKS[d:lower()]
            if not m then fail("bad weekday: " .. tostring(d)) end
            mask = mask + m
        end
        if mask == 0 then mask = DAY_MASKS.monday end
        set_prop(tr, "DaysOfWeek", mask)
    elseif schedule.type == "monthly" then
        local day_mask = 0
        for _, d in ipairs(schedule.days or { 1 }) do
            day_mask = day_mask + bit.lshift(1, (d - 1))
        end
        set_prop(tr, "DaysOfMonth", day_mask)
        -- Months of year: all months unless overridden later.
        set_prop(tr, "MonthsOfYear", 0x0FFF)
    end
    set_prop(tr, "Enabled", true)
    release(tr)
end

local function set_principal(principal, opts)
    local run_as = opts.run_as or "user"
    local run_level = opts.run_level or "lowest"
    if run_as == "system" then
        set_prop(principal, "LogonType", LOGON_TYPE_SERVICE)
        set_prop(principal, "UserId", "S-1-5-18")  -- LocalSystem SID
    elseif run_as == "interactive" then
        set_prop(principal, "LogonType", LOGON_TYPE_INTERACTIVE)
    else
        -- "user" -- run as the calling user, no password (S4U). Works on
        -- 7+/Server 2008 R2+, which is everything CLua targets.
        set_prop(principal, "LogonType", LOGON_TYPE_S4U)
    end
    if run_level == "highest" then
        set_prop(principal, "RunLevel", RUN_LEVEL_HIGHEST)
    else
        set_prop(principal, "RunLevel", RUN_LEVEL_LOWEST)
    end
end

local M = {}

function M.create_task(opts)
    assert(opts and opts.name, "scheduler.create_task: opts.name required")
    assert(opts.command, "scheduler.create_task: opts.command required")
    local schedule = opts.schedule or { type = "on_logon" }

    local svc = connect_service()
    local ok, err = pcall(function()
        -- Build the task definition.
        local def = dispatch_of(call_method(svc, "NewTask", 0))

        -- RegistrationInfo
        local reg = dispatch_of(get_prop(def, "RegistrationInfo"))
        if opts.description then set_prop(reg, "Description", opts.description) end
        set_prop(reg, "Author", opts.author or "CLua")
        release(reg)

        -- Principal
        local principal = dispatch_of(get_prop(def, "Principal"))
        set_principal(principal, opts)
        release(principal)

        -- Settings
        local settings = dispatch_of(get_prop(def, "Settings"))
        set_prop(settings, "Enabled", opts.enabled ~= false)
        set_prop(settings, "StartWhenAvailable", true)
        set_prop(settings, "AllowDemandStart", true)
        set_prop(settings, "DisallowStartIfOnBatteries", false)
        set_prop(settings, "StopIfGoingOnBatteries", false)
        release(settings)

        -- Triggers (collection)
        local triggers = dispatch_of(get_prop(def, "Triggers"))
        add_trigger(triggers, schedule)
        release(triggers)

        -- Actions (collection); we always add a single Exec action.
        local actions = dispatch_of(get_prop(def, "Actions"))
        local action  = dispatch_of(call_method(actions, "Create", 0))  -- TASK_ACTION_EXEC
        set_prop(action, "Path", opts.command)
        if opts.args then set_prop(action, "Arguments", opts.args) end
        if opts.working_dir then set_prop(action, "WorkingDirectory", opts.working_dir) end
        release(action)
        release(actions)

        -- Register via the folder.
        local folder = get_folder(svc, opts.folder or "\\")
        -- RegisterTaskDefinition(path, def, flags, userId, password, logonType, sddl)
        -- flags = TASK_CREATE_OR_UPDATE (6)
        local logon = LOGON_TYPE_S4U
        if (opts.run_as == "system") then logon = LOGON_TYPE_SERVICE
        elseif (opts.run_as == "interactive") then logon = LOGON_TYPE_INTERACTIVE end
        local r = call_method(folder, "RegisterTaskDefinition",
            opts.name, def, TASK_CREATE_OR_UPDATE, nil, nil, logon, nil)
        variant_clear(r)
        release(folder)
        release(def)
    end)
    release(svc)
    co_uninit()
    if not ok then return nil, err end
    return true
end

function M.delete_task(name, folder_path)
    local svc = connect_service()
    local ok, err = pcall(function()
        local folder = get_folder(svc, folder_path or "\\")
        call_method(folder, "DeleteTask", name, 0)
        release(folder)
    end)
    release(svc)
    co_uninit()
    if not ok then return nil, err end
    return true
end

function M.list_tasks(folder_path)
    local svc = connect_service()
    local out = {}
    local ok, err = pcall(function()
        local folder = get_folder(svc, folder_path or "\\")
        -- GetTasks(flags) -- flags=0 means hidden tasks too on some
        -- versions; we want a complete list, so pass 1 (TASK_ENUM_HIDDEN).
        local tasks = dispatch_of(call_method(folder, "GetTasks", 1))
        local count_v = get_prop(tasks, "Count")
        local count = v_get_i4(count_v) or 0
        for i = 1, count do
            local item = dispatch_of(get_prop(tasks, "Item", i))
            local name_v = get_prop(item, "Name")
            out[#out + 1] = v_get_bstr(name_v) or "?"
            variant_clear(name_v)
            release(item)
        end
        release(tasks)
        release(folder)
    end)
    release(svc)
    co_uninit()
    if not ok then return nil, err end
    return out
end

local function get_task(svc, name, folder_path)
    local folder = get_folder(svc, folder_path or "\\")
    local task = dispatch_of(call_method(folder, "GetTask", name))
    release(folder)
    return task
end

function M.run_now(name, folder_path)
    local svc = connect_service()
    local ok, err = pcall(function()
        local task = get_task(svc, name, folder_path)
        -- Run(params) -- empty VARIANT means no parameters.
        local r = call_method(task, "Run", nil)
        variant_clear(r)
        release(task)
    end)
    release(svc)
    co_uninit()
    if not ok then return nil, err end
    return true
end

function M.get_status(name, folder_path)
    local svc = connect_service()
    local result
    local ok, err = pcall(function()
        local task = get_task(svc, name, folder_path)
        local state_v = get_prop(task, "State")
        result = STATE_NAMES[v_get_i4(state_v) or 0] or "unknown"
        release(task)
    end)
    release(svc)
    co_uninit()
    if not ok then return nil, err end
    return result
end

local function set_enabled(name, on, folder_path)
    local svc = connect_service()
    local ok, err = pcall(function()
        local task = get_task(svc, name, folder_path)
        set_prop(task, "Enabled", on)
        release(task)
    end)
    release(svc)
    co_uninit()
    if not ok then return nil, err end
    return true
end

function M.disable(name, folder_path) return set_enabled(name, false, folder_path) end
function M.enable(name, folder_path)  return set_enabled(name, true,  folder_path) end

-- Convenience: ISO-8601 timestamp builder for opts.schedule.start_time.
function M.iso_time(year, month, day, hour, min, sec)
    return string.format("%04d-%02d-%02dT%02d:%02d:%02d",
        year, month, day, hour or 0, min or 0, sec or 0)
end

-- Convenience: "in N seconds from now" as an ISO timestamp.
function M.in_seconds(n)
    local t = os.date("*t", os.time() + n)
    return M.iso_time(t.year, t.month, t.day, t.hour, t.min, t.sec)
end

return M
