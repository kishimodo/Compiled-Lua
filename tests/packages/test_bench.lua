-- tests/packages/test_bench.lua : microbenchmark framework.
-- Determinism: we NEVER assert timing magnitudes (those vary per run/machine).
-- We assert (a) the RESULT SHAPE and statistical invariants, and (b) the pure
-- internal statistics via the public bench() on a trivially fast fn, plus
-- ordering/formatting guarantees that don't depend on wall-clock values.
local ok_req, bench = pcall(require, "bench")
if not ok_req then print("[~] SKIP test_bench (" .. tostring(bench) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_bench: " .. tostring(m)) end end

-- Keep the run tiny/fast: fixed iteration count, few trials, no auto-calibrate.
local FAST = { iterations = 50, warmup = 1, min_trials = 5, max_trials = 6, target_ms = 1 }

local noop = function() end
local r = bench.bench("noop", noop, FAST)

-- Result shape / field presence.
ok(r.name == "noop",                         "result carries the benchmark name")
ok(r.iterations == 50,                       "explicit iteration count is honored")
ok(type(r.ns_per_op) == "number",            "ns_per_op is a number")
ok(type(r.ops_per_sec) == "number",          "ops_per_sec is a number")
ok(type(r.mean_ns) == "number",              "mean_ns is a number")
ok(type(r.median_ns) == "number",            "median_ns is a number")
ok(type(r.stddev_ns) == "number",            "stddev_ns is a number")
ok(type(r.min_ns) == "number",               "min_ns is a number")
ok(type(r.max_ns) == "number",               "max_ns is a number")

-- Statistical invariants that hold regardless of the actual timings.
ok(r.min_ns <= r.median_ns,                  "min <= median")
ok(r.median_ns <= r.max_ns,                  "median <= max")
ok(r.mean_ns >= 0,                           "mean is non-negative")
ok(r.stddev_ns >= 0,                         "stddev is non-negative")
ok(r.ns_per_op == r.median_ns,              "ns_per_op equals the median")
ok(r.samples >= 1,                           "at least one sample survived outlier rejection")
ok(r.outliers >= 0,                          "outlier count is non-negative")
-- ops_per_sec is the reciprocal of median (in seconds). Allow tiny FP slack.
if r.median_ns > 0 then
    local expected = 1e9 / r.median_ns
    ok(math.abs(r.ops_per_sec - expected) < 1e-3,
       "ops_per_sec == 1e9 / median_ns")
end

-- compare(): returns a list sorted fastest-first with `relative` populated.
local cmp = bench.compare({ a = noop, b = function() local _ = 1 + 1 end }, FAST)
ok(#cmp == 2,                                "compare returns one entry per fn")
ok(cmp[1].ns_per_op <= cmp[2].ns_per_op,     "compare sorts fastest first")
ok(cmp[1].relative == 1,                     "fastest entry has relative == 1")
ok(cmp[2].relative >= 1,                     "slower entry has relative >= 1")

-- suite(): :add is chainable, :run returns one result per entry.
local suite = bench.suite(FAST)
local chained = suite:add("x", noop):add("y", noop)
ok(chained == suite,                         "suite:add is chainable (returns self)")
local results = suite:run()
ok(#results == 2,                            "suite:run returns a result per added entry")
ok(results[1].name == "x" and results[2].name == "y", "suite preserves add order in results")

-- report(): a table with a header row and one row per entry.
local report = suite:report()
ok(type(report) == "string",                 "suite:report returns a string")
ok(report:find("ns/op", 1, true) ~= nil,     "report header mentions ns/op")
ok(report:find("ops/sec", 1, true) ~= nil,   "report header mentions ops/sec")
ok(report:find("\nx", 1, true) ~= nil or report:find("x ", 1, true) ~= nil,
   "report contains the 'x' benchmark row")

-- format(): single-result human rendering, mentions the name and ns/op.
local txt = bench.format(r)
ok(type(txt) == "string",                    "format returns a string")
ok(txt:find("noop", 1, true) ~= nil,         "format mentions the benchmark name")
ok(txt:find("ns/op", 1, true) ~= nil,        "format mentions ns/op")

if fails == 0 then print("[+] PASS test_bench") os.exit(0) else os.exit(1) end
