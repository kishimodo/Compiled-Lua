-- signal -- SetConsoleCtrlHandler wrapper.
--
-- Windows console control events surface as Ctrl-C, Ctrl-Break, console
-- close, user logoff, and system shutdown. We register a single C-callable
-- thunk with the kernel; that thunk dispatches into a Lua-side handler
-- table keyed by event name.
--
-- A Lua handler that returns true tells the kernel the event was handled
-- (suppresses default behavior -- e.g. for Ctrl-C, the default is to
-- terminate the process). Returning false / nil falls through to the
-- next handler / the default.
--
-- Public surface:
--   signal.on(name, fn)     -- install a handler (replaces any previous)
--   signal.default(name)    -- restore default behavior for that signal
--   signal.raise(name)      -- generate the event in this process group
--                              (only "int" and "break" actually work --
--                               GenerateConsoleCtrlEvent limitation)
--   signal.SIGNALS          -- table of valid names

local W = require "windows"

ffi.cdef[[
typedef BOOL (__stdcall *PHANDLER_ROUTINE)(DWORD CtrlType);
BOOL SetConsoleCtrlHandler(PHANDLER_ROUTINE HandlerRoutine, BOOL Add);
BOOL GenerateConsoleCtrlEvent(DWORD dwCtrlEvent, DWORD dwProcessGroupId);
]]

local C = ffi.C

-- Windows CTRL_* event codes (see console.lua). We re-declare locally
-- so this package compiles without windows.console.
local CTRL_C_EVENT        = 0
local CTRL_BREAK_EVENT    = 1
local CTRL_CLOSE_EVENT    = 2
local CTRL_LOGOFF_EVENT   = 5
local CTRL_SHUTDOWN_EVENT = 6

local NAME_TO_CODE = {
    int      = CTRL_C_EVENT,
    ["break"] = CTRL_BREAK_EVENT,
    close    = CTRL_CLOSE_EVENT,
    logoff   = CTRL_LOGOFF_EVENT,
    shutdown = CTRL_SHUTDOWN_EVENT,
}

local CODE_TO_NAME = {}
for k, v in pairs(NAME_TO_CODE) do CODE_TO_NAME[v] = k end

local M = {}

M.SIGNALS = {}
for k in pairs(NAME_TO_CODE) do M.SIGNALS[#M.SIGNALS + 1] = k end
table.sort(M.SIGNALS)

-- ===== handler dispatch =================================================

-- Lua handlers keyed by event code; nil = no handler.
local g_handlers = {}

-- Cached cdata for the single C thunk we register with the kernel. We
-- must keep this around for the lifetime of the process; if the FFI
-- callback object is GC'd while the kernel still has the function
-- pointer, Ctrl-C will jump into freed memory.
local g_thunk = nil
local g_installed = false

local function dispatch(ctrl_type)
    local code = tonumber(ctrl_type)
    local h = g_handlers[code]
    if not h then return 0 end  -- not handled -> default behavior
    local name = CODE_TO_NAME[code] or "unknown"
    local ok, ret = pcall(h, name)
    if not ok then
        -- A throwing handler shouldn't crash the kernel callback; print
        -- and treat as unhandled so the OS does its default thing.
        io.stderr:write("[signal] handler for " .. name .. " errored: " .. tostring(ret) .. "\n")
        return 0
    end
    if ret == true then return 1 end
    return 0
end

local function install_thunk()
    if g_installed then return end
    g_thunk = ffi.cast("PHANDLER_ROUTINE", dispatch)
    if C.SetConsoleCtrlHandler(g_thunk, 1) == 0 then
        local e = tonumber(C.GetLastError())
        g_thunk:free()
        g_thunk = nil
        error("SetConsoleCtrlHandler failed: " .. e)
    end
    g_installed = true
end

-- ===== public API =======================================================

function M.on(name, fn)
    local code = NAME_TO_CODE[name]
    if code == nil then
        error("signal.on: unknown signal '" .. tostring(name) .. "'")
    end
    if type(fn) ~= "function" then
        error("signal.on: handler must be a function")
    end
    g_handlers[code] = fn
    install_thunk()
end

function M.default(name)
    local code = NAME_TO_CODE[name]
    if code == nil then
        error("signal.default: unknown signal '" .. tostring(name) .. "'")
    end
    g_handlers[code] = nil
    -- We keep the thunk installed even if no handlers remain -- removing
    -- it would mean re-installing if the user calls on() again, and the
    -- dispatch path returns 0 for missing handlers anyway, which is
    -- exactly the default-behavior signal.
end

function M.raise(name)
    local code = NAME_TO_CODE[name]
    if code == nil then
        error("signal.raise: unknown signal '" .. tostring(name) .. "'")
    end
    -- GenerateConsoleCtrlEvent only accepts CTRL_C and CTRL_BREAK.
    if code ~= CTRL_C_EVENT and code ~= CTRL_BREAK_EVENT then
        return nil, "signal.raise: only 'int' and 'break' can be raised programmatically"
    end
    -- 0 = current console process group
    if C.GenerateConsoleCtrlEvent(code, 0) == 0 then
        return nil, "GenerateConsoleCtrlEvent failed: " .. tonumber(C.GetLastError())
    end
    return true
end

-- ===== convenience block-and-wait pattern ==============================
--
-- signal.wait_for("int") blocks the calling thread until that signal
-- fires. Useful for "service-style" scripts that want to run until
-- Ctrl-C is pressed. The implementation is a busy-poll on a flag set
-- from the handler -- there is no win32 primitive that pairs the
-- console-ctrl callback with a waitable handle without writing C, so
-- a 50ms sleep keeps idle CPU near zero while remaining responsive.

function M.wait_for(name, opts)
    opts = opts or {}
    local poll_ms = opts.poll_ms or 50
    local fired = false
    local prev = g_handlers[NAME_TO_CODE[name]]
    M.on(name, function()
        fired = true
        if prev then return prev(name) end
        return true
    end)
    while not fired do
        ffi.C.Sleep(poll_ms)
    end
    -- restore previous handler (may be nil)
    g_handlers[NAME_TO_CODE[name]] = prev
end

return M
