-- tests/packages/test_rate_limit.lua : token/leaky bucket + sliding/fixed
-- window + keyed limiters for the builtin `rate_limit` package.
--
-- DETERMINISM NOTE: every limiter uses time.monotonic(), which advances in
-- real time. So we never assert an exact retry_after_ms or an exact refilled
-- token count (those depend on elapsed wall time). Instead we assert the
-- time-independent contract: a fresh limiter is at full capacity; takes that
-- fit succeed with retry==0; the take that exhausts the budget fails with a
-- POSITIVE retry hint; reset() restores capacity; misconfiguration errors.
-- All such facts are byte-identical under the JIT and the interpreter.

local ok_req, rate_limit = pcall(require, "rate_limit")
if not ok_req then print("[~] SKIP test_rate_limit (" .. tostring(rate_limit) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_rate_limit: " .. tostring(m)) end end

-- ===== token bucket ===================================================
local tb = rate_limit.token_bucket({ capacity = 5, refill_rate = 1, refill_interval_ms = 1000 })
ok(tb:available() == 5, "fresh token bucket reports full capacity (5)")
local ok1, r1 = tb:take(3)
ok(ok1 == true and r1 == 0, "take 3 of 5 succeeds with retry 0")
local ok2, r2 = tb:take(2)
ok(ok2 == true and r2 == 0, "take remaining 2 succeeds with retry 0")
local ok3, r3 = tb:take(1)
ok(ok3 == false, "take when empty fails")
ok(type(r3) == "number" and r3 > 0, "exhausted take returns a positive retry hint")
tb:reset()
ok(tb:available() == 5, "reset restores token bucket to full capacity")
-- A take larger than the whole capacity can never succeed immediately.
local okBig = rate_limit.token_bucket({ capacity = 2, refill_rate = 1, refill_interval_ms = 1000 }):take(3)
ok(okBig == false, "taking more than capacity fails immediately")

-- ===== leaky bucket ===================================================
local lb = rate_limit.leaky_bucket({ capacity = 5, leak_rate = 1, leak_interval_ms = 1000 })
ok(lb:available() == 5, "fresh leaky bucket has full headroom (5)")
local lo, lr = lb:take(5)
ok(lo == true and lr == 0, "filling the leaky bucket to capacity succeeds")
local lo2, lr2 = lb:take(1)
ok(lo2 == false and lr2 > 0, "overfilling the leaky bucket fails with positive retry")
lb:reset()
ok(lb:available() == 5, "reset drains the leaky bucket")

-- ===== sliding window =================================================
local sw = rate_limit.sliding_window({ max_requests = 3, window_ms = 10000 })
ok(sw:available() == 3, "fresh sliding window allows max_requests")
ok(select(1, sw:take()) == true, "sliding take 1/3")
ok(select(1, sw:take()) == true, "sliding take 2/3")
ok(select(1, sw:take()) == true, "sliding take 3/3")
local so, sr = sw:take()
ok(so == false and sr > 0, "sliding 4th take fails with positive retry")
ok(sw:available() == 0, "sliding window is exhausted")
sw:reset()
ok(sw:available() == 3, "reset clears the sliding window")

-- ===== fixed window ===================================================
local fw = rate_limit.fixed_window({ max_requests = 2, window_ms = 10000 })
ok(fw:available() == 2, "fresh fixed window allows max_requests")
ok(select(1, fw:take()) == true, "fixed take 1/2")
ok(select(1, fw:take()) == true, "fixed take 2/2")
local fo, fr = fw:take()
ok(fo == false and fr > 0, "fixed 3rd take fails with positive retry")
fw:reset()
ok(fw:available() == 2, "reset clears the fixed window")

-- ===== keyed limiter: per-key isolation ===============================
local keyed = rate_limit.keyed(function()
  return rate_limit.token_bucket({ capacity = 2, refill_rate = 1, refill_interval_ms = 1000 })
end)
ok(select(1, keyed:take("alice")) == true, "keyed alice take 1")
ok(select(1, keyed:take("alice")) == true, "keyed alice take 2")
ok(select(1, keyed:take("alice")) == false, "keyed alice take 3 (exhausted)")
-- bob has his own independent budget.
ok(select(1, keyed:take("bob")) == true, "keyed bob is independent of alice")
-- (token buckets refill continuously, so headroom is in [1, capacity=2])
local bob_avail = keyed:available("bob")
ok(bob_avail >= 1 and bob_avail <= 2, "keyed bob has ~1 (of 2) left after one take")
keyed:reset("alice")
ok(select(1, keyed:take("alice")) == true, "reset(alice) gives alice a fresh limiter")

-- ===== misconfiguration errors ========================================
ok(select(1, pcall(rate_limit.token_bucket, { capacity = 0 })) == false, "capacity 0 errors")
ok(select(1, pcall(rate_limit.token_bucket, { refill_rate = 0 })) == false, "refill_rate 0 errors")
ok(select(1, pcall(rate_limit.sliding_window, { max_requests = 0 })) == false, "sliding max_requests 0 errors")
ok(select(1, pcall(rate_limit.keyed, "not a function")) == false, "keyed requires a function")

if fails == 0 then print("[+] PASS test_rate_limit") os.exit(0) else os.exit(1) end
