-- rate_limit -- token bucket, leaky bucket, sliding window, fixed window.
--
-- Public surface:
--   rate_limit.token_bucket(opts?)     -> rl
--   rate_limit.leaky_bucket(opts?)     -> rl
--   rate_limit.sliding_window(opts?)   -> rl
--   rate_limit.fixed_window(opts?)     -> rl
--   rate_limit.keyed(make_limiter_fn)  -> klr
--
-- Each limiter (`rl`) exposes:
--   rl:take(n?)         -> ok (bool), retry_after_ms (number)
--   rl:available()      -> number of tokens / capacity remaining
--   rl:wait(n?, timeout_ms?)  -> ok (bool)  -- blocks; returns false if timeout hit
--   rl:reset()
--
-- Per-key limiter (`klr`):
--   klr:take(key, n?)         -> ok, retry_after_ms
--   klr:available(key)        -> remaining
--   klr:wait(key, n?, timeout_ms?) -> ok
--   klr:reset(key?)           -- one key or all
--
-- All limiters use time.monotonic() so a wallclock jump doesn't break them.
-- Mutex integration is best-effort: if the "mutex" package is available
-- we wrap state updates in a lock; otherwise we run lock-free (correct
-- under a single OS thread, which is what LuaVM provides today).

local time = require "time"

local _has_mutex, _mutex_mod = pcall(require, "mutex")
local function new_lock()
    if _has_mutex and _mutex_mod and _mutex_mod.new then
        return _mutex_mod.new()
    end
    -- No-op lock.
    return {
        lock   = function() end,
        unlock = function() end,
    }
end

local M = {}

local function with_lock(self, fn, ...)
    if self.lock_ then self.lock_:lock() end
    local ok, r1, r2 = pcall(fn, self, ...)
    if self.lock_ then self.lock_:unlock() end
    if not ok then error(r1) end
    return r1, r2
end

-- ===== Token bucket ===================================================
--
-- opts = {
--   capacity         -- max tokens (default 10)
--   refill_rate      -- tokens added per interval (default 1)
--   refill_interval_ms -- interval length in ms (default 1000)
-- }

local TB = {}
TB.__index = TB

function M.token_bucket(opts)
    opts = opts or {}
    local capacity        = opts.capacity or 10
    local refill_rate     = opts.refill_rate or 1
    local refill_interval = (opts.refill_interval_ms or 1000) / 1000  -- s
    if capacity <= 0 then error("token_bucket: capacity must be > 0") end
    if refill_rate <= 0 then error("token_bucket: refill_rate must be > 0") end
    if refill_interval <= 0 then error("token_bucket: refill_interval_ms must be > 0") end
    return setmetatable({
        capacity_ = capacity,
        rate_s_   = refill_rate / refill_interval,   -- tokens/sec
        tokens_   = capacity,
        last_     = time.monotonic(),
        lock_     = new_lock(),
    }, TB)
end

local function tb_refill(self)
    local now = time.monotonic()
    local elapsed = now - self.last_
    if elapsed > 0 then
        local add = elapsed * self.rate_s_
        local nt = self.tokens_ + add
        if nt > self.capacity_ then nt = self.capacity_ end
        self.tokens_ = nt
        self.last_   = now
    end
end

function TB:take(n)
    n = n or 1
    return with_lock(self, function(self)
        tb_refill(self)
        if self.tokens_ >= n then
            self.tokens_ = self.tokens_ - n
            return true, 0
        end
        local deficit = n - self.tokens_
        local wait_s = deficit / self.rate_s_
        return false, math.ceil(wait_s * 1000)
    end)
end

function TB:available()
    return with_lock(self, function(self)
        tb_refill(self)
        return self.tokens_
    end)
end

function TB:wait(n, timeout_ms)
    n = n or 1
    local deadline = timeout_ms and (time.monotonic() + timeout_ms / 1000) or nil
    while true do
        local ok, retry_ms = self:take(n)
        if ok then return true end
        local wait_s = retry_ms / 1000
        if deadline then
            local remaining = deadline - time.monotonic()
            if remaining <= 0 then return false end
            if wait_s > remaining then wait_s = remaining end
        end
        time.sleep(wait_s)
    end
end

function TB:reset()
    with_lock(self, function(self)
        self.tokens_ = self.capacity_
        self.last_   = time.monotonic()
    end)
end

-- ===== Leaky bucket ===================================================
--
-- opts = {
--   capacity      -- max queued volume (default 10)
--   leak_rate     -- volume drained per interval (default 1)
--   leak_interval_ms -- interval length in ms (default 1000)
-- }
--
-- We model "level" as the current queued volume. take(n) adds n to the
-- level and succeeds if the result fits under capacity; if not, the
-- caller is told to retry after the time the bucket needs to drain to
-- accommodate the request.

local LB = {}
LB.__index = LB

function M.leaky_bucket(opts)
    opts = opts or {}
    local capacity = opts.capacity or 10
    local leak_rate = opts.leak_rate or 1
    local leak_interval = (opts.leak_interval_ms or 1000) / 1000
    if capacity <= 0 then error("leaky_bucket: capacity must be > 0") end
    if leak_rate <= 0 then error("leaky_bucket: leak_rate must be > 0") end
    return setmetatable({
        capacity_ = capacity,
        rate_s_   = leak_rate / leak_interval,
        level_    = 0,
        last_     = time.monotonic(),
        lock_     = new_lock(),
    }, LB)
end

local function lb_leak(self)
    local now = time.monotonic()
    local elapsed = now - self.last_
    if elapsed > 0 then
        local drained = elapsed * self.rate_s_
        self.level_ = self.level_ - drained
        if self.level_ < 0 then self.level_ = 0 end
        self.last_  = now
    end
end

function LB:take(n)
    n = n or 1
    return with_lock(self, function(self)
        lb_leak(self)
        if self.level_ + n <= self.capacity_ then
            self.level_ = self.level_ + n
            return true, 0
        end
        local overflow = (self.level_ + n) - self.capacity_
        local wait_s = overflow / self.rate_s_
        return false, math.ceil(wait_s * 1000)
    end)
end

function LB:available()
    return with_lock(self, function(self)
        lb_leak(self)
        return self.capacity_ - self.level_
    end)
end

function LB:wait(n, timeout_ms)
    n = n or 1
    local deadline = timeout_ms and (time.monotonic() + timeout_ms / 1000) or nil
    while true do
        local ok, retry_ms = self:take(n)
        if ok then return true end
        local wait_s = retry_ms / 1000
        if deadline then
            local remaining = deadline - time.monotonic()
            if remaining <= 0 then return false end
            if wait_s > remaining then wait_s = remaining end
        end
        time.sleep(wait_s)
    end
end

function LB:reset()
    with_lock(self, function(self)
        self.level_ = 0
        self.last_  = time.monotonic()
    end)
end

-- ===== Sliding window =================================================
--
-- opts = { max_requests, window_ms }
-- Tracks per-event timestamps and trims anything older than the window.
-- take(n) succeeds if (events_in_window + n) <= max_requests.

local SW = {}
SW.__index = SW

function M.sliding_window(opts)
    opts = opts or {}
    local max_req = opts.max_requests or 100
    local window  = (opts.window_ms or 60000) / 1000
    if max_req <= 0 then error("sliding_window: max_requests must be > 0") end
    if window <= 0 then error("sliding_window: window_ms must be > 0") end
    return setmetatable({
        max_     = max_req,
        window_  = window,
        events_  = {},     -- circular log of monotonic timestamps
        head_    = 1,
        tail_    = 0,
        size_    = 0,
        lock_    = new_lock(),
    }, SW)
end

local function sw_trim(self, now)
    local cutoff = now - self.window_
    while self.size_ > 0 and self.events_[self.head_] <= cutoff do
        self.events_[self.head_] = nil
        self.head_ = self.head_ + 1
        self.size_ = self.size_ - 1
    end
end

function SW:take(n)
    n = n or 1
    return with_lock(self, function(self)
        local now = time.monotonic()
        sw_trim(self, now)
        if self.size_ + n > self.max_ then
            -- Retry after the oldest event ages out.
            local oldest = self.events_[self.head_]
            if oldest == nil then return false, 0 end
            local wait_s = (oldest + self.window_) - now
            if wait_s < 0 then wait_s = 0 end
            return false, math.ceil(wait_s * 1000)
        end
        for _ = 1, n do
            self.tail_ = self.tail_ + 1
            self.events_[self.tail_] = now
            self.size_ = self.size_ + 1
        end
        return true, 0
    end)
end

function SW:available()
    return with_lock(self, function(self)
        sw_trim(self, time.monotonic())
        return self.max_ - self.size_
    end)
end

function SW:wait(n, timeout_ms)
    n = n or 1
    local deadline = timeout_ms and (time.monotonic() + timeout_ms / 1000) or nil
    while true do
        local ok, retry_ms = self:take(n)
        if ok then return true end
        local wait_s = retry_ms / 1000
        if deadline then
            local remaining = deadline - time.monotonic()
            if remaining <= 0 then return false end
            if wait_s > remaining then wait_s = remaining end
        end
        if wait_s <= 0 then wait_s = 0.001 end
        time.sleep(wait_s)
    end
end

function SW:reset()
    with_lock(self, function(self)
        self.events_ = {}
        self.head_ = 1; self.tail_ = 0; self.size_ = 0
    end)
end

-- ===== Fixed window ===================================================
--
-- opts = { max_requests, window_ms }
-- The window starts at the first take() and re-arms when the window ms
-- has elapsed. Simpler / cheaper than sliding_window; bursty at window
-- boundaries by design.

local FW = {}
FW.__index = FW

function M.fixed_window(opts)
    opts = opts or {}
    local max_req = opts.max_requests or 100
    local window  = (opts.window_ms or 60000) / 1000
    if max_req <= 0 then error("fixed_window: max_requests must be > 0") end
    if window <= 0 then error("fixed_window: window_ms must be > 0") end
    return setmetatable({
        max_     = max_req,
        window_  = window,
        count_   = 0,
        start_   = time.monotonic(),
        lock_    = new_lock(),
    }, FW)
end

local function fw_rotate(self, now)
    if (now - self.start_) >= self.window_ then
        self.start_ = now
        self.count_ = 0
    end
end

function FW:take(n)
    n = n or 1
    return with_lock(self, function(self)
        local now = time.monotonic()
        fw_rotate(self, now)
        if self.count_ + n > self.max_ then
            local wait_s = (self.start_ + self.window_) - now
            if wait_s < 0 then wait_s = 0 end
            return false, math.ceil(wait_s * 1000)
        end
        self.count_ = self.count_ + n
        return true, 0
    end)
end

function FW:available()
    return with_lock(self, function(self)
        fw_rotate(self, time.monotonic())
        return self.max_ - self.count_
    end)
end

function FW:wait(n, timeout_ms)
    n = n or 1
    local deadline = timeout_ms and (time.monotonic() + timeout_ms / 1000) or nil
    while true do
        local ok, retry_ms = self:take(n)
        if ok then return true end
        local wait_s = retry_ms / 1000
        if deadline then
            local remaining = deadline - time.monotonic()
            if remaining <= 0 then return false end
            if wait_s > remaining then wait_s = remaining end
        end
        if wait_s <= 0 then wait_s = 0.001 end
        time.sleep(wait_s)
    end
end

function FW:reset()
    with_lock(self, function(self)
        self.count_ = 0
        self.start_ = time.monotonic()
    end)
end

-- ===== Keyed limiter ==================================================
--
-- A wrapper that lazily constructs one underlying limiter per key.

local Keyed = {}
Keyed.__index = Keyed

function M.keyed(make_limiter)
    if type(make_limiter) ~= "function" then
        error("rate_limit.keyed: expected a function that builds a limiter")
    end
    return setmetatable({
        make_     = make_limiter,
        limiters_ = {},
        lock_     = new_lock(),
    }, Keyed)
end

local function keyed_get(self, key)
    if self.lock_ then self.lock_:lock() end
    local rl = self.limiters_[key]
    if not rl then
        rl = self.make_(key)
        self.limiters_[key] = rl
    end
    if self.lock_ then self.lock_:unlock() end
    return rl
end

function Keyed:take(key, n)     return keyed_get(self, key):take(n)     end
function Keyed:available(key)   return keyed_get(self, key):available() end
function Keyed:wait(key, n, t)  return keyed_get(self, key):wait(n, t)  end

function Keyed:reset(key)
    if key == nil then
        self.limiters_ = {}
    else
        self.limiters_[key] = nil
    end
end

function Keyed:count() return self.limiters_ end

M.TB = TB; M.LB = LB; M.SW = SW; M.FW = FW; M.Keyed = Keyed

return M
