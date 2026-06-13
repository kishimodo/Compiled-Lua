-- pool -- worker-pool with a task queue and future-based result handoff.
--
-- Public surface:
--   pool.new(opts?)                  -> pool
--   pool.parallel(fn, items, opts?) -> { future, future, ... }
--
-- opts table:
--   workers     = thread.cpu_count()    pool size (>= 1), validated
--   queue_size  = 1000                  bounded task channel capacity
--
-- Tasks currently run INLINE (synchronously on the caller's thread); a future
-- revision can dispatch them to native OS threads via thread.spawn once the
-- task channel is shareable across lua_States.
--
-- Pool methods:
--   :submit(fn, args?)              -> future
--   :map(fn, items)                 -> { future, ... } (one per item)
--   :wait_all(futures, timeout_ms?) -> values_table | nil, err
--   :close(timeout_ms?)             drain the queue, signal workers, join
--   :size()                         -> queued + in-flight count
--
-- Future methods:
--   :result(timeout_ms?)            -> value | nil, err
--   :done()                         -> bool
--   :cancel()                       -> bool (true if not yet started)
--
-- ===== Implementation ===========================================
--
-- submit() runs the task INLINE on the calling thread and resolves the future
-- immediately; :result() then returns it on the first call. A cancelled task
-- (future already in the "cancelled" state) reports cancellation instead of
-- running.

local thread  = require "thread"
local channel = require "channel"
local atomic  = require "atomic"

local M = {}

-- ===== future ===================================================

local future_mt = { __index = {} }
local future_methods = future_mt.__index

local FUT_PENDING   = 0
local FUT_RUNNING   = 1
local FUT_DONE      = 2
local FUT_ERROR     = 3
local FUT_CANCELLED = 4

local function new_future()
    return setmetatable({
        state     = atomic.int(FUT_PENDING),
        result_ch = channel.make(1),    -- capacity-1 hand-off; named to avoid shadowing :result()
        _value    = nil,
        _err      = nil,
        _consumed = false,
    }, future_mt)
end

function future_methods:done()
    local s = self.state:get()
    return s == FUT_DONE or s == FUT_ERROR or s == FUT_CANCELLED
end

function future_methods:cancel()
    -- Only succeeds if the task is still pending (worker hasn't picked
    -- it up). Once running, cancellation is a no-op -- the worker will
    -- run the function to completion.
    return self.state:cas(FUT_PENDING, FUT_CANCELLED)
end

function future_methods:result(timeout_ms)
    if self._consumed then
        if self._err then return nil, self._err end
        return self._value
    end
    -- The result channel hands off exactly once. The state field already
    -- reflects done/error/cancelled; the channel carries the payload.
    local s = self.state:get()
    if s == FUT_CANCELLED then
        self._consumed = true
        self._err = "cancelled"
        return nil, "cancelled"
    end
    local v, ok, terr = self.result_ch:receive(timeout_ms)
    if terr == "timeout" then return nil, "timeout" end
    if not ok then
        -- Channel closed without a value -- the worker died before
        -- reporting. Surface as a generic failure.
        self._consumed = true
        self._err = "worker terminated without reporting"
        return nil, self._err
    end
    self._consumed = true
    -- v is a table { ok = bool, value = ..., err = ... }
    if v.ok then
        self._value = v.value
        return v.value
    end
    self._err = v.err
    return nil, v.err
end

-- ===== pool =====================================================

local pool_mt = { __index = {} }
local pool_methods = pool_mt.__index

-- Inline-execute a single task in the calling Lua state. Used when:
--   * thread package falls back to cooperative mode (no real threads), OR
--   * pool is run in single-worker mode for tests
local function exec_inline(fn, args, future)
    if not future.state:cas(FUT_PENDING, FUT_RUNNING) then
        -- Was cancelled before we got here.
        future.result_ch:send({ ok = false, err = "cancelled" })
        return
    end
    local ok, r1, r2, r3, r4 = pcall(fn, table.unpack(args or {}))
    if ok then
        future.state:set(FUT_DONE)
        future.result_ch:send({ ok = true, value = r1 })
    else
        future.state:set(FUT_ERROR)
        future.result_ch:send({ ok = false, err = tostring(r1) })
    end
end

function M.new(opts)
    opts = opts or {}
    local workers    = opts.workers or thread.cpu_count() or 4
    local queue_size = opts.queue_size or 1000
    if workers < 1 then error("pool.new: workers must be >= 1") end

    -- Tasks run inline (synchronously on the caller's thread); futures are born
    -- resolved. A real bounded pool over native OS threads -- thread.spawn now
    -- provides those -- needs a task channel shareable across lua_States, which
    -- is the documented next step; until then submit() is synchronous.
    return setmetatable({
        task_ch  = channel.make(queue_size),
        closed   = atomic.flag(),
        inflight = atomic.int(0),
    }, pool_mt)
end

function pool_methods:submit(fn, args)
    if type(fn) ~= "function" then
        error("pool:submit: fn must be a function", 2)
    end
    if self.closed:get() ~= 0 then
        local fut = new_future()
        fut.state:set(FUT_ERROR)
        fut.result_ch:send({ ok = false, err = "pool closed" })
        return fut
    end
    local fut = new_future()
    self.inflight:inc()
    -- Tasks execute inline on the calling thread; the future is born
    -- resolved. thread.spawn can already place a shippable function on a real
    -- OS thread (resolved by its compile-time function-id); a real bounded pool
    -- additionally needs the task channel to be shareable across lua_States, the
    -- documented next step. Until then submit() is synchronous.
    exec_inline(fn, args, fut)
    self.inflight:dec()
    return fut
end

-- Apply fn to each item and return a future per item. Order preserved.
function pool_methods:map(fn, items)
    local futures = {}
    for i = 1, #items do
        futures[i] = self:submit(fn, { items[i] })
    end
    return futures
end

-- Block until every future is done or the per-call timeout expires.
-- Returns the list of values (positional) on success, or nil + the first
-- error encountered. A cancelled future surfaces as err = "cancelled".
function pool_methods:wait_all(futures, timeout_ms)
    local out = {}
    -- Per-future timeout is computed against a single deadline so the
    -- caller can bound total wait time.
    local deadline = nil
    if timeout_ms ~= nil then
        deadline = os.clock() * 1000 + timeout_ms
    end
    for i, fut in ipairs(futures) do
        local rem
        if deadline ~= nil then
            rem = deadline - os.clock() * 1000
            if rem <= 0 then return nil, "timeout" end
        end
        local v, err = fut:result(rem)
        if err then return nil, err end
        out[i] = v
    end
    return out
end

function pool_methods:close(timeout_ms)
    if self.closed:test_and_set() then return end
    self.task_ch:close()
    -- Inline mode: nothing to wait for. Real mode would join() each
    -- worker handle here.
    return true
end

function pool_methods:size()
    -- Approximate -- the channel's len reflects queued tasks; inflight
    -- counts the ones a worker has picked up. The sum is the right
    -- answer for "is there outstanding work?".
    return self.task_ch:len() + self.inflight:get()
end

-- pool.parallel(fn, items, opts?): convenience that submits each item to
-- a fresh pool, waits, returns the results, and closes the pool. Useful
-- for one-shot parallel maps where managing the pool isn't worth it.
function M.parallel(fn, items, opts)
    local p = M.new(opts)
    local futures = p:map(fn, items)
    local result, err = p:wait_all(futures)
    p:close()
    if err then return nil, err end
    return result
end

return M
