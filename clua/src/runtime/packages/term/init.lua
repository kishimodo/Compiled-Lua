-- term -- Cursor positioning, screen control, and alt-screen via ANSI VT.
--
-- All output goes through io.write; callers should ensure VT is enabled with
-- color.enable() once at startup. None of these helpers query terminal state
-- on their own -- they just emit the well-known CSI sequences so they work
-- on Windows Terminal, ConHost (Win10+ with VT), and any POSIX terminal.
--
-- Public surface:
--   clear(), clear_line(), clear_above(), clear_below(),
--   clear_screen_keep_scrollback()
--   move(x, y) -- 1-indexed, (column, row)
--   up(n), down(n), left(n), right(n)
--   col(n), row(n)
--   save_pos(), restore_pos()
--   enter_alt_screen(), leave_alt_screen()
--   with_alt_screen(fn)  -- pcall-wrapped, leaves alt screen on error
--   hide_cursor(), show_cursor()
--   bell()
--   size() -> cols, rows         (queries the Windows console; falls back to env)
--   set_title(s)                 -- OSC 0
--   scroll_up(n), scroll_down(n)
--   write(...), writeln(...)     -- convenience that bundles io.write + flush

local M = {}

local ESC = string.char(27)
local CSI = ESC .. "["

-- Internal: write + flush, but skip the flush when not on a tty (printf-buffered
-- stdout would just smear output across reboots otherwise).
local function out(s)
    io.write(s)
end

function M.write(...)
    io.write(...)
end

function M.writeln(...)
    io.write(...)
    io.write("\n")
end

-- ===== Clearing =======================================================

function M.clear()
    -- ED 2: erase entire screen. Cursor stays put per spec, so we also
    -- home it so a fresh paint starts at (1,1).
    out(CSI .. "2J" .. CSI .. "H")
end

function M.clear_line()
    -- EL 2: erase whole line; cursor column unchanged.
    out(CSI .. "2K")
end

function M.clear_above()
    out(CSI .. "1J")
end

function M.clear_below()
    out(CSI .. "0J")
end

function M.clear_screen_keep_scrollback()
    -- Different from clear(): only clears the visible viewport, leaving the
    -- scrollback buffer intact. Useful in REPLs where users want \C-l.
    out(CSI .. "H" .. CSI .. "2J")
end

-- ===== Cursor movement ===============================================

function M.move(x, y)
    -- CSI <row>;<col>H. We expose (x, y) = (column, row) since most callers
    -- think in screen coordinates.
    out(CSI .. tostring(y) .. ";" .. tostring(x) .. "H")
end

function M.up(n)    out(CSI .. tostring(n or 1) .. "A") end
function M.down(n)  out(CSI .. tostring(n or 1) .. "B") end
function M.right(n) out(CSI .. tostring(n or 1) .. "C") end
function M.left(n)  out(CSI .. tostring(n or 1) .. "D") end

function M.col(n)
    -- CHA: move to absolute column on current row.
    out(CSI .. tostring(n) .. "G")
end

function M.row(n)
    -- VPA: move to absolute row, current column unchanged.
    out(CSI .. tostring(n) .. "d")
end

function M.save_pos()    out(ESC .. "7") end   -- DECSC, more widely supported than CSI s
function M.restore_pos() out(ESC .. "8") end   -- DECRC

-- ===== Alt screen =====================================================
-- 1049 = save cursor + switch to alt screen + clear; 1049l = restore.
-- This is the modern variant; ?47h and ?1047h are kept for legacy but lose
-- the cursor save -- we don't expose them.

function M.enter_alt_screen()
    out(CSI .. "?1049h")
end

function M.leave_alt_screen()
    out(CSI .. "?1049l")
end

function M.with_alt_screen(fn)
    M.enter_alt_screen()
    M.hide_cursor()
    local ok, err = pcall(fn)
    M.show_cursor()
    M.leave_alt_screen()
    if not ok then error(err, 0) end
end

-- ===== Cursor visibility =============================================

function M.hide_cursor() out(CSI .. "?25l") end
function M.show_cursor() out(CSI .. "?25h") end

-- ===== Bell / title ==================================================

function M.bell() out(string.char(7)) end

function M.set_title(s)
    -- OSC 0;<title>BEL.
    out(ESC .. "]0;" .. s .. string.char(7))
end

-- ===== Scrolling region =============================================

function M.scroll_up(n)   out(CSI .. tostring(n or 1) .. "S") end
function M.scroll_down(n) out(CSI .. tostring(n or 1) .. "T") end

function M.set_scroll_region(top, bottom)
    -- CSI t;b r. Pair with reset_scroll_region() at teardown -- leaving a
    -- region set across a process boundary confuses subsequent shells.
    out(CSI .. tostring(top) .. ";" .. tostring(bottom) .. "r")
end

function M.reset_scroll_region()
    out(CSI .. "r")
end

-- ===== Size query ====================================================

function M.size()
    -- Try the Windows console API first via the color package's cached
    -- stdout handle (avoids a redundant GetStdHandle round-trip).
    local ok, c = pcall(require, "color")
    if ok then
        local handle = c._stdout()
        if handle then
            local ok2 = pcall(function()
                require "windows.console"
                local info = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
                if ffi.C.GetConsoleScreenBufferInfo(handle, info) ~= 0 then
                    -- srWindow gives the viewport (visible area), not the buffer.
                    -- That's what callers want for layout.
                    return info.srWindow.Right - info.srWindow.Left + 1,
                           info.srWindow.Bottom - info.srWindow.Top + 1
                end
            end)
            if ok2 then
                require "windows.console"
                local info = ffi.new("CONSOLE_SCREEN_BUFFER_INFO")
                if ffi.C.GetConsoleScreenBufferInfo(handle, info) ~= 0 then
                    return info.srWindow.Right - info.srWindow.Left + 1,
                           info.srWindow.Bottom - info.srWindow.Top + 1
                end
            end
        end
    end
    -- Fall back to env vars (set by some shells/IDEs).
    local cols = tonumber(os.getenv("COLUMNS")) or 80
    local rows = tonumber(os.getenv("LINES"))   or 24
    return cols, rows
end

-- ===== Combined helpers ==============================================

function M.print_at(x, y, ...)
    M.save_pos()
    M.move(x, y)
    io.write(...)
    M.restore_pos()
end

function M.fill_line(ch)
    -- Fill the current row with a single char, then return cursor to col 1.
    local cols = select(1, M.size())
    out(string.rep(ch or " ", cols))
    out("\r")
end

return M
