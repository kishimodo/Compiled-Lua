-- prompt -- Interactive question / answer helpers.
--
-- All prompts return nil on Ctrl-C (cancellation). Validators may run repeatedly
-- so users can correct invalid input without losing the surrounding flow.
--
-- Public surface:
--   prompt.input(question, opts?)        -> string|nil
--   prompt.password(question, opts?)     -> string|nil
--   prompt.select(question, choices, opts?) -> index, item|nil
--   prompt.multi_select(question, choices, opts?) -> {indices}|nil
--   prompt.confirm(question, default?)   -> bool|nil
--   prompt.number(question, opts?)       -> number|nil
--   prompt.choose_file(question, opts?)  -> string|nil  (path picker)
--
-- opts (input/password/number):
--   default     -- value to use when the user just presses enter
--   validate    -- fn(value) -> ok, err_msg
--   allow_empty -- bool
--   max_length  -- bytes
--
-- opts (select/multi_select):
--   default     -- index (or set of indices for multi)
--   render      -- fn(item, i) -> string  (custom row format)
--   page_size   -- number of choices visible at once before scrolling

local color    = require "color"
local term     = require "term"
local keyboard = require "keyboard"

local M = {}

-- ===== Plain input ==================================================

local function show_question(q, default_hint)
    io.write(color.cyan("? ") .. color.bold(q))
    if default_hint then
        io.write(color.dim(" (" .. default_hint .. ")"))
    end
    io.write(" ")
    io.flush()
end

function M.input(question, opts)
    opts = opts or {}
    local default_hint = opts.default and tostring(opts.default) or nil
    show_question(question, default_hint)

    while true do
        local s = keyboard.read_line({
            history   = opts.history or {},
            completer = opts.completer,
        })
        if s == nil then return nil end
        if s == "" and opts.default ~= nil then s = tostring(opts.default) end
        if s == "" and not opts.allow_empty then
            io.write(color.red("  please enter a value\n"))
            show_question(question, default_hint)
        elseif opts.validate then
            local ok, err = opts.validate(s)
            if ok then return s end
            io.write(color.red("  " .. (err or "invalid input") .. "\n"))
            show_question(question, default_hint)
        else
            return s
        end
    end
end

-- ===== Password (no echo) ===========================================

function M.password(question, opts)
    opts = opts or {}
    show_question(question)
    -- read_line supports a mask char; pass nil-mask to show nothing at all
    -- (most password prompts hide everything to avoid revealing length).
    local mask = opts.mask  -- e.g. "*" if you want length feedback
    local s = keyboard.read_line({ mask = mask })
    if s == nil then return nil end
    return s
end

-- ===== Confirm ======================================================

function M.confirm(question, default)
    local hint = default == true and "Y/n" or default == false and "y/N" or "y/n"
    show_question(question, hint)
    while true do
        local ev = keyboard.read_key()
        if not ev then return nil end
        if ev.ctrl and ev.name == "c" then io.write("\n"); return nil end
        if ev.name == "enter" then
            io.write("\n")
            return default == true and true or default == false and false or false
        elseif ev.char then
            local ch = ev.char:lower()
            if ch == "y" then io.write("yes\n"); return true end
            if ch == "n" then io.write("no\n"); return false end
        end
    end
end

-- ===== Number =======================================================

function M.number(question, opts)
    opts = opts or {}
    while true do
        local s = M.input(question, {
            default     = opts.default,
            allow_empty = false,
            validate    = function(v)
                local n = tonumber(v)
                if not n then return false, "expected a number" end
                if opts.min and n < opts.min then return false, "must be >= " .. opts.min end
                if opts.max and n > opts.max then return false, "must be <= " .. opts.max end
                if opts.integer and n ~= math.floor(n) then return false, "must be an integer" end
                if opts.validate then return opts.validate(n) end
                return true
            end,
        })
        if s == nil then return nil end
        return tonumber(s)
    end
end

-- ===== Select =======================================================
-- Renders an interactive list with a moving cursor. Arrow keys / j-k / k-j
-- to move; Enter to confirm; Esc/Ctrl-C to cancel.

local function clamp(n, lo, hi)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

local function render_choices(choices, opts, sel_idx, marks, scroll, page_size)
    -- Clear previous render area: we move up `page_size` rows + paint.
    local renderer = opts.render or function(item) return tostring(item) end
    local _, rows = term.size()
    if not page_size or page_size > #choices then page_size = math.min(#choices, math.max(rows - 5, 5)) end

    -- Adjust scroll to keep selection visible.
    if sel_idx < scroll + 1 then scroll = sel_idx - 1 end
    if sel_idx > scroll + page_size then scroll = sel_idx - page_size end
    if scroll < 0 then scroll = 0 end

    for i = 1, page_size do
        local idx = scroll + i
        local item = choices[idx]
        if item == nil then
            io.write("\27[2K\n")
        else
            local cursor = (idx == sel_idx) and color.cyan("> ") or "  "
            local mark = ""
            if marks then
                mark = marks[idx] and color.green("[x] ") or color.dim("[ ] ")
            end
            local label = renderer(item, idx)
            io.write("\27[2K" .. cursor .. mark .. label .. "\n")
        end
    end
    -- Move back to the top of the rendered block so the next render overwrites.
    io.write("\27[" .. page_size .. "A")
    io.flush()
    return scroll, page_size
end

function M.select(question, choices, opts)
    opts = opts or {}
    show_question(question)
    io.write("\n")
    local sel = opts.default or 1
    sel = clamp(sel, 1, #choices)
    local scroll, page_size = render_choices(choices, opts, sel, nil, 0, opts.page_size)
    keyboard.enable_raw_mode()
    while true do
        local ev = keyboard.read_key()
        if not ev then
            -- spurious
        elseif (ev.ctrl and ev.name == "c") or ev.name == "esc" then
            -- Cancel: clear block, restore cursor.
            for _ = 1, page_size do io.write("\27[2K\n") end
            io.write("\27[" .. page_size .. "A")
            io.flush()
            keyboard.disable_raw_mode()
            return nil
        elseif ev.name == "up" or ev.name == "k" then
            sel = clamp(sel - 1, 1, #choices)
            scroll = render_choices(choices, opts, sel, nil, scroll, page_size)
        elseif ev.name == "down" or ev.name == "j" then
            sel = clamp(sel + 1, 1, #choices)
            scroll = render_choices(choices, opts, sel, nil, scroll, page_size)
        elseif ev.name == "home" or ev.name == "g" then
            sel = 1
            scroll = render_choices(choices, opts, sel, nil, scroll, page_size)
        elseif ev.name == "end" or ev.name == "G" then
            sel = #choices
            scroll = render_choices(choices, opts, sel, nil, scroll, page_size)
        elseif ev.name == "enter" then
            -- Clear the block so subsequent output starts clean.
            for _ = 1, page_size do io.write("\27[2K\n") end
            io.write("\27[" .. page_size .. "A")
            -- Print final selection inline above for readability.
            io.write(color.green("[+] ") .. tostring(choices[sel]) .. "\n")
            io.flush()
            keyboard.disable_raw_mode()
            return sel, choices[sel]
        end
    end
end

function M.multi_select(question, choices, opts)
    opts = opts or {}
    show_question(question, "space to toggle, enter to confirm")
    io.write("\n")
    local sel = opts.default_cursor or 1
    sel = clamp(sel, 1, #choices)
    local marks = {}
    if opts.default then
        if type(opts.default) == "table" then
            for _, i in ipairs(opts.default) do marks[i] = true end
        end
    end
    local scroll, page_size = render_choices(choices, opts, sel, marks, 0, opts.page_size)
    keyboard.enable_raw_mode()
    while true do
        local ev = keyboard.read_key()
        if not ev then
        elseif (ev.ctrl and ev.name == "c") or ev.name == "esc" then
            for _ = 1, page_size do io.write("\27[2K\n") end
            io.write("\27[" .. page_size .. "A"); io.flush()
            keyboard.disable_raw_mode()
            return nil
        elseif ev.name == "up" or ev.name == "k" then
            sel = clamp(sel - 1, 1, #choices)
            scroll = render_choices(choices, opts, sel, marks, scroll, page_size)
        elseif ev.name == "down" or ev.name == "j" then
            sel = clamp(sel + 1, 1, #choices)
            scroll = render_choices(choices, opts, sel, marks, scroll, page_size)
        elseif ev.name == "space" or ev.char == " " then
            marks[sel] = not marks[sel]
            scroll = render_choices(choices, opts, sel, marks, scroll, page_size)
        elseif ev.char == "a" and ev.ctrl then
            -- Ctrl-A toggles all.
            local any = false
            for i = 1, #choices do if marks[i] then any = true; break end end
            for i = 1, #choices do marks[i] = not any end
            scroll = render_choices(choices, opts, sel, marks, scroll, page_size)
        elseif ev.name == "enter" then
            for _ = 1, page_size do io.write("\27[2K\n") end
            io.write("\27[" .. page_size .. "A")
            local picked = {}
            for i = 1, #choices do if marks[i] then picked[#picked+1] = i end end
            local picked_labels = {}
            for _, i in ipairs(picked) do picked_labels[#picked_labels+1] = tostring(choices[i]) end
            io.write(color.green("[+] ") .. table.concat(picked_labels, ", ") .. "\n")
            io.flush()
            keyboard.disable_raw_mode()
            return picked
        end
    end
end

return M
