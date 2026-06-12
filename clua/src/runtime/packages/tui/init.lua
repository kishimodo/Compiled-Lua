-- BIT_SHIM_COMPAT: stock Lua 5.4 has no `bit` lib; native ops used instead
local bit = { band = function(a,b) return (tonumber(a) or 0) & (tonumber(b) or 0) end, bor = function(a, ...) local r = tonumber(a) or 0; for _,v in ipairs({...}) do r = r | (tonumber(v) or 0) end; return r end, bxor = function(a,b) return (tonumber(a) or 0) ~ (tonumber(b) or 0) end, bnot = function(a) return ~(tonumber(a) or 0) end, lshift = function(a,b) return (tonumber(a) or 0) << (tonumber(b) or 0) end, rshift = function(a,b) return (tonumber(a) or 0) >> (tonumber(b) or 0) end, }
-- tui -- Curses-like terminal UI: widgets, layout, focus, double-buffered paint.
--
-- This is a small, batteries-included TUI that doesn't try to reimplement
-- ncurses. The render model is:
--
--   * Screen owns a back-buffer of (rune, fg, bg, attrs) cells.
--   * Each widget paints into the buffer through a clipped Region API.
--   * After all widgets have painted, the screen diffs back-buffer against
--     front-buffer and emits only the changed cells -- O(changed) ANSI.
--   * Input is pulled from windows.console via the keyboard package; mouse
--     events get parsed from INPUT_RECORDs directly.
--
-- Public surface:
--   tui.screen(opts?)             -> screen object
--   screen:add(widget)            -- push a top-level widget (last one drawn = root)
--   screen:run()                  -- enter event loop until :stop()
--   screen:stop()                 -- exit run() at next event
--   screen:invalidate()           -- mark for repaint
--   screen:focus_next(), :focus_prev()
--
--   Widget constructors:
--     tui.text(s, opts?)
--     tui.input(opts?)
--     tui.button(label, on_click)
--     tui.list(items, on_select)
--     tui.table(rows, opts?)
--     tui.progress(opts?)
--     tui.vbox({children, ...})
--     tui.hbox({children, ...})
--     tui.grid({rows, cols, cells})
--     tui.border(child, opts?)

local color    = require "color"
local term     = require "term"
local keyboard = require "keyboard"
local W        = require "windows"
require "windows.console"

local M = {}

-- ===== Cell buffer ===================================================

local function new_buffer(w, h)
    local b = { w = w, h = h, cells = {} }
    for i = 1, w * h do
        b.cells[i] = { ch = " ", fg = nil, bg = nil, attr = 0 }
    end
    return b
end

local function buf_set(buf, x, y, ch, fg, bg, attr)
    if x < 1 or x > buf.w or y < 1 or y > buf.h then return end
    local cell = buf.cells[(y - 1) * buf.w + x]
    cell.ch = ch
    cell.fg = fg
    cell.bg = bg
    cell.attr = attr or 0
end

local function buf_clear(buf, fg, bg)
    for i = 1, buf.w * buf.h do
        local c = buf.cells[i]
        c.ch = " "; c.fg = fg; c.bg = bg; c.attr = 0
    end
end

local function cells_equal(a, b)
    return a.ch == b.ch and a.fg == b.fg and a.bg == b.bg and a.attr == b.attr
end

-- ===== Region (clipped writer used by widgets) =====================

local Region = {}
Region.__index = Region

local function make_region(buf, x, y, w, h)
    return setmetatable({
        buf = buf, ox = x, oy = y, w = w, h = h,
    }, Region)
end

function Region:put(x, y, ch, fg, bg, attr)
    if x < 1 or x > self.w or y < 1 or y > self.h then return end
    buf_set(self.buf, self.ox + x - 1, self.oy + y - 1, ch, fg, bg, attr)
end

function Region:text(x, y, s, fg, bg, attr)
    -- Naive: 1 byte = 1 cell. Good enough for ASCII; UTF-8 multibyte chars get
    -- truncated. TUI widgets pre-strip ANSI before reaching here.
    local i = 1
    local len = #s
    while i <= len and x <= self.w do
        local b = s:byte(i)
        local ch
        if b < 0x80 then
            ch = string.char(b); i = i + 1
        elseif b < 0xE0 then
            ch = s:sub(i, i+1); i = i + 2
        elseif b < 0xF0 then
            ch = s:sub(i, i+2); i = i + 3
        else
            ch = s:sub(i, i+3); i = i + 4
        end
        self:put(x, y, ch, fg, bg, attr)
        x = x + 1
    end
end

function Region:fill(ch, fg, bg, attr)
    for yy = 1, self.h do
        for xx = 1, self.w do
            self:put(xx, yy, ch, fg, bg, attr)
        end
    end
end

function Region:sub(x, y, w, h)
    -- Clip a sub-region; widgets use this to give children a bounded canvas.
    if x < 1 then w = w + x - 1; x = 1 end
    if y < 1 then h = h + y - 1; y = 1 end
    if x + w - 1 > self.w then w = self.w - x + 1 end
    if y + h - 1 > self.h then h = self.h - y + 1 end
    if w <= 0 or h <= 0 then return make_region(self.buf, self.ox, self.oy, 0, 0) end
    return make_region(self.buf, self.ox + x - 1, self.oy + y - 1, w, h)
end

-- ===== Attribute encoding =========================================
-- We pack styles into bitflags: 1 = bold, 2 = underline, 4 = inverse, 8 = dim.

local ATTR_BOLD, ATTR_UNDER, ATTR_INVERSE, ATTR_DIM = 1, 2, 4, 8

-- ===== Diff renderer ==============================================

local function sgr_for(cell)
    -- Compose an SGR sequence reflecting cell.fg, cell.bg, and attrs.
    local codes = { "0" }
    if cell.attr and cell.attr ~= 0 then
        if bit.band(cell.attr, ATTR_BOLD)    ~= 0 then codes[#codes+1] = "1" end
        if bit.band(cell.attr, ATTR_DIM)     ~= 0 then codes[#codes+1] = "2" end
        if bit.band(cell.attr, ATTR_UNDER)   ~= 0 then codes[#codes+1] = "4" end
        if bit.band(cell.attr, ATTR_INVERSE) ~= 0 then codes[#codes+1] = "7" end
    end
    if cell.fg then codes[#codes+1] = tostring(cell.fg) end
    if cell.bg then codes[#codes+1] = tostring(cell.bg) end
    return "\27[" .. table.concat(codes, ";") .. "m"
end

local function present(front, back)
    -- Diff front vs back; emit ANSI batched per contiguous run with shared attrs.
    local out = {}
    local last_sgr = nil
    local y = 1
    while y <= back.h do
        local x = 1
        while x <= back.w do
            local idx = (y - 1) * back.w + x
            local bc = back.cells[idx]
            local fc = front.cells[idx]
            if not cells_equal(fc, bc) then
                -- Begin a run: move cursor, set SGR, emit chars until break.
                out[#out+1] = "\27[" .. y .. ";" .. x .. "H"
                local sgr = sgr_for(bc)
                if sgr ~= last_sgr then out[#out+1] = sgr; last_sgr = sgr end
                out[#out+1] = bc.ch
                front.cells[idx] = { ch = bc.ch, fg = bc.fg, bg = bc.bg, attr = bc.attr }
                x = x + 1
                while x <= back.w do
                    local i2 = (y - 1) * back.w + x
                    local bc2 = back.cells[i2]
                    local fc2 = front.cells[i2]
                    if cells_equal(fc2, bc2) then break end
                    local s2 = sgr_for(bc2)
                    if s2 ~= last_sgr then out[#out+1] = s2; last_sgr = s2 end
                    out[#out+1] = bc2.ch
                    front.cells[i2] = { ch = bc2.ch, fg = bc2.fg, bg = bc2.bg, attr = bc2.attr }
                    x = x + 1
                end
            else
                x = x + 1
            end
        end
        y = y + 1
    end
    if #out > 0 then
        out[#out+1] = "\27[0m"
        io.write(table.concat(out))
        io.flush()
    end
end

-- ===== Widget base ===============================================

local function Widget(kind)
    return {
        kind        = kind,
        focusable   = false,
        focused     = false,
        on_key      = nil,
        x = 1, y = 1, w = 1, h = 1,
    }
end

-- ===== text =========================================================

function M.text(s, opts)
    opts = opts or {}
    local w = Widget("text")
    w.text = s or ""
    w.fg = opts.fg
    w.bg = opts.bg
    w.attr = opts.attr or 0
    w.align = opts.align or "left"
    w.measure = function(self) return color.visible_width(self.text), 1 end
    w.paint = function(self, region)
        local stripped = color.strip(self.text)
        local pad
        if self.align == "right" then
            pad = math.max(0, region.w - #stripped)
            region:text(pad + 1, 1, stripped, self.fg, self.bg, self.attr)
        elseif self.align == "center" then
            pad = math.max(0, math.floor((region.w - #stripped) / 2))
            region:text(pad + 1, 1, stripped, self.fg, self.bg, self.attr)
        else
            region:text(1, 1, stripped, self.fg, self.bg, self.attr)
        end
    end
    return w
end

-- ===== input ========================================================

function M.input(opts)
    opts = opts or {}
    local w = Widget("input")
    w.focusable = true
    w.value = opts.value or ""
    w.cursor = #w.value
    w.placeholder = opts.placeholder or ""
    w.on_change = opts.on_change
    w.on_submit = opts.on_submit
    w.label = opts.label
    w.measure = function(self) return opts.width or 20, 1 end
    w.paint = function(self, region)
        local visible = self.value
        if #visible == 0 and not self.focused then
            region:text(1, 1, self.placeholder, 8, nil, ATTR_DIM)
        else
            local bg = self.focused and 47 or nil  -- white bg on focus
            local fg = self.focused and 30 or nil
            region:fill(" ", fg, bg, 0)
            region:text(1, 1, visible, fg, bg, 0)
            if self.focused then
                -- Highlight cursor cell.
                local cx = math.min(self.cursor + 1, region.w)
                local ch = visible:sub(self.cursor + 1, self.cursor + 1)
                if ch == "" then ch = " " end
                region:put(cx, 1, ch, fg, bg, ATTR_INVERSE)
            end
        end
    end
    w.on_key = function(self, ev)
        if ev.name == "backspace" then
            if self.cursor > 0 then
                self.value = self.value:sub(1, self.cursor - 1) .. self.value:sub(self.cursor + 1)
                self.cursor = self.cursor - 1
                if self.on_change then self.on_change(self, self.value) end
                return true
            end
        elseif ev.name == "left" and self.cursor > 0 then
            self.cursor = self.cursor - 1
            return true
        elseif ev.name == "right" and self.cursor < #self.value then
            self.cursor = self.cursor + 1
            return true
        elseif ev.name == "home" then self.cursor = 0; return true
        elseif ev.name == "end" then self.cursor = #self.value; return true
        elseif ev.name == "enter" then
            if self.on_submit then self.on_submit(self, self.value) end
            return true
        elseif ev.char then
            self.value = self.value:sub(1, self.cursor) .. ev.char .. self.value:sub(self.cursor + 1)
            self.cursor = self.cursor + 1
            if self.on_change then self.on_change(self, self.value) end
            return true
        end
        return false
    end
    return w
end

-- ===== button =======================================================

function M.button(label, on_click)
    local w = Widget("button")
    w.focusable = true
    w.label = label
    w.on_click = on_click
    w.measure = function(self) return #self.label + 4, 1 end
    w.paint = function(self, region)
        local style_fg, style_bg = nil, nil
        if self.focused then style_fg, style_bg = 30, 46 end  -- cyan inverted
        region:fill(" ", style_fg, style_bg, 0)
        local text = "[ " .. self.label .. " ]"
        local x = math.floor((region.w - #text) / 2) + 1
        region:text(math.max(x, 1), 1, text, style_fg, style_bg, ATTR_BOLD)
    end
    w.on_key = function(self, ev)
        if ev.name == "enter" or ev.name == "space" or ev.char == " " then
            if self.on_click then self.on_click(self) end
            return true
        end
        return false
    end
    return w
end

-- ===== list =========================================================

function M.list(items, on_select)
    local w = Widget("list")
    w.focusable = true
    w.items = items or {}
    w.on_select = on_select
    w.cursor = 1
    w.scroll = 0
    w.measure = function(self)
        local mw = 0
        for _, it in ipairs(self.items) do
            local s = type(it) == "string" and it or tostring(it)
            if #s > mw then mw = #s end
        end
        return mw, math.min(#self.items, 10)
    end
    w.paint = function(self, region)
        region:fill(" ")
        for i = 1, region.h do
            local idx = self.scroll + i
            local it = self.items[idx]
            if it then
                local label = type(it) == "string" and it or tostring(it)
                if idx == self.cursor then
                    region:fill(" ", 30, 46, 0)  -- highlight bar
                    -- Re-fill only this row
                    for x = 1, region.w do region:put(x, i, " ", 30, 46, 0) end
                    region:text(2, i, "> " .. label, 30, 46, ATTR_BOLD)
                else
                    region:text(2, i, "  " .. label)
                end
            end
        end
    end
    w.on_key = function(self, ev)
        if ev.name == "up" or ev.name == "k" then
            if self.cursor > 1 then
                self.cursor = self.cursor - 1
                if self.cursor <= self.scroll then self.scroll = self.cursor - 1 end
                return true
            end
        elseif ev.name == "down" or ev.name == "j" then
            if self.cursor < #self.items then
                self.cursor = self.cursor + 1
                return true
            end
        elseif ev.name == "enter" then
            if self.on_select then self.on_select(self, self.cursor, self.items[self.cursor]) end
            return true
        end
        return false
    end
    return w
end

-- ===== table ========================================================

function M.table(rows, opts)
    opts = opts or {}
    local w = Widget("table")
    w.rows = rows or {}
    w.headers = opts.headers
    w.scroll = 0
    w.cursor = 1
    w.focusable = opts.focusable ~= false
    w.measure = function(self)
        return 60, math.min(#self.rows + (self.headers and 1 or 0), 15)
    end
    w.paint = function(self, region)
        region:fill(" ")
        -- Compute column widths once per paint.
        local n_cols = 0
        if self.headers then for i in ipairs(self.headers) do if i > n_cols then n_cols = i end end end
        for _, r in ipairs(self.rows) do
            for i in ipairs(r) do if i > n_cols then n_cols = i end end
        end
        if n_cols == 0 then return end
        local col_w = math.max(8, math.floor(region.w / n_cols) - 1)

        local row_y = 1
        if self.headers then
            for c = 1, n_cols do
                local x = (c - 1) * (col_w + 1) + 1
                local h = tostring(self.headers[c] or "")
                region:text(x, row_y, h, nil, nil, ATTR_BOLD)
            end
            row_y = row_y + 1
        end

        local visible = region.h - row_y + 1
        for i = 1, visible do
            local r = self.rows[self.scroll + i]
            if r then
                local highlight = (self.scroll + i == self.cursor)
                for c = 1, n_cols do
                    local x = (c - 1) * (col_w + 1) + 1
                    local cell = tostring(r[c] or "")
                    if #cell > col_w then cell = cell:sub(1, col_w - 3) .. "..." end
                    if highlight then
                        for xx = x, x + col_w do region:put(xx, row_y + i - 1, " ", 30, 46, 0) end
                        region:text(x, row_y + i - 1, cell, 30, 46, ATTR_BOLD)
                    else
                        region:text(x, row_y + i - 1, cell)
                    end
                end
            end
        end
    end
    w.on_key = function(self, ev)
        if ev.name == "up"   and self.cursor > 1 then self.cursor = self.cursor - 1; return true end
        if ev.name == "down" and self.cursor < #self.rows then self.cursor = self.cursor + 1; return true end
        return false
    end
    return w
end

-- ===== progress widget =============================================

function M.progress(opts)
    opts = opts or {}
    local w = Widget("progress")
    w.value = opts.value or 0
    w.total = opts.total or 100
    w.label = opts.label or ""
    w.measure = function(self) return opts.width or 30, 1 end
    w.paint = function(self, region)
        local frac = self.total > 0 and self.value / self.total or 0
        if frac > 1 then frac = 1 end
        local filled = math.floor(frac * region.w)
        for x = 1, region.w do
            if x <= filled then region:put(x, 1, "#", 32, nil, 0)
            else region:put(x, 1, "-", 8, nil, 0) end
        end
        local txt = string.format("%3d%% %s", math.floor(frac * 100), self.label)
        if #txt < region.w then
            region:text(math.floor((region.w - #txt) / 2) + 1, 1, txt, 15, nil, ATTR_BOLD)
        end
    end
    return w
end

-- ===== Layout containers ===========================================

local function paint_container(self, region)
    for _, c in ipairs(self.children) do
        if c.x and c.y and c.w > 0 and c.h > 0 then
            local sub = region:sub(c.x, c.y, c.w, c.h)
            c:paint(sub)
        end
    end
end

local function layout_vbox(self, w, h)
    self.w, self.h = w, h
    local total_fixed = 0
    local flex_count = 0
    for _, c in ipairs(self.children) do
        if c.flex then flex_count = flex_count + (c.flex or 1)
        else
            local _, ch = c:measure(w, h)
            c._req_h = ch
            total_fixed = total_fixed + ch
        end
    end
    local remaining = math.max(0, h - total_fixed)
    local per_flex = flex_count > 0 and math.floor(remaining / flex_count) or 0
    local y = 1
    for _, c in ipairs(self.children) do
        c.x = 1
        c.y = y
        c.w = w
        if c.flex then c.h = per_flex * c.flex
        else c.h = c._req_h end
        if c.layout then c:layout(c.w, c.h) end
        y = y + c.h
    end
end

function M.vbox(opts)
    opts = opts or {}
    local children = opts.children or opts
    local w = Widget("vbox")
    w.children = children
    w.measure = function(self, _w, _h)
        local max_w, sum_h = 0, 0
        for _, c in ipairs(self.children) do
            local cw, ch = c:measure(_w, _h)
            if cw > max_w then max_w = cw end
            sum_h = sum_h + ch
        end
        return max_w, sum_h
    end
    w.layout = layout_vbox
    w.paint = paint_container
    return w
end

local function layout_hbox(self, w, h)
    self.w, self.h = w, h
    local total_fixed = 0
    local flex_count = 0
    for _, c in ipairs(self.children) do
        if c.flex then flex_count = flex_count + (c.flex or 1)
        else
            local cw = (c:measure(w, h))
            c._req_w = cw
            total_fixed = total_fixed + cw
        end
    end
    local remaining = math.max(0, w - total_fixed)
    local per_flex = flex_count > 0 and math.floor(remaining / flex_count) or 0
    local x = 1
    for _, c in ipairs(self.children) do
        c.y = 1
        c.x = x
        c.h = h
        if c.flex then c.w = per_flex * c.flex
        else c.w = c._req_w end
        if c.layout then c:layout(c.w, c.h) end
        x = x + c.w
    end
end

function M.hbox(opts)
    opts = opts or {}
    local children = opts.children or opts
    local w = Widget("hbox")
    w.children = children
    w.measure = function(self, _w, _h)
        local sum_w, max_h = 0, 0
        for _, c in ipairs(self.children) do
            local cw, ch = c:measure(_w, _h)
            sum_w = sum_w + cw
            if ch > max_h then max_h = ch end
        end
        return sum_w, max_h
    end
    w.layout = layout_hbox
    w.paint = paint_container
    return w
end

function M.grid(spec)
    -- spec = { rows, cols, cells } where cells is row-major array.
    -- All cells get equal weight; for non-uniform layouts use vbox-of-hbox.
    local rows, cols, cells = spec.rows, spec.cols, spec.cells
    local w = Widget("grid")
    w.children = cells
    w.rows = rows
    w.cols = cols
    w.measure = function(self, _w, _h) return _w, _h end
    w.layout = function(self, _w, _h)
        local cw = math.floor(_w / cols)
        local ch = math.floor(_h / rows)
        for i, c in ipairs(self.children) do
            local r = math.floor((i - 1) / cols)
            local col = (i - 1) % cols
            c.x = col * cw + 1
            c.y = r * ch + 1
            c.w = cw
            c.h = ch
            if c.layout then c:layout(c.w, c.h) end
        end
    end
    w.paint = paint_container
    return w
end

-- Per-style border glyphs. ASCII is the default; pass opts.style="line"|"heavy"
-- to opt into box-drawing characters.
local _BORDER_STYLES = {
    ascii = { tl="+", tr="+", bl="+", br="+", h="-", v="|" },
    line  = { tl="\u{250c}", tr="\u{2510}", bl="\u{2514}", br="\u{2518}",
              h="\u{2500}", v="\u{2502}" },
    heavy = { tl="\u{250f}", tr="\u{2513}", bl="\u{2517}", br="\u{251b}",
              h="\u{2501}", v="\u{2503}" },
    double = { tl="\u{2554}", tr="\u{2557}", bl="\u{255a}", br="\u{255d}",
               h="\u{2550}", v="\u{2551}" },
}

function M.border(child, opts)
    opts = opts or {}
    local glyphs = _BORDER_STYLES[opts.style or "ascii"] or _BORDER_STYLES.ascii
    local w = Widget("border")
    w.children = { child }
    w.title = opts.title
    w.measure = function(self, _w, _h)
        local cw, ch = child:measure((_w or 80) - 2, (_h or 24) - 2)
        return cw + 2, ch + 2
    end
    w.layout = function(self, _w, _h)
        self.w, self.h = _w, _h
        child.x = 2; child.y = 2
        child.w = _w - 2; child.h = _h - 2
        if child.layout then child:layout(child.w, child.h) end
    end
    w.paint = function(self, region)
        region:put(1, 1, glyphs.tl)
        region:put(region.w, 1, glyphs.tr)
        region:put(1, region.h, glyphs.bl)
        region:put(region.w, region.h, glyphs.br)
        for x = 2, region.w - 1 do
            region:put(x, 1, glyphs.h)
            region:put(x, region.h, glyphs.h)
        end
        for y = 2, region.h - 1 do
            region:put(1, y, glyphs.v)
            region:put(region.w, y, glyphs.v)
        end
        if self.title then
            region:text(3, 1, " " .. self.title .. " ", nil, nil, ATTR_BOLD)
        end
        local inner = region:sub(2, 2, region.w - 2, region.h - 2)
        child:paint(inner)
    end
    return w
end

-- ===== Focus management ===========================================

local function collect_focusable(widget, out)
    out = out or {}
    if widget.focusable then out[#out+1] = widget end
    if widget.children then
        for _, c in ipairs(widget.children) do collect_focusable(c, out) end
    end
    return out
end

-- ===== Screen =====================================================

local Screen = {}
Screen.__index = Screen

function M.screen(opts)
    opts = opts or {}
    local cols, rows = term.size()
    return setmetatable({
        root        = nil,
        front       = new_buffer(cols, rows),
        back        = new_buffer(cols, rows),
        running     = false,
        dirty       = true,
        focus_chain = {},
        focus_idx   = 1,
        on_key      = opts.on_key,    -- global key handler (returns true to consume)
        cols        = cols,
        rows        = rows,
    }, Screen)
end

function Screen:add(widget)
    self.root = widget
    self.focus_chain = collect_focusable(widget)
    self.focus_idx = 1
    if self.focus_chain[1] then self.focus_chain[1].focused = true end
    self.dirty = true
end

function Screen:invalidate() self.dirty = true end

function Screen:focus_next()
    if #self.focus_chain == 0 then return end
    self.focus_chain[self.focus_idx].focused = false
    self.focus_idx = self.focus_idx % #self.focus_chain + 1
    self.focus_chain[self.focus_idx].focused = true
    self.dirty = true
end

function Screen:focus_prev()
    if #self.focus_chain == 0 then return end
    self.focus_chain[self.focus_idx].focused = false
    self.focus_idx = (self.focus_idx - 2) % #self.focus_chain + 1
    self.focus_chain[self.focus_idx].focused = true
    self.dirty = true
end

local function resize_if_needed(self)
    local cols, rows = term.size()
    if cols ~= self.cols or rows ~= self.rows then
        self.cols, self.rows = cols, rows
        self.front = new_buffer(cols, rows)
        self.back = new_buffer(cols, rows)
        self.dirty = true
    end
end

function Screen:_render()
    if not self.dirty or not self.root then return end
    buf_clear(self.back)
    if self.root.layout then self.root:layout(self.cols, self.rows)
    else
        self.root.x = 1; self.root.y = 1
        self.root.w = self.cols; self.root.h = self.rows
    end
    local region = make_region(self.back, 1, 1, self.cols, self.rows)
    self.root:paint(region)
    present(self.front, self.back)
    self.dirty = false
end

function Screen:run()
    color.enable()
    term.enter_alt_screen()
    term.hide_cursor()
    keyboard.enable_raw_mode()
    self.running = true

    -- Force first paint to draw the whole screen by leaving front as the
    -- default-init (all spaces, no attrs) vs back which the widgets just
    -- filled.
    local ok, err = pcall(function()
        while self.running do
            resize_if_needed(self)
            self:_render()
            local ev = keyboard.read_key(50)  -- 50ms tick so we can re-check resize
            if ev then
                local handled = false
                if self.on_key then handled = self.on_key(ev) end
                if not handled then
                    if ev.name == "tab" then self:focus_next(); handled = true
                    elseif ev.name == "tab" and ev.shift then self:focus_prev(); handled = true
                    elseif ev.ctrl and ev.name == "c" then self.running = false; handled = true
                    end
                end
                if not handled and self.focus_chain[self.focus_idx] then
                    local f = self.focus_chain[self.focus_idx]
                    if f.on_key and f:on_key(ev) then self.dirty = true end
                end
            end
        end
    end)

    keyboard.disable_raw_mode()
    term.show_cursor()
    term.leave_alt_screen()
    if not ok then error(err, 0) end
end

function Screen:stop() self.running = false end

return M
