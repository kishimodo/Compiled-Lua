local ok_req, retry = pcall(require, "retry")
if not ok_req then print("[~] SKIP test_retry") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_retry: " .. tostring(m)) end end

-- Keep every delay tiny so the suite stays fast (time.sleep busy-waits on QPC).
local FAST = { initial_delay_ms = 1, max_delay_ms = 1, multiplier = 1, jitter = "none" }
local function fast(extra)
  local o = {}
  for k, v in pairs(FAST) do o[k] = v end
  if extra then for k, v in pairs(extra) do o[k] = v end end
  return o
end

-- ===== retry.run: succeeds after N failures, within the attempt budget =====
do
  local calls = 0
  -- fail twice, succeed on the 3rd attempt; budget of 3 is exactly enough.
  local res = retry.run(function()
    calls = calls + 1
    if calls < 3 then error("transient " .. calls) end
    return "value-" .. calls
  end, fast({ max_attempts = 3 }))
  ok(calls == 3, "should have been called exactly 3 times, got " .. calls)
  ok(res == "value-3", "should return the successful result, got " .. tostring(res))
end

-- ===== module is callable: retry(fn, opts) == retry.run(fn, opts) =====
do
  local calls = 0
  local res = retry(function() calls = calls + 1; return 42 end, fast())
  ok(calls == 1, "callable form: success on first try is called once, got " .. calls)
  ok(res == 42, "callable form: returns result, got " .. tostring(res))
end

-- ===== exhausting retries surfaces the LAST error =====
do
  local calls = 0
  local ok_call, err = pcall(retry.run, function()
    calls = calls + 1
    error("boom-" .. calls)
  end, fast({ max_attempts = 3 }))
  ok(not ok_call, "exhausted retries must raise")
  ok(calls == 3, "should attempt exactly max_attempts times, got " .. calls)
  -- The raised message must mention the attempt count and the LAST error.
  ok(type(err) == "string" and err:find("gave up after 3 attempts", 1, true) ~= nil,
     "error should report attempt count, got " .. tostring(err))
  ok(type(err) == "string" and err:find("boom-3", 1, true) ~= nil,
     "error should surface the LAST underlying error (boom-3), got " .. tostring(err))
end

-- ===== on_retry callback fires once per retry (not on the final attempt) =====
do
  local calls, retries = 0, 0
  local seen_attempts = {}
  pcall(retry.run, function()
    calls = calls + 1
    error("e")
  end, fast({
    max_attempts = 4,
    on_retry = function(_err, attempt, _delay)
      retries = retries + 1
      seen_attempts[#seen_attempts + 1] = attempt
    end,
  }))
  ok(calls == 4, "fn called max_attempts(4) times, got " .. calls)
  -- 4 attempts => 3 inter-attempt retries; the final failure is NOT a retry.
  ok(retries == 3, "on_retry should fire (max_attempts-1)=3 times, got " .. retries)
  ok(seen_attempts[1] == 1 and seen_attempts[2] == 2 and seen_attempts[3] == 3,
     "on_retry attempt numbers should be 1,2,3")
end

-- ===== retry_on as a function: returning false aborts immediately =====
do
  local calls = 0
  local ok_call, err = pcall(retry.run, function()
    calls = calls + 1
    error("do-not-retry")
  end, fast({
    max_attempts = 5,
    retry_on = function(_e) return false end,
  }))
  ok(not ok_call, "retry_on=false must surface an error")
  ok(calls == 1, "retry_on=false should stop after the first attempt, got " .. calls)
  ok(type(err) == "string" and err:find("retry_on returned false", 1, true) ~= nil,
     "abort error should mention retry_on, got " .. tostring(err))
end

-- ===== retry_on as a function: returning true keeps retrying =====
do
  local calls = 0
  pcall(retry.run, function()
    calls = calls + 1
    error("retry-me")
  end, fast({ max_attempts = 3, retry_on = function(_e) return true end }))
  ok(calls == 3, "retry_on=true should retry up to max_attempts, got " .. calls)
end

-- ===== retry_on as a table of literal/prefix error strings =====
do
  -- The raised error is a full string "<file>:<line>: ETIMEDOUT". The table
  -- match uses substring/prefix find, so listing "ETIMEDOUT" matches.
  local calls = 0
  pcall(retry.run, function()
    calls = calls + 1
    error("ETIMEDOUT")
  end, fast({ max_attempts = 3, retry_on = { "ETIMEDOUT" } }))
  ok(calls == 3, "table retry_on should retry on a matching substring, got " .. calls)

  -- A non-matching error in the table => no retry.
  local calls2 = 0
  pcall(retry.run, function()
    calls2 = calls2 + 1
    error("EPERM")
  end, fast({ max_attempts = 3, retry_on = { "ETIMEDOUT" } }))
  ok(calls2 == 1, "table retry_on should NOT retry an unlisted error, got " .. calls2)
end

-- ===== retry.backoff iterator: count + monotone non-decreasing delays =====
do
  -- deterministic schedule: jitter "none", base 100, x2, capped at 350.
  local it = retry.backoff({
    max_attempts = 5, initial_delay_ms = 100, multiplier = 2,
    max_delay_ms = 350, jitter = "none",
  })
  local got = {}
  for attempt, delay in it do got[attempt] = delay end
  ok(got[1] == 100, "backoff[1] should be 100, got " .. tostring(got[1]))
  ok(got[2] == 200, "backoff[2] should be 200 (100*2), got " .. tostring(got[2]))
  ok(got[3] == 350, "backoff[3] should be capped at 350 (400>350), got " .. tostring(got[3]))
  ok(got[4] == 350, "backoff[4] should stay capped at 350, got " .. tostring(got[4]))
  ok(got[5] == 350, "backoff[5] should stay capped at 350, got " .. tostring(got[5]))
  ok(got[6] == nil, "backoff should stop after max_attempts(5)")

  -- count of yielded entries == max_attempts
  local n = 0
  for _a, _d in retry.backoff({ max_attempts = 4, jitter = "none" }) do n = n + 1 end
  ok(n == 4, "backoff should yield exactly max_attempts(4) entries, got " .. n)
end

-- ===== backoff "full" jitter stays within [0, d] =====
do
  math.randomseed(12345)
  local within = true
  for attempt, delay in retry.backoff({
    max_attempts = 6, initial_delay_ms = 100, multiplier = 2,
    max_delay_ms = 100000, jitter = "full",
  }) do
    local cap = 100 * (2 ^ (attempt - 1))
    if delay < 0 or delay > cap + 1e-9 then within = false end
  end
  ok(within, "full jitter delays must lie in [0, base*mult^(n-1)]")
end

-- ===== circuit_breaker: trips OPEN after failure_threshold, then rejects =====
do
  local cb = retry.circuit_breaker({ failure_threshold = 3, timeout_ms = 60000 })
  ok(cb:state() == "closed", "breaker starts closed, got " .. cb:state())

  local function boom() error("fail") end
  -- Two failures: still closed (threshold is 3).
  pcall(cb.call, cb, boom)
  pcall(cb.call, cb, boom)
  ok(cb:state() == "closed", "below threshold the breaker stays closed, got " .. cb:state())

  -- Third consecutive failure trips it OPEN.
  pcall(cb.call, cb, boom)
  ok(cb:state() == "open", "breaker should be OPEN after 3 failures, got " .. cb:state())

  -- While OPEN, calls are rejected fast with "circuit_breaker: open" and the
  -- underlying fn is NOT invoked.
  local invoked = false
  local ok_call, err = pcall(cb.call, cb, function() invoked = true end)
  ok(not ok_call, "OPEN breaker must reject calls")
  ok(not invoked, "OPEN breaker must NOT invoke the wrapped fn")
  ok(type(err) == "string" and err:find("circuit_breaker: open", 1, true) ~= nil,
     "OPEN rejection should say so, got " .. tostring(err))
end

-- ===== circuit_breaker: a success in CLOSED resets the consecutive count =====
do
  local cb = retry.circuit_breaker({ failure_threshold = 3 })
  local function boom() error("x") end
  pcall(cb.call, cb, boom)            -- fail_count = 1
  pcall(cb.call, cb, boom)            -- fail_count = 2
  cb:call(function() return "ok" end) -- success resets fail_count to 0
  ok(cb:state() == "closed", "still closed after a success, got " .. cb:state())
  pcall(cb.call, cb, boom)            -- 1
  pcall(cb.call, cb, boom)            -- 2
  ok(cb:state() == "closed",
     "two fresh failures after the reset must NOT trip (count was reset), got " .. cb:state())
end

-- ===== circuit_breaker: OPEN -> half_open after timeout, success closes it =====
do
  -- timeout 0ms => the breaker is eligible to move to half_open immediately.
  local cb = retry.circuit_breaker({
    failure_threshold = 1, success_threshold = 1, timeout_ms = 0,
  })
  pcall(cb.call, cb, function() error("trip") end)
  ok(cb:state() == "half_open" or cb:state() == "open",
     "after timeout=0 the breaker becomes half_open on inspection, got " .. cb:state())
  -- One success in half_open (success_threshold=1) closes the breaker.
  local res = cb:call(function() return "recovered" end)
  ok(res == "recovered", "half_open success returns the result, got " .. tostring(res))
  ok(cb:state() == "closed", "success in half_open should CLOSE the breaker, got " .. cb:state())
end

-- ===== circuit_breaker: a failure in half_open trips back OPEN =====
do
  local cb = retry.circuit_breaker({
    failure_threshold = 1, success_threshold = 2, timeout_ms = 0,
  })
  pcall(cb.call, cb, function() error("trip") end)   -- -> open, eligible half_open
  ok(cb:state() == "half_open", "should be half_open after timeout=0, got " .. cb:state())
  pcall(cb.call, cb, function() error("still bad") end) -- failure in half_open
  -- After tripping open with timeout 0 it is immediately eligible again, but
  -- the important invariant is that a half_open failure did NOT close it.
  ok(cb:state() ~= "closed", "half_open failure must NOT close the breaker, got " .. cb:state())
end

-- ===== circuit_breaker: reset() forces back to closed =====
do
  local cb = retry.circuit_breaker({ failure_threshold = 1 })
  pcall(cb.call, cb, function() error("x") end)
  ok(cb:state() == "open", "tripped open, got " .. cb:state())
  cb:reset()
  ok(cb:state() == "closed", "reset() must return the breaker to closed, got " .. cb:state())
end

-- ===== circuit_breaker: passes args through and returns fn result =====
do
  local cb = retry.circuit_breaker({})
  local sum = cb:call(function(a, b, c) return a + b + c end, 2, 3, 4)
  ok(sum == 9, "cb:call should forward args and return result, got " .. tostring(sum))
end

if fails == 0 then print("[+] PASS test_retry") os.exit(0) else os.exit(1) end
