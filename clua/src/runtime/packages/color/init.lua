-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- color -- ANSI styling with Windows VT-processing enable and NO_COLOR support.
--
-- Public surface:
--   color.enable()                 -- flip VT processing on the current console
--   color.supports_color()         -- bool: any color support detected
--   color.supports_truecolor()     -- bool: 24-bit color detected
--   color.strip(s)                 -- remove ANSI CSI sequences
--   color.red(s), color.green(s), ...   -- 16-color foreground
--   color.bg.red(s), ...                 -- 16-color background
--   color.rgb(r, g, b)(s)                -- truecolor closure
--   color.rgb_bg(r, g, b)(s)             -- truecolor background closure
--   color.color256(n)(s)                 -- 256-color closure
--   color.bold(s), italic, underline, dim, inverse, strike, blink, reverse
--   color.reset                          -- the ANSI reset sequence string
--
-- All wrap-style helpers nest: color.red(color.bold("oops")) works because each
-- function only emits the codes it owns and appends \27[0m at the end. The
-- inner reset gets restored to outer codes by tacking the outer code back on
-- after the inner reset.

local M = {}

-- ESC = \27 -- avoid the literal byte in source so editors don't get confused.
local ESC = string.char(27)
local CSI = ESC .. "["
M.reset = CSI .. "0m"

-- ===== Capability detection ===========================================

local function getenv(name)
    -- os.getenv is the portable hook; LuaVM exposes it like stock Lua.
    return os.getenv and os.getenv(name) or nil
end

local _enabled = nil  -- nil = not probed yet, true/false = cached probe result

local function isatty_stdout()
    -- Best-effort: io.stdout:seek("cur") fails on pipes/redirects, succeeds on
    -- a real console. LuaJIT-style fallback when seek isn't available.
    local f = io.stdout
    if not f then return false end
    local ok, _ = pcall(function() return f:seek("cur") end)
    -- Inverted: seek SUCCEEDS on files (redirected), so success means NOT a tty.
    -- That heuristic is wrong on Windows where consoles do refuse seek; but
    -- we accept the ambiguity and lean on the VT enable as authoritative.
    return not ok
end

function M.supports_color()
    if getenv("NO_COLOR") then return false end
    if getenv("FORCE_COLOR") then return true end
    local term = getenv("TERM")
    if term == "dumb" then return false end
    -- On Windows, modern terminals (Win10+) honor VT once enabled. We treat
    -- successful enable as the source of truth; pre-enable we optimistically
    -- assume yes so callers don't have to order their setup precisely.
    if _enabled == false then return false end
    return true
end

function M.supports_truecolor()
    if not M.supports_color() then return false end
    local ct = getenv("COLORTERM")
    if ct == "truecolor" or ct == "24bit" then return true end
    -- Windows Terminal, ConEmu, ConHost (Win10+) all support truecolor once
    -- VT is enabled. We can't probe reliably; assume yes if VT is on.
    if _enabled == true then return true end
    return false
end

-- ===== VT enable ======================================================

-- Caches resolved FFI handles to avoid re-querying GetStdHandle every call.
local _stdout_handle, _stdin_handle, _stderr_handle

local function resolve_handles()
    if _stdout_handle then return end
    -- Pull from the windows package -- the require is deferred so a host that
    -- doesn't have FFI/windows can still load this module for the stripping
    -- helpers (color.strip etc. work without any system bits).
    local ok, W = pcall(require, "windows")
    if not ok then return end
    local STD_OUTPUT = ffi.cast("HANDLE", ffi.cast("intptr_t", -11))  -- (DWORD)-11
    local STD_INPUT  = ffi.cast("HANDLE", ffi.cast("intptr_t", -10))
    local STD_ERROR  = ffi.cast("HANDLE", ffi.cast("intptr_t", -12))
    _stdout_handle = ffi.C.GetStdHandle(W.STD_OUTPUT_HANDLE)
    _stdin_handle  = ffi.C.GetStdHandle(W.STD_INPUT_HANDLE)
    _stderr_handle = ffi.C.GetStdHandle(W.STD_ERROR_HANDLE)
end

function M.enable()
    if _enabled == true then return true end
    -- Try the FFI path; if FFI isn't available we just trust that the host
    -- terminal already speaks VT (modern Linux/macOS pipes, Windows Terminal
    -- launching directly into a Lua harness, etc.).
    local ok = pcall(function()
        resolve_handles()
        if not _stdout_handle then return end
        local W = require "windows"
        require "windows.console"
        local mode = ffi.new("unsigned long[1]")
        if ffi.C.GetConsoleMode(_stdout_handle, ffi.cast("CONSOLE_MODE*", mode)) ~= 0 then
            local want = bit.bor(mode[0],
                W.ENABLE_VIRTUAL_TERMINAL_PROCESSING,
                W.ENABLE_PROCESSED_OUTPUT)
            ffi.C.SetConsoleMode(_stdout_handle, want)
        end
        if ffi.C.GetConsoleMode(_stderr_handle, ffi.cast("CONSOLE_MODE*", mode)) ~= 0 then
            local want = bit.bor(mode[0],
                W.ENABLE_VIRTUAL_TERMINAL_PROCESSING)
            ffi.C.SetConsoleMode(_stderr_handle, want)
        end
    end)
    _enabled = ok and true or false
    return _enabled
end

-- Expose the resolved handles for sibling packages (term, prompt, keyboard,
-- tui) so they don't need to re-query GetStdHandle.
function M._stdout() resolve_handles(); return _stdout_handle end
function M._stdin()  resolve_handles(); return _stdin_handle end
function M._stderr() resolve_handles(); return _stderr_handle end

-- ===== Strip helper ===================================================

function M.strip(s)
    if type(s) ~= "string" then return s end
    -- CSI: ESC [ <params> <intermediate> <final>. We also strip OSC ESC ] ... BEL/ST.
    s = s:gsub(ESC .. "%[[%d;]*[%a]", "")
    s = s:gsub(ESC .. "%].-" .. string.char(7), "")
    s = s:gsub(ESC .. "%].-" .. ESC .. "\\", "")
    return s
end

-- ===== Style construction ============================================

local function wrap(code, s)
    if type(s) ~= "string" then s = tostring(s) end
    if not M.supports_color() then return s end
    -- Make nested styles compose by re-emitting our opening code after any
    -- inner reset (\27[0m). Without this, an inner reset would clear our
    -- color before the outer text continues.
    local body = s:gsub(ESC .. "%[0m", M.reset .. CSI .. code .. "m")
    return CSI .. code .. "m" .. body .. M.reset
end

-- 16-color foreground (30-37 normal, 90-97 bright)
local _FG = {
    black = 30, red = 31, green = 32, yellow = 33,
    blue = 34, magenta = 35, cyan = 36, white = 37,
    bright_black = 90, gray = 90, grey = 90,
    bright_red = 91, bright_green = 92, bright_yellow = 93,
    bright_blue = 94, bright_magenta = 95, bright_cyan = 96, bright_white = 97,
}
for name, code in pairs(_FG) do
    M[name] = function(s) return wrap(tostring(code), s) end
end

-- 16-color background (40-47 normal, 100-107 bright)
local _BG = {
    black = 40, red = 41, green = 42, yellow = 43,
    blue = 44, magenta = 45, cyan = 46, white = 47,
    bright_black = 100, gray = 100, grey = 100,
    bright_red = 101, bright_green = 102, bright_yellow = 103,
    bright_blue = 104, bright_magenta = 105, bright_cyan = 106, bright_white = 107,
}
M.bg = {}
for name, code in pairs(_BG) do
    M.bg[name] = function(s) return wrap(tostring(code), s) end
end

-- Attributes (SGR codes)
local _ATTR = {
    bold = 1, dim = 2, italic = 3, underline = 4,
    blink = 5, inverse = 7, reverse = 7, hidden = 8, strike = 9,
}
for name, code in pairs(_ATTR) do
    M[name] = function(s) return wrap(tostring(code), s) end
end

-- ===== Truecolor and 256-color closures ==============================

function M.rgb(r, g, b)
    local code = "38;2;" .. r .. ";" .. g .. ";" .. b
    return function(s) return wrap(code, s) end
end

function M.rgb_bg(r, g, b)
    local code = "48;2;" .. r .. ";" .. g .. ";" .. b
    return function(s) return wrap(code, s) end
end

function M.color256(n)
    return function(s) return wrap("38;5;" .. n, s) end
end

function M.color256_bg(n)
    return function(s) return wrap("48;5;" .. n, s) end
end

-- ===== Hex parsing convenience =======================================

function M.hex(h)
    -- Accept "#rrggbb" or "rrggbb".
    h = h:gsub("^#", "")
    if #h == 3 then
        -- Expand "#abc" to "#aabbcc".
        h = h:sub(1,1):rep(2) .. h:sub(2,2):rep(2) .. h:sub(3,3):rep(2)
    end
    local r = tonumber(h:sub(1,2), 16)
    local g = tonumber(h:sub(3,4), 16)
    local b = tonumber(h:sub(5,6), 16)
    return M.rgb(r, g, b)
end

-- ===== Visible width ==================================================
-- Handy for layout code that needs to size a string ignoring escapes.

function M.visible_width(s)
    local stripped = M.strip(s)
    -- Naive: 1 cell per byte for ASCII. We don't try to handle CJK / combining
    -- chars here -- TUI layout code should pre-strip and assume monospace.
    return #stripped
end

return M
