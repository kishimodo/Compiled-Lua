-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- daemon -- Windows service install + run helpers over windows.services.
--
-- Two use cases, both wrapped here:
--   1. From an admin script: install / uninstall / start / stop / query a
--      service. The service binary lives elsewhere (or is the current
--      script's executable, passed in opts.executable_path).
--   2. From inside the service binary itself: run_as_service(handler)
--      registers with the SCM, calls handler(), and reports status
--      transitions back to the SCM as the user code runs.
--
-- Public surface:
--   daemon.install(opts)        -- create the service entry
--   daemon.uninstall(name)
--   daemon.start(name)
--   daemon.stop(name)
--   daemon.status(name)         -> "running" | "stopped" | "start_pending" | ...
--   daemon.run_as_service(handler, opts?)
--     handler is called once after SCM hand-off. It receives a context
--     table with .stop_event (HANDLE) and :should_stop() (bool). The
--     handler must loop until should_stop() returns true.

local W   = require "windows"
local svc = require "windows.services"

-- Full SCM surface (Create/Open/StartServiceW, RegisterServiceCtrlHandlerExW,
-- StartServiceCtrlDispatcherW, ...) is declared in windows.services. We only
-- need a callback typedef pair for ffi.cast targets and a description struct
-- the winmd-gen output doesn't expose by name.
ffi.cdef[[
typedef DWORD (__stdcall *daemon_handler_ex_t)(DWORD, DWORD, void *, void *);
typedef void  (__stdcall *daemon_service_main_t)(DWORD, LPWSTR *);

typedef struct _daemon_SERVICE_DESCRIPTIONW {
    LPWSTR lpDescription;
} daemon_SERVICE_DESCRIPTIONW;
]]

local C = ffi.C
local M = {}

-- ===== constants -- mostly mirror svc but in friendlier names ==========

local SC_MANAGER_ALL_ACCESS  = 0x000F003F
local SERVICE_ALL_ACCESS     = 0x000F01FF
local SERVICE_WIN32_OWN_PROCESS = 0x00000010
local SERVICE_INTERACTIVE_PROCESS = 0x00000100

local SERVICE_AUTO_START   = 0x00000002
local SERVICE_DEMAND_START = 0x00000003
local SERVICE_DISABLED     = 0x00000004

local SERVICE_ERROR_NORMAL = 0x00000001

local SERVICE_CONTROL_STOP        = 0x00000001
local SERVICE_CONTROL_INTERROGATE = 0x00000004
local SERVICE_CONTROL_SHUTDOWN    = 0x00000005

local SERVICE_STOPPED          = 0x00000001
local SERVICE_START_PENDING    = 0x00000002
local SERVICE_STOP_PENDING     = 0x00000003
local SERVICE_RUNNING          = 0x00000004
local SERVICE_CONTINUE_PENDING = 0x00000005
local SERVICE_PAUSE_PENDING    = 0x00000006
local SERVICE_PAUSED           = 0x00000007

local SERVICE_ACCEPT_STOP     = 0x00000001
local SERVICE_ACCEPT_SHUTDOWN = 0x00000004

local SERVICE_CONFIG_DESCRIPTION = 1

local WAIT_OBJECT_0 = 0

local STATE_NAMES = {
    [SERVICE_STOPPED]          = "stopped",
    [SERVICE_START_PENDING]    = "start_pending",
    [SERVICE_STOP_PENDING]     = "stop_pending",
    [SERVICE_RUNNING]          = "running",
    [SERVICE_CONTINUE_PENDING] = "continue_pending",
    [SERVICE_PAUSE_PENDING]    = "pause_pending",
    [SERVICE_PAUSED]           = "paused",
}

local START_TYPE_FROM_NAME = {
    auto     = SERVICE_AUTO_START,
    manual   = SERVICE_DEMAND_START,
    disabled = SERVICE_DISABLED,
}

-- ===== install / uninstall ==============================================

local function open_scm(access)
    local h = C.OpenSCManagerW(nil, nil, access)
    if h == nil then
        return nil, "OpenSCManagerW failed: " .. tonumber(C.GetLastError())
            .. " (need administrator?)"
    end
    return h
end

-- Build a double-null-terminated UTF-16 block for the dependencies arg.
-- nil and {} both yield nil so CreateService uses no dependencies.
local function build_deps(deps)
    if not deps or #deps == 0 then return nil end
    local pieces = {}
    for i, d in ipairs(deps) do pieces[i] = d end
    -- Each name terminated by null; whole block ends with extra null.
    local s = table.concat(pieces, "\0") .. "\0\0"
    return W.ToWide(s)
end

function M.install(opts)
    assert(opts.name, "daemon.install: opts.name required")
    assert(opts.executable_path, "daemon.install: opts.executable_path required")
    local scm, err = open_scm(SC_MANAGER_ALL_ACCESS)
    if not scm then return nil, err end

    local start_type = SERVICE_DEMAND_START
    if opts.start_type then
        local t = START_TYPE_FROM_NAME[opts.start_type]
        if t == nil then
            C.CloseServiceHandle(scm)
            return nil, "invalid start_type: " .. tostring(opts.start_type)
        end
        start_type = t
    end

    -- Concatenate executable path + args (if any) into the binary path
    -- field. SCM hands the whole thing to CreateProcess; argv parsing
    -- happens on the receiver side.
    local bin = opts.executable_path
    if opts.args and #opts.args > 0 then
        local quoted = { '"' .. bin .. '"' }
        for i, a in ipairs(opts.args) do
            quoted[i + 1] = '"' .. a .. '"'
        end
        bin = table.concat(quoted, " ")
    end

    local h = C.CreateServiceW(
        scm,
        W.ToWide(opts.name),
        W.ToWide(opts.display_name or opts.name),
        SERVICE_ALL_ACCESS,
        SERVICE_WIN32_OWN_PROCESS,
        start_type,
        SERVICE_ERROR_NORMAL,
        W.ToWide(bin),
        nil,                           -- lpLoadOrderGroup
        nil,                           -- lpdwTagId
        build_deps(opts.dependencies),
        opts.account and W.ToWide(opts.account) or nil,
        opts.password and W.ToWide(opts.password) or nil)

    if h == nil then
        local e = tonumber(C.GetLastError())
        C.CloseServiceHandle(scm)
        return nil, "CreateServiceW failed: " .. e
    end

    -- Description -- optional, set via ChangeServiceConfig2W
    if opts.description then
        local desc = ffi.new("daemon_SERVICE_DESCRIPTIONW")
        desc.lpDescription = ffi.cast("LPWSTR", W.ToWide(opts.description))
        C.ChangeServiceConfig2W(h, SERVICE_CONFIG_DESCRIPTION, desc)
    end

    C.CloseServiceHandle(h)
    C.CloseServiceHandle(scm)
    return true
end

function M.uninstall(name)
    local scm, err = open_scm(SC_MANAGER_ALL_ACCESS)
    if not scm then return nil, err end
    local h = C.OpenServiceW(scm, W.ToWide(name), SERVICE_ALL_ACCESS)
    if h == nil then
        local e = tonumber(C.GetLastError())
        C.CloseServiceHandle(scm)
        return nil, "OpenServiceW failed: " .. e
    end
    local ok = C.DeleteService(h) ~= 0
    local e = ok and 0 or tonumber(C.GetLastError())
    C.CloseServiceHandle(h)
    C.CloseServiceHandle(scm)
    if not ok then return nil, "DeleteService failed: " .. e end
    return true
end

-- ===== start / stop / status ============================================

local function open_service(name, access)
    local scm, err = open_scm(SC_MANAGER_ALL_ACCESS)
    if not scm then return nil, nil, err end
    local h = C.OpenServiceW(scm, W.ToWide(name), access)
    if h == nil then
        local e = tonumber(C.GetLastError())
        C.CloseServiceHandle(scm)
        return nil, nil, "OpenServiceW failed: " .. e
    end
    return h, scm
end

function M.start(name)
    local h, scm, err = open_service(name, SERVICE_ALL_ACCESS)
    if not h then return nil, err end
    local ok = C.StartServiceW(h, 0, nil) ~= 0
    local e = ok and 0 or tonumber(C.GetLastError())
    C.CloseServiceHandle(h); C.CloseServiceHandle(scm)
    -- 1056 = ERROR_SERVICE_ALREADY_RUNNING -- treat as success
    if not ok and e ~= 1056 then
        return nil, "StartServiceW failed: " .. e
    end
    return true
end

function M.stop(name)
    local h, scm, err = open_service(name, SERVICE_ALL_ACCESS)
    if not h then return nil, err end
    local status = ffi.new("SERVICE_STATUS")
    local ok = C.ControlService(h, SERVICE_CONTROL_STOP, status) ~= 0
    local e = ok and 0 or tonumber(C.GetLastError())
    C.CloseServiceHandle(h); C.CloseServiceHandle(scm)
    -- 1062 = ERROR_SERVICE_NOT_ACTIVE -- already stopped
    if not ok and e ~= 1062 then
        return nil, "ControlService failed: " .. e
    end
    return true
end

function M.status(name)
    local h, scm, err = open_service(name, 0x00000004 --[[ SERVICE_QUERY_STATUS ]])
    if not h then return nil, err end
    local status = ffi.new("SERVICE_STATUS")
    local ok = C.QueryServiceStatus(h, status) ~= 0
    local e = ok and 0 or tonumber(C.GetLastError())
    C.CloseServiceHandle(h); C.CloseServiceHandle(scm)
    if not ok then return nil, "QueryServiceStatus failed: " .. e end
    return STATE_NAMES[tonumber(status.dwCurrentState)] or "unknown"
end

-- ===== run_as_service ====================================================
--
-- The service-binary path. Win32 expects:
--   1. main() calls StartServiceCtrlDispatcherW with a table of
--      { service_name, ServiceMain_callback }.
--   2. SCM forks our ServiceMain on its own thread.
--   3. ServiceMain calls RegisterServiceCtrlHandlerExW, transitions
--      status to RUNNING, then runs the user payload.
--   4. When the SCM signals stop (or shutdown), the registered handler
--      sets a stop event; user payload notices and unwinds; ServiceMain
--      transitions to STOPPED.
--
-- The whole thing is callback-driven and has to live across coroutine
-- yields and FFI boundary crossings; we keep all shared state in the
-- module-scope `g_run` table so the C callbacks can find it again.

local g_run = nil   -- populated for the lifetime of one run_as_service call

local function set_status(state, accept_mask)
    if not g_run or g_run.status_handle == nil then return end
    local s = ffi.new("SERVICE_STATUS")
    s.dwServiceType   = SERVICE_WIN32_OWN_PROCESS
    s.dwCurrentState  = state
    s.dwControlsAccepted = accept_mask or 0
    s.dwWin32ExitCode = 0
    s.dwServiceSpecificExitCode = 0
    s.dwCheckPoint    = 0
    s.dwWaitHint      = 0
    C.SetServiceStatus(g_run.status_handle, s)
end

local function handler_ex(control, _, _, _)
    if not g_run then return 0 end
    local c = tonumber(control)
    if c == SERVICE_CONTROL_STOP or c == SERVICE_CONTROL_SHUTDOWN then
        set_status(SERVICE_STOP_PENDING, 0)
        g_run.should_stop = true
        if g_run.stop_event ~= nil then
            ffi.C.SetEvent(g_run.stop_event)
        end
    end
    return 0
end

local function service_main(argc, argv)
    if not g_run then return end
    g_run.status_handle = C.RegisterServiceCtrlHandlerExW(
        W.ToWide(g_run.name),
        g_run.handler_thunk,
        nil)
    if g_run.status_handle == nil then return end
    set_status(SERVICE_START_PENDING, 0)
    -- stop event: auto-reset, initially nonsignaled
    g_run.stop_event = ffi.C.CreateEventW(nil, 0, 0, nil)
    set_status(SERVICE_RUNNING,
        bit.bor(SERVICE_ACCEPT_STOP, SERVICE_ACCEPT_SHUTDOWN))

    local ctx = {
        stop_event   = g_run.stop_event,
        should_stop  = function() return g_run.should_stop end,
        wait_stop    = function(timeout_ms)
            -- helper: block until stop is requested or timeout elapses;
            -- returns true if stop was requested.
            local r = tonumber(ffi.C.WaitForSingleObject(
                g_run.stop_event, timeout_ms or 0xFFFFFFFF))
            return r == WAIT_OBJECT_0
        end,
    }

    local ok, err = pcall(g_run.user_handler, ctx)
    if not ok then
        io.stderr:write("[daemon] handler errored: " .. tostring(err) .. "\n")
    end

    set_status(SERVICE_STOPPED, 0)
end

function M.run_as_service(handler, opts)
    opts = opts or {}
    assert(type(handler) == "function", "daemon.run_as_service: handler required")
    local name = opts.name or "luavm_service"

    -- Cast Lua closures to C-compatible function pointers ONCE per process;
    -- the SCM keeps the pointer for the duration of the run. We stash them
    -- on g_run so they don't get GC'd mid-call.
    g_run = {
        name           = name,
        user_handler   = handler,
        should_stop    = false,
        status_handle  = nil,
        stop_event     = nil,
    }
    g_run.handler_thunk = ffi.cast("daemon_handler_ex_t", handler_ex)
    g_run.main_thunk    = ffi.cast("daemon_service_main_t", service_main)

    -- StartServiceCtrlDispatcherW gets a single-entry table terminated by
    -- a nulled-out entry. The string buffer for the service name must
    -- outlive the call -- it does, via name_wide closing over this scope.
    local name_wide = W.ToWide(name)
    local entries = ffi.new("SERVICE_TABLE_ENTRYW[2]")
    entries[0].lpServiceName = ffi.cast("LPWSTR", name_wide)
    entries[0].lpServiceProc = ffi.cast("LPSERVICE_MAIN_FUNCTIONW", g_run.main_thunk)
    entries[1].lpServiceName = nil
    entries[1].lpServiceProc = nil

    local ok = C.StartServiceCtrlDispatcherW(entries) ~= 0
    if not ok then
        local e = tonumber(C.GetLastError())
        g_run = nil
        return nil, "StartServiceCtrlDispatcherW failed: " .. e
    end

    -- Tear down the persistent thunks now that the dispatcher returned.
    if g_run then
        if g_run.handler_thunk then g_run.handler_thunk:free() end
        if g_run.main_thunk    then g_run.main_thunk:free() end
        g_run = nil
    end
    return true
end

return M
