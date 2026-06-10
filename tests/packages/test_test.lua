-- tests/packages/test_test.lua : describe/it test runner.
-- Determinism trap: test.run() with the default reporter prints ANSI colors +
-- per-test millisecond timings (non-deterministic). So we install a SILENT
-- custom reporter (prints nothing) and assert on the RETURNED summary counts,
-- which are deterministic. We print only our own fixed [+]/[-] lines.
local ok_req, test = pcall(require, "test")
if not ok_req then print("[~] SKIP test_test (" .. tostring(test) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_test: " .. tostring(m)) end end

-- A reporter that emits nothing keeps run() output empty + deterministic.
local function silent_reporter()
    local noop = function() end
    return {
        suite_start = noop, describe_enter = noop, describe_leave = noop,
        it_result = noop, suite_end = noop,
    }
end

-- run() reads Reporters._custom; set_reporter(fn) installs it. We re-install
-- before every run because run() does not clear it.
local function run_silent(opts)
    test.set_reporter(silent_reporter)
    return test.run(opts)
end

-- ---- Scenario 1: passes, failures, skips counted correctly ----
test.reset()
test.describe("math", function()
    test.it("adds", function() assert(1 + 1 == 2) end)
    test.it("subtracts", function() assert(5 - 3 == 2) end)
    test.it("fails on purpose", function() error("nope") end)
    test.pending("not yet", "todo")          -- becomes a skip
end)
local s1 = run_silent()
ok(s1.total == 4,    "scenario1: 4 tests total")
ok(s1.passed == 2,   "scenario1: 2 passed (got " .. s1.passed .. ")")
ok(s1.failed == 1,   "scenario1: 1 failed (got " .. s1.failed .. ")")
ok(s1.skipped == 1,  "scenario1: 1 skipped (pending) (got " .. s1.skipped .. ")")
ok(#s1.records == 4, "scenario1: one record per test")

-- Records carry status + name; find the failing one and check its path.
local function find_rec(summary, name)
    for _, r in ipairs(summary.records) do if r.name == name then return r end end
    return nil
end
local frec = find_rec(s1, "fails on purpose")
ok(frec ~= nil and frec.status == "fail", "scenario1: failing test recorded as fail")
ok(frec and frec.path == "math > fails on purpose", "scenario1: nested path is 'math > ...'")
local prec = find_rec(s1, "adds")
ok(prec and prec.status == "pass", "scenario1: passing test recorded as pass")

-- ---- Scenario 2: before_each / after_each run around each it ----
test.reset()
local seq = {}
test.describe("hooks", function()
    test.before_each(function() seq[#seq + 1] = "before" end)
    test.after_each(function()  seq[#seq + 1] = "after"  end)
    test.it("one", function() seq[#seq + 1] = "body1" end)
    test.it("two", function() seq[#seq + 1] = "body2" end)
end)
local s2 = run_silent()
ok(s2.passed == 2, "scenario2: both hook tests pass")
-- Exact deterministic hook order across both tests.
local joined = table.concat(seq, ",")
ok(joined == "before,body1,after,before,body2,after",
   "scenario2: before/after wrap each test in order (got " .. joined .. ")")

-- ---- Scenario 3: before_all runs exactly once per describe ----
test.reset()
local all_count = 0
test.describe("setup", function()
    test.before_all(function() all_count = all_count + 1 end)
    test.it("a", function() end)
    test.it("b", function() end)
    test.it("c", function() end)
end)
run_silent()
ok(all_count == 1, "scenario3: before_all fired exactly once for 3 tests")

-- ---- Scenario 4: skip() inside a body marks the test skipped ----
test.reset()
test.describe("skips", function()
    test.it("explicitly skipped", function() test.skip("manual") end)
    test.it("runs", function() assert(true) end)
end)
local s4 = run_silent()
ok(s4.skipped == 1, "scenario4: skip() yields one skipped test")
ok(s4.passed == 1,  "scenario4: the other test still passes")

-- ---- Scenario 5: opts.only / focus restricts the run ----
test.reset()
test.describe("focus", function()
    test.it("only this", function() assert(true) end, { only = true })
    test.it("not this", function() error("should not run") end)
end)
local s5 = run_silent()
ok(s5.total == 1,  "scenario5: only the focused test ran")
ok(s5.passed == 1, "scenario5: focused test passed")

-- ---- Scenario 6: filter by name pattern ----
test.reset()
test.describe("group", function()
    test.it("alpha", function() assert(true) end)
    test.it("beta", function() assert(true) end)
    test.it("alphabet", function() assert(true) end)
end)
local s6 = run_silent({ filter = "alpha" })
ok(s6.total == 2, "scenario6: filter 'alpha' matches 2 tests (alpha, alphabet)")

-- ---- Scenario 7: tag filtering ----
test.reset()
test.describe("tagged", function()
    test.it("slow one", function() assert(true) end, { tags = { "slow" } })
    test.it("fast one", function() assert(true) end, { tags = { "fast" } })
end)
local s7 = run_silent({ tags = { "slow" } })
ok(s7.total == 1, "scenario7: tag filter 'slow' selects 1 test")

-- ---- Scenario 8: bail stops on first failure ----
test.reset()
test.describe("bailing", function()
    test.it("ok1", function() assert(true) end)
    test.it("boom", function() error("x") end)
    test.it("never", function() error("should not run") end)
end)
local s8 = run_silent({ bail = true })
ok(s8.total == 2,  "scenario8: bail stops after the failing test")
ok(s8.failed == 1, "scenario8: exactly one failure before bailing")

-- ---- Scenario 9: xit is always skipped ----
test.reset()
test.describe("xit", function()
    test.xit("disabled", function() error("should not run") end)
    test.it("enabled", function() assert(true) end)
end)
local s9 = run_silent()
ok(s9.skipped == 1, "scenario9: xit registers as skipped")
ok(s9.passed == 1,  "scenario9: sibling it still runs")

if fails == 0 then print("[+] PASS test_test") os.exit(0) else os.exit(1) end
