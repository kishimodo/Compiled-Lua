-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- keyboard -- Raw keypress reader on top of ReadConsoleInputW.
--
-- Returns a structured event for every keystroke including F-keys, arrows,
-- Ctrl-combos, Alt-prefixed (Alt+letter), and printable characters. Mouse and
-- window-resize events are filtered out (those belong to the tui package).
--
-- Public surface:
--   keyboard.read_key(timeout_ms?) -> event|nil
--   keyboard.read_line(opts?)      -> string|nil   (full line editing)
--   keyboard.wait_for(keys, timeout_ms?) -> name|nil
--   keyboard.with_raw_mode(fn)     -- RAII switch in/out of raw input
--   keyboard.peek_buffered()       -> n  (count of pending input records)
--
-- Event shape:
--   { name = "a"|"enter"|"esc"|"up"|"f5"|...,
--     char = "a",            -- printable char (UTF-8) if any, else nil
--     ctrl = bool, alt = bool, shift = bool }

local W = require "windows"
require "windows.console"
local color = require "color"

local M = {}

-- ===== Saved console mode for restore ================================

local _saved_in_mode  = nil
local _saved_out_mode = nil

local function get_mode(handle)
    local m = ffi.new("CONSOLE_MODE[1]")
    if ffi.C.GetConsoleMode(handle, m) == 0 then return nil end
    return m[0]
end

function M.enable_raw_mode()
    local h_in = color._stdin()
    if not h_in then return false end
    if _saved_in_mode == nil then
        _saved_in_mode = get_mode(h_in)
    end
    -- Disable line input + echo + processed input (we want raw Ctrl-C etc).
    -- Keep WINDOW_INPUT off so resizes don't pollute our queue.
    local new_mode = bit.bor(
        W.CONSOLE_MODE and W.CONSOLE_MODE_ENABLE_VIRTUAL_TERMINAL_INPUT or 0x0200,
        0)  -- start with only VT input; line/echo/processed all cleared.
    -- The console package's enum names get re-exported with the
    -- CONSOLE_MODE_ prefix; we hard-code the bit value as a safety net.
    ffi.C.SetConsoleMode(h_in, new_mode)
    return true
end

function M.disable_raw_mode()
    local h_in = color._stdin()
    if not h_in or _saved_in_mode == nil then return end
    ffi.C.SetConsoleMode(h_in, _saved_in_mode)
    _saved_in_mode = nil
end

function M.with_raw_mode(fn)
    M.enable_raw_mode()
    local ok, err = pcall(fn)
    M.disable_raw_mode()
    if not ok then error(err, 0) end
end

-- ===== VK -> name translation ========================================

local _VK_NAMES = {
    [0x08] = "backspace",
    [0x09] = "tab",
    [0x0D] = "enter",
    [0x1B] = "esc",
    [0x20] = "space",
    [0x21] = "pageup",   [0x22] = "pagedown",
    [0x23] = "end",      [0x24] = "home",
    [0x25] = "left",     [0x26] = "up",
    [0x27] = "right",    [0x28] = "down",
    [0x2D] = "insert",   [0x2E] = "delete",
    [0x70] = "f1",  [0x71] = "f2",  [0x72] = "f3",  [0x73] = "f4",
    [0x74] = "f5",  [0x75] = "f6",  [0x76] = "f7",  [0x77] = "f8",
    [0x78] = "f9",  [0x79] = "f10", [0x7A] = "f11", [0x7B] = "f12",
}

-- ===== INPUT_RECORD parser ===========================================
-- The struct is opaque (uses union _Char_e__Union for the WCHAR/AsciiChar pair
-- and the encoding doesn't expose member names via cdef). We read fields by
-- byte offset from the WORD-aligned layout:
--
--   offset  size  field
--   0       2     EventType (KEY_EVENT=1, MOUSE_EVENT=2, WINDOW_BUFFER_SIZE=4)
--   4       4     bKeyDown          (DWORD-aligned BOOL)
--   8       2     wRepeatCount
--   10      2     wVirtualKeyCode
--   12      2     wVirtualScanCode
--   14      2     uChar.UnicodeChar (WCHAR)
--   16      4     dwControlKeyState
--
-- sizeof(INPUT_RECORD) is 20 bytes on Win64.

local INPUT_RECORD_SIZE = 20

local function read_input_record(buf, i)
    local base = ffi.cast("unsigned char*", buf) + (i * INPUT_RECORD_SIZE)
    local event_type = ffi.cast("unsigned short*", base)[0]
    if event_type ~= 1 then return nil end  -- not KEY_EVENT

    -- Cast for typed reads at the right offsets.
    local key_down  = ffi.cast("int*", base + 4)[0]
    local vk        = ffi.cast("unsigned short*", base + 10)[0]
    local wch       = ffi.cast("unsigned short*", base + 14)[0]
    local ctrl_keys = ffi.cast("unsigned long*", base + 16)[0]

    if key_down == 0 then return nil end  -- ignore key-up

    local shift = bit.band(ctrl_keys, W.SHIFT_PRESSED) ~= 0
    local ctrl  = bit.band(ctrl_keys, bit.bor(W.LEFT_CTRL_PRESSED, W.RIGHT_CTRL_PRESSED)) ~= 0
    local alt   = bit.band(ctrl_keys, bit.bor(W.LEFT_ALT_PRESSED, W.RIGHT_ALT_PRESSED)) ~= 0

    local name = _VK_NAMES[vk]
    local ch
    if wch >= 0x20 and wch ~= 0x7F then
        -- UTF-16 -> UTF-8 (one wchar, no surrogate pairs for typical input).
        if wch < 0x80 then
            ch = string.char(wch)
        elseif wch < 0x800 then
            ch = string.char(
                0xC0 + bit.rshift(wch, 6),
                0x80 + bit.band(wch, 0x3F))
        else
            ch = string.char(
                0xE0 + bit.rshift(wch, 12),
                0x80 + bit.band(bit.rshift(wch, 6), 0x3F),
                0x80 + bit.band(wch, 0x3F))
        end
    end

    if not name then
        if ch then
            name = ch:lower()
        elseif vk >= 0x30 and vk <= 0x39 then
            name = string.char(vk)  -- top-row digits
        elseif vk >= 0x41 and vk <= 0x5A then
            name = string.char(vk + 32)  -- A-Z -> lowercase name
        else
            name = string.format("vk%02x", vk)
        end
    end

    return {
        name  = name,
        char  = ch,
        ctrl  = ctrl,
        alt   = alt,
        shift = shift,
        vk    = vk,
    }
end

-- ===== Event queue ===================================================
-- We drain one INPUT_RECORD batch at a time; the queue smooths the boundary
-- between batched reads (e.g. paste delivers a flood of records) and the
-- one-event-per-call API users expect.

local _queue, _qhead, _qtail = {}, 1, 0

local function pump(timeout_ms)
    local h_in = color._stdin()
    if not h_in then return false end
    -- Use WaitForSingleObject to honor the timeout before blocking on
    -- ReadConsoleInputW (which itself only takes a count, not a timeout).
    if timeout_ms then
        local W2 = W
        local rc = ffi.C.WaitForSingleObject(h_in, timeout_ms)
        if rc == W2.WAIT_TIMEOUT then return false end
    end
    -- Drain everything currently buffered so a paste doesn't dribble out.
    local pending = ffi.new("unsigned long[1]")
    if ffi.C.GetNumberOfConsoleInputEvents(h_in, pending) == 0 then return false end
    local n = pending[0]
    if n == 0 then n = 1 end  -- block for at least one event
    if n > 64 then n = 64 end
    local buf = ffi.new("unsigned char[?]", n * INPUT_RECORD_SIZE)
    local read = ffi.new("unsigned long[1]")
    if ffi.C.ReadConsoleInputW(h_in, ffi.cast("INPUT_RECORD*", buf), n, read) == 0 then
        return false
    end
    for i = 0, read[0] - 1 do
        local ev = read_input_record(buf, i)
        if ev then
            _qtail = _qtail + 1
            _queue[_qtail] = ev
        end
    end
    return _qtail >= _qhead
end

function M.peek_buffered()
    return _qtail - _qhead + 1
end

function M.read_key(timeout_ms)
    if _qhead > _qtail then
        if not pump(timeout_ms) then return nil end
    end
    if _qhead > _qtail then return nil end
    local ev = _queue[_qhead]
    _queue[_qhead] = nil
    _qhead = _qhead + 1
    if _qhead > _qtail then _qhead, _qtail = 1, 0 end  -- reset to avoid leak
    return ev
end

function M.wait_for(keys, timeout_ms)
    -- keys may be a single string or a set/array of names.
    local want = {}
    if type(keys) == "string" then want[keys] = true
    else
        for _, k in ipairs(keys) do want[k] = true end
    end
    local deadline
    if timeout_ms then deadline = ffi.C.GetTickCount64() + timeout_ms end
    while true do
        local remain
        if deadline then
            local now = ffi.C.GetTickCount64()
            if now >= deadline then return nil end
            remain = tonumber(deadline - now)
        end
        local ev = M.read_key(remain)
        if ev == nil then return nil end
        if want[ev.name] then return ev.name end
    end
end

-- ===== Line editor ===================================================
-- Minimal in-process line editor: chars, backspace, arrows (move within
-- buffer), Home/End, history navigation, Enter to submit, Ctrl-C cancels.

function M.read_line(opts)
    opts = opts or {}
    local prompt = opts.prompt or ""
    local history = opts.history or {}
    local hist_idx = #history + 1
    local saved_current = ""
    local completer = opts.completer    -- fn(line, pos) -> {candidates}, common_prefix
    local mask_char = opts.mask          -- if set, echo this instead of typed char

    local buf, cursor = {}, 0

    local function redraw()
        -- Repaint prompt + buffer in place; we use \r and clear-to-eol rather
        -- than tracking absolute cursor coords.
        io.write("\r" .. string.char(27) .. "[K" .. prompt)
        if mask_char then
            io.write(string.rep(mask_char, #buf))
        else
            for i = 1, #buf do io.write(buf[i]) end
        end
        -- Position cursor: prompt width is len(prompt) + cursor.
        local back = #buf - cursor
        if back > 0 then io.write(string.char(27) .. "[" .. back .. "D") end
        io.flush()
    end

    M.enable_raw_mode()
    redraw()
    while true do
        local ev = M.read_key()
        if ev == nil then
            -- spurious; loop
        elseif ev.ctrl and (ev.name == "c" or ev.vk == 0x03) then
            io.write("\n"); io.flush()
            M.disable_raw_mode()
            return nil
        elseif ev.ctrl and ev.name == "d" then
            if #buf == 0 then
                io.write("\n"); io.flush()
                M.disable_raw_mode()
                return nil
            end
        elseif ev.name == "enter" then
            io.write("\n"); io.flush()
            M.disable_raw_mode()
            return table.concat(buf)
        elseif ev.name == "backspace" then
            if cursor > 0 then
                table.remove(buf, cursor)
                cursor = cursor - 1
                redraw()
            end
        elseif ev.name == "delete" then
            if cursor < #buf then
                table.remove(buf, cursor + 1)
                redraw()
            end
        elseif ev.name == "left" then
            if cursor > 0 then cursor = cursor - 1; redraw() end
        elseif ev.name == "right" then
            if cursor < #buf then cursor = cursor + 1; redraw() end
        elseif ev.name == "home" then
            cursor = 0; redraw()
        elseif ev.name == "end" then
            cursor = #buf; redraw()
        elseif ev.name == "up" then
            if hist_idx > 1 then
                if hist_idx == #history + 1 then
                    saved_current = table.concat(buf)
                end
                hist_idx = hist_idx - 1
                buf = {}
                for c in history[hist_idx]:gmatch(".") do buf[#buf+1] = c end
                cursor = #buf
                redraw()
            end
        elseif ev.name == "down" then
            if hist_idx <= #history then
                hist_idx = hist_idx + 1
                if hist_idx == #history + 1 then
                    buf = {}
                    for c in saved_current:gmatch(".") do buf[#buf+1] = c end
                else
                    buf = {}
                    for c in history[hist_idx]:gmatch(".") do buf[#buf+1] = c end
                end
                cursor = #buf
                redraw()
            end
        elseif ev.name == "tab" and completer then
            local line = table.concat(buf)
            local cands, prefix = completer(line, cursor)
            if cands and #cands == 1 then
                -- replace word with the single completion
                local word_start = cursor
                while word_start > 0 and buf[word_start]:match("[%w_]") do
                    word_start = word_start - 1
                end
                for i = cursor, word_start + 1, -1 do table.remove(buf, i) end
                for c in cands[1]:gmatch(".") do
                    word_start = word_start + 1
                    table.insert(buf, word_start, c)
                end
                cursor = word_start
                redraw()
            elseif cands and #cands > 1 then
                io.write("\n")
                for _, c in ipairs(cands) do io.write(c .. "  ") end
                io.write("\n")
                if prefix and #prefix > 0 then
                    -- extend with the longest common prefix the completer found
                    for c in prefix:gmatch(".") do
                        cursor = cursor + 1
                        table.insert(buf, cursor, c)
                    end
                end
                redraw()
            end
        elseif ev.char then
            cursor = cursor + 1
            table.insert(buf, cursor, ev.char)
            redraw()
        end
    end
end

return M
