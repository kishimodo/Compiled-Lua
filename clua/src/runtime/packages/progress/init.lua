-- progress -- Progress bars and spinners with ETA tracking.
--
-- Public surface:
--   progress.bar(opts?)     -> bar    -- :set(n, total?), :inc(n?), :finish(), :fail(msg?), :tick(msg?)
--   progress.spinner(opts?) -> sp     -- :start(msg), :update(msg), :stop(ok_msg), :fail(msg)
--   progress.multi()        -> mgr    -- :bar(opts) registers a slot; bars repaint to fixed rows
--
-- bar opts:
--   total       -- target value (default 100)
--   width       -- glyph cells in the bar (default 40)
--   format      -- format string with {bar} {percent} {value} {total} {rate} {eta} {elapsed} {msg}
--   fill, empty -- bar glyphs (default ASCII "#" / "-"; pass "\u{2588}" / "\u{2591}" for unicode)
--   stream      -- io stream (default io.stderr -- so the bar doesn't pollute piped stdout)
--   throttle_ms -- minimum repaint interval (default 50)
--
-- ETA uses an exponential moving average of rate (units/sec) so brief stalls
-- don't whiplash the estimate.

local color = require "color"

local M = {}

-- Reuse the windows package for a high-resolution monotonic clock. We use
-- GetTickCount64 (millisecond resolution) -- plenty for UI updates and free
-- of the float drift that os.clock() has under JIT.
local function now_ms()
    return tonumber(ffi.C.GetTickCount64())
end

local DEFAULT_FORMAT = "{bar} {percent}% [{value}/{total}] {rate} {eta} {msg}"

-- ===== Format helpers ===============================================

local function fmt_duration(ms)
    if not ms or ms < 0 or ms ~= ms then return "--:--" end
    local s = math.floor(ms / 1000)
    local h = math.floor(s / 3600)
    local m = math.floor((s % 3600) / 60)
    s = s % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%02d:%02d", m, s)
end

local function fmt_rate(units_per_sec)
    if not units_per_sec or units_per_sec <= 0 then return "0/s" end
    if units_per_sec >= 1e6 then return string.format("%.1fM/s", units_per_sec / 1e6) end
    if units_per_sec >= 1e3 then return string.format("%.1fk/s", units_per_sec / 1e3) end
    if units_per_sec >= 10  then return string.format("%d/s", math.floor(units_per_sec)) end
    return string.format("%.1f/s", units_per_sec)
end

-- ===== Bar ==========================================================

local Bar = {}
Bar.__index = Bar

function M.bar(opts)
    opts = opts or {}
    local self = setmetatable({
        total       = opts.total or 100,
        width       = opts.width or 40,
        format      = opts.format or DEFAULT_FORMAT,
        fill        = opts.fill  or "#",
        empty       = opts.empty or "-",
        stream      = opts.stream or io.stderr,
        throttle_ms = opts.throttle_ms or 50,
        value       = 0,
        msg         = opts.msg or "",
        started_at  = now_ms(),
        last_paint  = 0,
        ema_rate    = nil,
        ema_alpha   = opts.ema_alpha or 0.2,
        finished    = false,
        line_index  = opts.line_index,    -- multi-bar slot row
        _last_value = 0,
        _last_t     = now_ms(),
    }, Bar)
    return self
end

function Bar:_render()
    local pct = self.total > 0 and (self.value / self.total) or 0
    if pct > 1 then pct = 1 end
    local filled = math.floor(pct * self.width)
    local bar = string.rep(self.fill, filled) .. string.rep(self.empty, self.width - filled)
    local elapsed = now_ms() - self.started_at
    local eta_ms
    if self.ema_rate and self.ema_rate > 0 then
        local remain = self.total - self.value
        if remain <= 0 then eta_ms = 0
        else eta_ms = remain / self.ema_rate * 1000 end
    end
    local subs = {
        bar      = bar,
        percent  = string.format("%3d", math.floor(pct * 100)),
        value    = tostring(self.value),
        total    = tostring(self.total),
        rate     = fmt_rate(self.ema_rate or 0),
        eta      = fmt_duration(eta_ms),
        elapsed  = fmt_duration(elapsed),
        msg      = self.msg or "",
    }
    return (self.format:gsub("{(%w+)}", subs))
end

function Bar:_paint(force)
    local t = now_ms()
    if not force and (t - self.last_paint) < self.throttle_ms then return end
    self.last_paint = t
    local line = self:_render()
    if self.line_index then
        -- Multi-bar mode: jump to the slot, repaint, return.
        local term = require "term"
        term.save_pos()
        term.move(1, self.line_index)
        self.stream:write("\27[2K" .. line)
        term.restore_pos()
        self.stream:flush()
    else
        self.stream:write("\r\27[2K" .. line)
        self.stream:flush()
    end
end

function Bar:_update_rate()
    local t = now_ms()
    local dt = t - self._last_t
    if dt < 50 then return end  -- too noisy under 50 ms windows
    local dv = self.value - self._last_value
    local instantaneous = dv / (dt / 1000)
    if self.ema_rate == nil then
        self.ema_rate = instantaneous
    else
        self.ema_rate = self.ema_alpha * instantaneous + (1 - self.ema_alpha) * self.ema_rate
    end
    self._last_t = t
    self._last_value = self.value
end

function Bar:set(n, total)
    if total then self.total = total end
    self.value = n
    self:_update_rate()
    self:_paint(false)
end

function Bar:inc(n)
    self.value = self.value + (n or 1)
    self:_update_rate()
    self:_paint(false)
end

function Bar:tick(msg)
    if msg then self.msg = msg end
    self:_paint(false)
end

function Bar:finish(msg)
    self.value = self.total
    if msg then self.msg = msg end
    self:_paint(true)
    self.stream:write("\n")
    self.stream:flush()
    self.finished = true
end

function Bar:fail(msg)
    if msg then self.msg = color.red(msg) end
    self:_paint(true)
    self.stream:write("\n")
    self.stream:flush()
    self.finished = true
end

-- ===== Spinner ======================================================

-- ASCII default rotates through |/-\; pass opts.frames for unicode braille
-- spinners (the "\u{280b}"..."\u{280f}" set works well in modern terminals).
local DEFAULT_FRAMES = { "|", "/", "-", "\\" }

M.FRAMES_BRAILLE = { "\u{280b}", "\u{2819}", "\u{2839}", "\u{2838}",
                      "\u{283c}", "\u{2834}", "\u{2826}", "\u{2827}",
                      "\u{2807}", "\u{280f}" }
M.FRAMES_LINE    = { "|", "/", "-", "\\" }
M.FRAMES_DOTS    = { ".  ", ".. ", "...", " ..", "  .", "   " }
M.FRAMES_ARROW   = { "<", "^", ">", "v" }
M.FRAMES_BAR     = { "[=   ]", "[==  ]", "[=== ]", "[ ===]", "[  ==]", "[   =]", "[    ]" }
M.FRAMES_PULSE   = { ".", "o", "O", "o" }

local Spinner = {}
Spinner.__index = Spinner

function M.spinner(opts)
    opts = opts or {}
    return setmetatable({
        frames     = opts.frames or DEFAULT_FRAMES,
        interval_ms = opts.interval_ms or 80,
        stream     = opts.stream or io.stderr,
        idx        = 1,
        msg        = "",
        last_paint = 0,
        running    = false,
    }, Spinner)
end

function Spinner:_paint(force)
    local t = now_ms()
    if not force and (t - self.last_paint) < self.interval_ms then return end
    self.last_paint = t
    self.idx = (self.idx % #self.frames) + 1
    self.stream:write("\r\27[2K" .. self.frames[self.idx] .. " " .. self.msg)
    self.stream:flush()
end

function Spinner:start(msg)
    self.msg = msg or ""
    self.running = true
    self:_paint(true)
end

-- update() advances the frame -- callers from a tight loop get animation
-- without spawning a thread. Throttling means it's safe to call every iter.
function Spinner:update(msg)
    if msg then self.msg = msg end
    if self.running then self:_paint(false) end
end

function Spinner:stop(ok_msg)
    self.running = false
    self.stream:write("\r\27[2K" .. (ok_msg and (color.green("[+] ") .. ok_msg) or "") .. "\n")
    self.stream:flush()
end

function Spinner:fail(msg)
    self.running = false
    self.stream:write("\r\27[2K" .. color.red("[-] ") .. (msg or "") .. "\n")
    self.stream:flush()
end

-- ===== Multi-bar manager ============================================
-- Bars occupy fixed rows below the current cursor. The manager remembers
-- where to repaint each one so they don't fight over \r.

local Multi = {}
Multi.__index = Multi

function M.multi(opts)
    opts = opts or {}
    -- Reserve N rows from current cursor position. We don't know "current"
    -- until the user starts adding bars; the first add prints blank lines
    -- and remembers the resulting top row.
    return setmetatable({
        stream   = opts.stream or io.stderr,
        bars     = {},
        anchor   = nil,
    }, Multi)
end

function Multi:bar(opts)
    opts = opts or {}
    -- Print a blank line to reserve a row; the next size() query is unreliable
    -- inside the same write batch, so we use the count of existing bars to
    -- compute the slot index relative to "current row minus N".
    self.stream:write("\n")
    self.stream:flush()
    local slot = #self.bars + 1
    opts.stream = self.stream
    -- Defer the absolute row resolution to first paint by leaving line_index
    -- as a function. Simpler: track via a fixed offset from cursor at time of
    -- creation by querying term.size + cursor via a save/restore probe.
    -- For CLua's typical batched terminals, treating bars as a vertical
    -- stack anchored to "current cursor at time of multi()" is reliable.
    local term = require "term"
    if not self.anchor then
        -- Approximate: anchor to bottom rows of viewport.
        local _, h = term.size()
        self.anchor = h - 10  -- reserve up to 10 rows above the bottom
        if self.anchor < 1 then self.anchor = 1 end
    end
    opts.line_index = self.anchor + slot - 1
    local b = M.bar(opts)
    self.bars[slot] = b
    return b
end

-- ===== Auto-progress iterator =======================================
-- Wraps an array iteration with a progress bar that ticks per step.
-- Usage: for i, v in progress.iter(items, { msg = "scanning" }) do ... end

function M.iter(t, opts)
    opts = opts or {}
    opts.total = opts.total or #t
    local b = M.bar(opts)
    local i = 0
    local n = #t
    return function()
        i = i + 1
        if i > n then
            b:finish(opts.done_msg)
            return nil
        end
        b:set(i)
        return i, t[i]
    end
end

return M
