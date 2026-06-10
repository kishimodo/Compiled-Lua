-- tests/packages/test_timer.lua : stopwatch + the cooperative scheduler heap
-- of the builtin `timer` package.
--
-- DETERMINISM NOTE: stopwatches and the scheduler use time.monotonic(), so we
-- never assert a specific elapsed duration (that varies with wall time). We
-- assert the time-INDEPENDENT contract instead: running-state toggles, lap
-- counts, heap size accounting, that already-due callbacks fire on poll(),
-- cancellation suppresses a callback, intervals re-arm, and misuse errors.
-- The scheduler heap is process-global, so we cancel_all() before each block.

local ok_req, timer = pcall(require, "timer")
if not ok_req then print("[~] SKIP test_timer (" .. tostring(timer) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_timer: " .. tostring(m)) end end

-- ===== stopwatch state machine ========================================
local sw = timer.stopwatch()
ok(sw:is_running() == false, "fresh stopwatch is not running")
ok(sw:elapsed() == 0, "fresh stopwatch elapsed is exactly 0")
ok(sw:elapsed_ms() == 0, "fresh stopwatch elapsed_ms is 0")
ok(#sw:laps() == 0, "fresh stopwatch has no laps")
sw:start()
ok(sw:is_running() == true, "stopwatch is running after start")
-- start() is idempotent while running.
sw:start()
ok(sw:is_running() == true, "second start while running is a no-op (still running)")
sw:lap(); sw:lap(); sw:lap()
ok(#sw:laps() == 3, "three laps recorded")
sw:stop()
ok(sw:is_running() == false, "stopwatch is not running after stop")
ok(sw:elapsed() >= 0, "elapsed is non-negative after stop")
ok(math.type(sw:elapsed_ms()) == "integer", "elapsed_ms is an integer")
sw:reset()
ok(sw:elapsed() == 0, "reset clears elapsed to 0")
ok(#sw:laps() == 0, "reset clears laps")
ok(sw:is_running() == false, "reset stops the stopwatch")
-- A lap while stopped records a 0-length lap.
ok(sw:lap() == 0, "lap while stopped is 0")

-- ===== scheduler: count / oneshot / poll ==============================
timer.cancel_all()
ok(timer.count() == 0, "scheduler is empty after cancel_all")

local fired = {}
-- Negative delays are already due, so the next poll() fires them.
local h1 = timer.oneshot(-100, function() fired[#fired + 1] = "a" end)
local h2 = timer.oneshot(-50,  function() fired[#fired + 1] = "b" end)
ok(timer.count() == 2, "two pending oneshots are counted")
ok(h1:active() == true, "oneshot handle is active before firing")
local n = timer.poll()
ok(n == 2, "poll fires both due oneshots")
ok(#fired == 2, "both callbacks ran exactly once")
ok(timer.count() == 0, "oneshots are removed from the heap after firing")
ok(h1:active() == false, "fired oneshot handle is no longer active")

-- ===== cancellation suppresses the callback ===========================
timer.cancel_all()
local hits = 0
local h3 = timer.oneshot(-10, function() hits = hits + 1 end)
h3:cancel()
ok(h3:active() == false, "cancelled handle is inactive")
ok(timer.count() == 0, "cancelling a oneshot removes it from the heap")
local n2 = timer.poll()
ok(n2 == 0, "poll fires nothing after cancellation")
ok(hits == 0, "cancelled callback never ran")
-- cancel() is idempotent.
h3:cancel()
ok(h3:active() == false, "double cancel is safe")

-- ===== interval re-arms after firing ==================================
timer.cancel_all()
local ic = 0
local hi = timer.interval(1000, function() ic = ic + 1 end, { immediate = true })
ok(timer.count() == 1, "interval is on the heap")
local n3 = timer.poll()  -- immediate => due now
ok(n3 == 1, "interval fires once on the first poll (immediate)")
ok(ic == 1, "interval callback ran once")
ok(timer.count() == 1, "interval re-arms itself and stays on the heap")
hi:cancel()
ok(timer.count() == 0, "cancelling the interval removes it")

-- ===== next_deadline sign =============================================
timer.cancel_all()
ok(timer.next_deadline() == nil, "next_deadline is nil with an empty heap")
timer.oneshot(50000, function() end)  -- ~50s out, comfortably in the future
local d = timer.next_deadline()
ok(type(d) == "number" and d > 0, "next_deadline for a future timer is positive")
timer.cancel_all()

-- ===== shorthands after()/every() build handles =======================
timer.cancel_all()
local ha = timer.after(100, function() end)
ok(timer.count() == 1, "after() schedules a oneshot")
ok(ha:active() == true, "after() returns an active handle")
local he = timer.every(100, function() end)
ok(timer.count() == 2, "every() schedules an interval")
timer.cancel_all()
ok(timer.count() == 0, "cancel_all clears everything")

-- ===== error paths ====================================================
ok(select(1, pcall(timer.oneshot, "x", function() end)) == false, "oneshot rejects non-number delay")
ok(select(1, pcall(timer.oneshot, 100, "nope")) == false, "oneshot rejects non-function callback")
ok(select(1, pcall(timer.interval, -5, function() end)) == false, "interval rejects non-positive period")
ok(select(1, pcall(timer.interval, 100, 42)) == false, "interval rejects non-function callback")
ok(select(1, pcall(timer.tick, 0)) == false, "tick rejects non-positive period")

if fails == 0 then print("[+] PASS test_timer") os.exit(0) else os.exit(1) end
