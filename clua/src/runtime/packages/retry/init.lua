-- retry -- exponential backoff with jitter + circuit breaker.
--
-- Public surface:
--   retry(fn, opts?)                  -> result      (raises on final failure)
--   retry.run(fn, opts?)              -> alias for the table-call above
--   retry.backoff(opts?)              -> iterator yielding (attempt, delay_ms)
--   retry.circuit_breaker(opts?)      -> cb
--
-- retry options:
--   max_attempts        (default 3)
--   initial_delay_ms    (default 100)
--   max_delay_ms        (default 30000)
--   multiplier          (default 2)
--   jitter              "full" | "equal" | "none"        (default "full")
--   retry_on            function(err) -> bool, OR a table of literal errs/msg-prefixes
--   on_retry            function(err, attempt, delay_ms) -- callback per retry
--
-- circuit_breaker options:
--   failure_threshold   (default 5)   -- closed -> open after N consecutive failures
--   success_threshold   (default 2)   -- half_open -> closed after N consecutive successes
--   timeout_ms          (default 60000) -- how long OPEN waits before half_open
--   half_open_max_calls (default 1)   -- max in-flight calls allowed in half_open
--
-- cb methods:
--   cb:call(fn, ...)                  -> result (raises if open or fn raises)
--   cb:state()                        -> "closed" | "open" | "half_open"
--   cb:reset()
--
-- Errors raised:
--   "retry: gave up after N attempts: <last error>"
--   "circuit_breaker: open"
--   "circuit_breaker: too many half_open calls"

local time = require "time"

-- The module table is also callable as a function (retry(fn, opts) <=>
-- retry.run(fn, opts)). We assign the metatable after M.run is defined.
local M = {}

-- ===== Backoff schedule ================================================

local function compute_delay(opts, attempt)
    local base = opts.initial_delay_ms or 100
    local mult = opts.multiplier or 2
    local cap  = opts.max_delay_ms or 30000
    local d = base * (mult ^ (attempt - 1))
    if d > cap then d = cap end
    local jitter = opts.jitter or "full"
    if jitter == "none" then
        return d
    elseif jitter == "equal" then
        -- equal jitter: half deterministic + half random
        return d * 0.5 + math.random() * d * 0.5
    else -- "full"
        return math.random() * d
    end
end

function M.backoff(opts)
    opts = opts or {}
    local max_attempts = opts.max_attempts or 3
    local i = 0
    return function()
        i = i + 1
        if i > max_attempts then return nil end
        return i, compute_delay(opts, i)
    end
end

local function should_retry(err, retry_on)
    if retry_on == nil then return true end
    if type(retry_on) == "function" then
        return retry_on(err) == true
    end
    if type(retry_on) == "table" then
        local s = tostring(err or "")
        for _, candidate in ipairs(retry_on) do
            if type(candidate) == "string" then
                if s == candidate or s:find(candidate, 1, true) then return true end
            elseif candidate == err then
                return true
            end
        end
        return false
    end
    return true
end

function M.run(fn, opts)
    opts = opts or {}
    local max_attempts = opts.max_attempts or 3
    local last_err
    for attempt = 1, max_attempts do
        local ok, ret = pcall(fn, attempt)
        if ok then return ret end
        last_err = ret
        if not should_retry(last_err, opts.retry_on) then
            error("retry: aborted (retry_on returned false): " .. tostring(last_err), 2)
        end
        if attempt == max_attempts then break end
        local delay_ms = compute_delay(opts, attempt)
        if opts.on_retry then
            pcall(opts.on_retry, last_err, attempt, delay_ms)
        end
        time.sleep(delay_ms / 1000)
    end
    error(string.format("retry: gave up after %d attempts: %s",
        max_attempts, tostring(last_err)), 2)
end

-- ===== Circuit breaker ================================================

local CB = {}
CB.__index = CB

function M.circuit_breaker(opts)
    opts = opts or {}
    return setmetatable({
        failure_threshold   = opts.failure_threshold or 5,
        success_threshold   = opts.success_threshold or 2,
        timeout_s_          = (opts.timeout_ms or 60000) / 1000,
        half_open_max_calls = opts.half_open_max_calls or 1,
        on_open_            = opts.on_open,
        on_close_           = opts.on_close,
        state_              = "closed",
        fail_count_         = 0,
        succ_count_         = 0,
        opened_at_          = nil,
        half_open_inflight_ = 0,
        last_err_           = nil,
    }, CB)
end

local function cb_promote(self)
    if self.state_ == "open" then
        if (time.monotonic() - self.opened_at_) >= self.timeout_s_ then
            self.state_ = "half_open"
            self.succ_count_ = 0
            self.fail_count_ = 0
            self.half_open_inflight_ = 0
        end
    end
end

function CB:state()
    cb_promote(self)
    return self.state_
end

function CB:reset()
    self.state_              = "closed"
    self.fail_count_         = 0
    self.succ_count_         = 0
    self.opened_at_          = nil
    self.half_open_inflight_ = 0
    self.last_err_           = nil
end

local function trip_open(self, reason)
    local was = self.state_
    self.state_     = "open"
    self.opened_at_ = time.monotonic()
    self.last_err_  = reason
    if was ~= "open" and self.on_open_ then pcall(self.on_open_, reason) end
end

local function close_breaker(self)
    local was = self.state_
    self.state_     = "closed"
    self.fail_count_ = 0
    self.succ_count_ = 0
    self.opened_at_  = nil
    self.half_open_inflight_ = 0
    if was ~= "closed" and self.on_close_ then pcall(self.on_close_) end
end

function CB:call(fn, ...)
    cb_promote(self)
    local cur = self.state_
    if cur == "open" then
        error("circuit_breaker: open", 2)
    end
    if cur == "half_open" then
        if self.half_open_inflight_ >= self.half_open_max_calls then
            error("circuit_breaker: too many half_open calls", 2)
        end
        self.half_open_inflight_ = self.half_open_inflight_ + 1
    end
    -- Hand pcall the arguments directly; this avoids round-tripping
    -- through table.unpack(varargs) which a couple of Lua VMs (and our
    -- own JIT codegen) handle badly.
    local ok, ret = pcall(fn, ...)
    if cur == "half_open" then
        self.half_open_inflight_ = self.half_open_inflight_ - 1
    end
    if ok then
        if cur == "half_open" then
            self.succ_count_ = self.succ_count_ + 1
            if self.succ_count_ >= self.success_threshold then
                close_breaker(self)
            end
        else
            self.fail_count_ = 0
        end
        return ret
    end
    -- Failure
    if cur == "half_open" then
        trip_open(self, ret)
    else
        self.fail_count_ = self.fail_count_ + 1
        if self.fail_count_ >= self.failure_threshold then
            trip_open(self, ret)
        end
    end
    error(ret, 2)
end

M.CB = CB

-- Install the __call shim now that M.run is set. We capture the
-- function locally so the metamethod doesn't have to round-trip through
-- the module table (and avoids one LuaVM JIT codegen path).
local _retry_run = M.run
setmetatable(M, {
    __call = function(_, fn, opts) return _retry_run(fn, opts) end,
})

return M
