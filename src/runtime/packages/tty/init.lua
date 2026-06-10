-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- tty -- terminal control: raw mode, size, cursor, color capability detect.
--
-- Built on top of GetStdHandle + GetConsoleMode / SetConsoleMode plus
-- virtual terminal sequences for everything that's a string emission.
-- Windows 10 1607+ has the VT processing mode (ENABLE_VIRTUAL_TERMINAL_
-- PROCESSING) -- once enabled, ANSI escape sequences just work and we
-- get the same ergonomics as Unix terminals.
--
-- Public surface:
--   tty.is_tty(stream?)         -- stream in {"stdin","stdout","stderr"}; default stdout
--   tty.size()                  -> width, height (in cells)
--   tty.enable_vt()             -- turn on ENABLE_VIRTUAL_TERMINAL_PROCESSING on stdout
--   tty.raw_mode(on, stream?)   -- disable line buffer + echo (stdin)
--   tty.hide_cursor() / show_cursor()
--   tty.clear()                 -- clear screen + move to (1,1)
--   tty.move(x, y)              -- 1-based column, row
--   tty.set_title(s)            -- SetConsoleTitleW
--   tty.supports_truecolor()    -- best-effort env-var sniffing
--   tty.supports_256color()
--   tty.color(fg?, bg?, ...style)  -- returns the SGR escape string

local W = require "windows"

-- We do NOT require "windows.console" here because the cdefs there use
-- typedef'd enums (CONSOLE_MODE, STD_HANDLE) that other windows sub-
-- packages don't define -- pulling it in would fail at load time on a
-- bare windows install. Re-declare the small surface we need locally.

ffi.cdef[[
HANDLE GetStdHandle(DWORD nStdHandle);
BOOL GetConsoleMode(HANDLE hConsoleHandle, DWORD *lpMode);
BOOL SetConsoleMode(HANDLE hConsoleHandle, DWORD dwMode);
BOOL SetConsoleTitleW(LPCWSTR lpConsoleTitle);
typedef struct _tty_COORD { short X; short Y; } tty_COORD;
typedef struct _tty_SMALL_RECT { short L, T, R, B; } tty_SMALL_RECT;
typedef struct _tty_CSBI {
    tty_COORD dwSize;
    tty_COORD dwCursorPosition;
    WORD wAttributes;
    tty_SMALL_RECT srWindow;
    tty_COORD dwMaximumWindowSize;
} tty_CSBI;
BOOL GetConsoleScreenBufferInfo(HANDLE hConsoleOutput, tty_CSBI *info);
DWORD GetFileType(HANDLE hFile);
]]

local C = ffi.C

-- Std-handle codes (signed casts because the Windows ABI specifies them
-- as (DWORD)-10/-11/-12 but the FFI thunk wants the right sign).
local STD_INPUT  = 0xFFFFFFF6  -- -10
local STD_OUTPUT = 0xFFFFFFF5  -- -11
local STD_ERROR  = 0xFFFFFFF4  -- -12

local STREAM_TO_HANDLE_CODE = {
    stdin  = STD_INPUT,
    stdout = STD_OUTPUT,
    stderr = STD_ERROR,
}

local function get_handle(stream)
    return C.GetStdHandle(STREAM_TO_HANDLE_CODE[stream or "stdout"])
end

local FILE_TYPE_CHAR = 0x0002

-- Console mode flags we touch
local ENABLE_PROCESSED_INPUT             = 0x0001
local ENABLE_LINE_INPUT                  = 0x0002
local ENABLE_ECHO_INPUT                  = 0x0004
local ENABLE_VIRTUAL_TERMINAL_INPUT      = 0x0200
local ENABLE_PROCESSED_OUTPUT            = 0x0001
local ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
local DISABLE_NEWLINE_AUTO_RETURN        = 0x0008

local M = {}

-- ===== capability detection =============================================

function M.is_tty(stream)
    local h = get_handle(stream)
    if h == nil then return false end
    -- A console-attached stream returns FILE_TYPE_CHAR AND has a console
    -- mode (redirected streams to NUL or files don't).
    if C.GetFileType(h) ~= FILE_TYPE_CHAR then return false end
    local mode = ffi.new("DWORD[1]")
    return C.GetConsoleMode(h, mode) ~= 0
end

function M.size()
    local h = get_handle("stdout")
    local info = ffi.new("tty_CSBI")
    if C.GetConsoleScreenBufferInfo(h, info) == 0 then
        return 80, 25  -- conservative default, e.g. when stdout is piped
    end
    local w = tonumber(info.srWindow.R) - tonumber(info.srWindow.L) + 1
    local h_lines = tonumber(info.srWindow.B) - tonumber(info.srWindow.T) + 1
    return w, h_lines
end

function M.enable_vt(stream)
    local h = get_handle(stream or "stdout")
    local mode = ffi.new("DWORD[1]")
    if C.GetConsoleMode(h, mode) == 0 then
        return false, "GetConsoleMode failed: " .. tonumber(C.GetLastError())
    end
    local want = bit.bor(mode[0], ENABLE_VIRTUAL_TERMINAL_PROCESSING,
                                  ENABLE_PROCESSED_OUTPUT)
    if C.SetConsoleMode(h, want) == 0 then
        return false, "SetConsoleMode failed: " .. tonumber(C.GetLastError())
    end
    return true
end

-- ===== raw mode =========================================================
--
-- Saves the previous mode in a closed-over table keyed by stream so
-- raw_mode("stdin", false) restores exactly what was there before.

local g_saved_modes = {}

function M.raw_mode(on, stream)
    stream = stream or "stdin"
    local h = get_handle(stream)
    if on then
        local mode = ffi.new("DWORD[1]")
        if C.GetConsoleMode(h, mode) == 0 then
            return false, "GetConsoleMode failed: " .. tonumber(C.GetLastError())
        end
        g_saved_modes[stream] = tonumber(mode[0])
        -- clear line-input, echo, and the processed-input flag (so Ctrl-C
        -- comes through as a raw byte instead of a signal). Keep the VT
        -- input flag if it was already set.
        local raw = bit.band(mode[0],
            bit.bnot(bit.bor(ENABLE_LINE_INPUT,
                             ENABLE_ECHO_INPUT,
                             ENABLE_PROCESSED_INPUT)))
        if C.SetConsoleMode(h, raw) == 0 then
            return false, "SetConsoleMode failed: " .. tonumber(C.GetLastError())
        end
    else
        local saved = g_saved_modes[stream]
        if saved == nil then return true end  -- nothing to restore
        if C.SetConsoleMode(h, saved) == 0 then
            return false, "SetConsoleMode failed: " .. tonumber(C.GetLastError())
        end
        g_saved_modes[stream] = nil
    end
    return true
end

-- ===== VT-sequence helpers ==============================================
--
-- All of these emit ANSI escape sequences directly. They expect the caller
-- to have called tty.enable_vt() at startup -- modern Windows consoles
-- need that toggle before they'll interpret the escapes.

function M.hide_cursor() io.write("\27[?25l") end
function M.show_cursor() io.write("\27[?25h") end
function M.clear()       io.write("\27[2J\27[H") end

function M.move(x, y)
    -- ANSI CUP is 1-based. We accept 1-based inputs because that matches
    -- every other terminal API; users converting from 0-based grids will
    -- have to add 1, but the alternative (silent +1) is more confusing.
    io.write(string.format("\27[%d;%dH", y, x))
end

function M.set_title(s)
    local w = W.ToWide(s)
    if C.SetConsoleTitleW(w) == 0 then
        return false, "SetConsoleTitleW failed: " .. tonumber(C.GetLastError())
    end
    return true
end

-- ===== color =============================================================
--
-- Detection is heuristic: COLORTERM=truecolor for 24-bit, TERM containing
-- "256" for 8-bit. Windows Terminal sets COLORTERM=truecolor; conhost on
-- Win10+ supports truecolor too once VT is on. We default to "yes" on
-- modern Windows when no env var disambiguates.

local function getenv(name)
    -- avoid pulling in the env package; tty is meant to be lightweight
    local buf = ffi.new("unsigned short[1024]")
    local wname = W.ToWide(name)
    local n = ffi.C.GetEnvironmentVariableW(wname, buf, 1024)
    if n == 0 or n > 1024 then return nil end
    return W.FromWide(buf)
end

function M.supports_truecolor()
    local ct = getenv("COLORTERM")
    if ct and (ct == "truecolor" or ct == "24bit") then return true end
    -- Win10 1703+ conhost + Windows Terminal both support it; we can't
    -- detect the build cheaply, so optimistically say yes when the
    -- environment looks console-attached.
    return M.is_tty("stdout")
end

function M.supports_256color()
    if M.supports_truecolor() then return true end
    local t = getenv("TERM")
    if t and t:find("256", 1, true) then return true end
    return false
end

-- SGR builder. tty.color(31, 47, "bold") -> "\27[1;31;47m".
-- Pass integers for raw SGR codes (foreground 30-37 / 90-97, background
-- 40-47 / 100-107). Style strings: "bold", "dim", "italic", "underline",
-- "reverse", "strike", "reset".
local STYLE_SGR = {
    reset = 0, bold = 1, dim = 2, italic = 3, underline = 4,
    blink = 5, reverse = 7, hidden = 8, strike = 9,
}

function M.color(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "number" then
            parts[#parts + 1] = tostring(v)
        elseif type(v) == "string" then
            local code = STYLE_SGR[v]
            if code then parts[#parts + 1] = tostring(code) end
        end
    end
    if #parts == 0 then return "\27[0m" end
    return "\27[" .. table.concat(parts, ";") .. "m"
end

M.RESET = "\27[0m"

return M
