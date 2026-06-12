-- timer -- stopwatches + periodic / one-shot scheduling.
--
-- Public surface:
--   timer.stopwatch()              -> sw
--   timer.oneshot(delay_ms, fn)    -> handle (cancellable)
--   timer.interval(period_ms, fn, opts?) -> handle  (opts.immediate)
--   timer.after(seconds, fn)       -> handle   (shorthand for oneshot)
--   timer.every(seconds, fn)       -> handle   (shorthand for interval)
--   timer.tick(period_seconds)     -> iterator yielding monotonic timestamps
--   timer.poll()                   -> n_fired   -- run due callbacks once
--   timer.run_forever()            -- block + poll until no timers remain
--   timer.sleep_until_next()       -- sleep up to the earliest deadline
--   timer.next_deadline()          -> seconds-from-now or nil
--   timer.count()                  -> number of active scheduled timers
--   timer.cancel_all()
--
-- Stopwatch (sw):
--   sw:start()         -- (re)start the clock. Does nothing if already running.
--   sw:stop()          -- pauses and accumulates elapsed time.
--   sw:reset()         -- clears all accumulation and laps.
--   sw:lap()           -> seconds since the last lap (or :start)
--   sw:elapsed()       -> total accumulated seconds
--   sw:elapsed_ms()    -> total ms (integer)
--   sw:elapsed_ns()    -> total ns (int64)
--   sw:laps()          -> array of lap durations (seconds)
--   sw:is_running()    -> bool
--
-- Scheduling design:
--   We keep a Lua-side binary min-heap of pending handles. Callbacks run
--   on the LuaVM main thread (no Win32 worker threads touching Lua
--   state). poll() drains everything that's due now. run_forever()
--   alternates poll/sleep until the heap empties.

require "windows"
local time = require "time"

local M = {}
local floor = math.floor

-- ===== Stopwatch ======================================================

local Stopwatch = {}
Stopwatch.__index = Stopwatch

function M.stopwatch()
    return setmetatable({
        running_   = false,
        start_     = 0,        -- monotonic at last start
        accum_     = 0,        -- accumulated seconds while not running
        lap_mark_  = 0,        -- monotonic at last lap/start
        laps_      = {},
    }, Stopwatch)
end

function Stopwatch:start()
    if self.running_ then return self end
    local now = time.monotonic()
    self.start_    = now
    self.lap_mark_ = now
    self.running_  = true
    return self
end

function Stopwatch:stop()
    if not self.running_ then return self end
    local now = time.monotonic()
    self.accum_   = self.accum_ + (now - self.start_)
    self.running_ = false
    return self
end

function Stopwatch:reset()
    self.running_   = false
    self.start_     = 0
    self.accum_     = 0
    self.lap_mark_  = 0
    self.laps_      = {}
    return self
end

function Stopwatch:lap()
    local now = time.monotonic()
    local lap
    if self.running_ then
        lap = now - self.lap_mark_
        self.lap_mark_ = now
    else
        lap = 0
    end
    self.laps_[#self.laps_ + 1] = lap
    return lap
end

function Stopwatch:laps()
    local out = {}
    for i = 1, #self.laps_ do out[i] = self.laps_[i] end
    return out
end

function Stopwatch:is_running() return self.running_ end

function Stopwatch:elapsed()
    if self.running_ then
        return self.accum_ + (time.monotonic() - self.start_)
    end
    return self.accum_
end

function Stopwatch:elapsed_ms() return floor(self:elapsed() * 1000) end
function Stopwatch:elapsed_ns() return math.floor(self:elapsed() * 1e9) end

M.Stopwatch = Stopwatch

-- ===== Scheduler heap =================================================

local heap = {}
local heap_n = 0
local id_seq = 0

local function heap_swap(i, j)
    heap[i], heap[j] = heap[j], heap[i]
    heap[i].heap_idx_ = i
    heap[j].heap_idx_ = j
end

local function heap_up(i)
    while i > 1 do
        local p = i >> 1
        if heap[p].when_ > heap[i].when_ then heap_swap(p, i); i = p else break end
    end
end

local function heap_down(i)
    while true do
        local l, r = i * 2, i * 2 + 1
        local best = i
        if l <= heap_n and heap[l].when_ < heap[best].when_ then best = l end
        if r <= heap_n and heap[r].when_ < heap[best].when_ then best = r end
        if best == i then break end
        heap_swap(i, best); i = best
    end
end

local function heap_push(t)
    heap_n = heap_n + 1
    heap[heap_n]   = t
    t.heap_idx_    = heap_n
    heap_up(heap_n)
end

local function heap_remove(i)
    if i > heap_n then return end
    if i == heap_n then heap[heap_n] = nil; heap_n = heap_n - 1; return end
    heap_swap(i, heap_n)
    heap[heap_n] = nil; heap_n = heap_n - 1
    heap_up(i); heap_down(i)
end

local function heap_pop()
    if heap_n == 0 then return nil end
    local top = heap[1]
    top.heap_idx_ = nil
    if heap_n == 1 then heap[1] = nil; heap_n = 0; return top end
    heap[1] = heap[heap_n]
    heap[1].heap_idx_ = 1
    heap[heap_n] = nil
    heap_n = heap_n - 1
    heap_down(1)
    return top
end

-- ===== Handle =========================================================

local Handle = {}
Handle.__index = Handle

function Handle:cancel()
    if self.cancelled_ then return end
    self.cancelled_ = true
    if self.heap_idx_ then
        heap_remove(self.heap_idx_)
        self.heap_idx_ = nil
    end
end

function Handle:active()
    return not self.cancelled_ and self.heap_idx_ ~= nil
end

function Handle:next_fire()
    if not self.heap_idx_ then return nil end
    return self.when_ - time.monotonic()
end

local function new_handle(when, fn, period)
    id_seq = id_seq + 1
    return setmetatable({
        id_        = id_seq,
        when_      = when,
        fn_        = fn,
        period_    = period,
        cancelled_ = false,
    }, Handle)
end

-- ===== Scheduling API =================================================

function M.oneshot(delay_ms, fn)
    if type(delay_ms) ~= "number" then error("timer.oneshot: delay_ms must be number") end
    if type(fn) ~= "function" then error("timer.oneshot: fn must be function") end
    local h = new_handle(time.monotonic() + delay_ms / 1000, fn, nil)
    heap_push(h)
    return h
end

function M.interval(period_ms, fn, opts)
    if type(period_ms) ~= "number" or period_ms <= 0 then
        error("timer.interval: period_ms must be > 0")
    end
    if type(fn) ~= "function" then error("timer.interval: fn must be function") end
    opts = opts or {}
    local first_at
    if opts.immediate then
        first_at = time.monotonic()
    else
        first_at = time.monotonic() + period_ms / 1000
    end
    local h = new_handle(first_at, fn, period_ms / 1000)
    heap_push(h)
    return h
end

function M.after(seconds, fn)  return M.oneshot(seconds * 1000, fn) end
function M.every(seconds, fn)  return M.interval(seconds * 1000, fn) end

function M.tick(period_seconds)
    if not period_seconds or period_seconds <= 0 then
        error("timer.tick: period must be > 0")
    end
    local next_at = time.monotonic() + period_seconds
    return function()
        local now = time.monotonic()
        if now < next_at then time.sleep(next_at - now) end
        local t = time.monotonic()
        next_at = next_at + period_seconds
        -- Catch up if we fell behind so ticks stay aligned.
        while next_at <= t do next_at = next_at + period_seconds end
        return t
    end
end

function M.count() return heap_n end

function M.next_deadline()
    if heap_n == 0 then return nil end
    return heap[1].when_ - time.monotonic()
end

function M.poll()
    local fired = 0
    while heap_n > 0 do
        local now = time.monotonic()
        if heap[1].when_ > now then break end
        local h = heap_pop()
        if not h.cancelled_ then
            if h.period_ then
                h.when_ = h.when_ + h.period_
                while h.when_ <= now do h.when_ = h.when_ + h.period_ end
                heap_push(h)
            end
            local ok, err = pcall(h.fn_)
            fired = fired + 1
            if not ok and M.on_error then pcall(M.on_error, err, h) end
        end
    end
    return fired
end

function M.sleep_until_next()
    local d = M.next_deadline()
    if not d then return end
    if d > 0 then time.sleep(d) end
end

function M.run_forever()
    while heap_n > 0 do
        M.poll()
        if heap_n == 0 then break end
        M.sleep_until_next()
    end
end

function M.cancel_all()
    for i = 1, heap_n do
        heap[i].cancelled_ = true
        heap[i].heap_idx_  = nil
        heap[i] = nil
    end
    heap_n = 0
end

return M
