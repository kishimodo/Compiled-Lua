-- tests/packages/test_profile.lua : sampling profiler.
-- Determinism trap: real profiling samples depend on os.clock + scheduling and
-- are NON-deterministic. We therefore (a) test session state transitions +
-- error paths, and (b) feed HAND-BUILT sample data to the formatters and assert
-- the deterministic aggregation (tree/flame), never live-captured timings.
local ok_req, profile = pcall(require, "profile")
if not ok_req then print("[~] SKIP test_profile (" .. tostring(profile) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_profile: " .. tostring(m)) end end

-- ---- Session state transitions ----
ok(profile.is_active() == false, "no active session at start")
profile.start({ count = 1000000 })   -- huge count so the hook ~never fires during this test
ok(profile.is_active() == true,  "is_active true after start")
-- Starting again while active must error.
ok(not pcall(profile.start), "start() while already profiling errors")
local data = profile.stop()
ok(profile.is_active() == false, "is_active false after stop")
ok(type(data) == "table",        "stop returns a data table")
ok(data.mode == "cpu",           "default mode is cpu")
ok(type(data.samples) == "table","data carries a samples list")
ok(type(data.total_samples) == "number", "data carries a total_samples count")

-- stop() while not profiling must error.
ok(not pcall(profile.stop), "stop() while not profiling errors")

-- ---- with(): runs fn, returns result + data, and clears the session ----
local res, pdata = profile.with(function() return 7 end, { count = 1000000 })
ok(res == 7,                     "with() returns the body's result")
ok(type(pdata) == "table",       "with() returns profile data")
ok(profile.is_active() == false, "with() clears the active session")

-- ---- Formatters over HAND-BUILT deterministic sample data ----
-- Two stacks: A;B occurs twice (leaf B), A;C occurs once (leaf C).
local fixed = {
    mode = "cpu", rate_hz = 100, started = 0.0, stopped = 1.0,
    total_samples = 3,
    samples = {
        { ts = 0.1, stack = { "f.lua:2:B", "f.lua:1:A" } },  -- leaf-first
        { ts = 0.2, stack = { "f.lua:2:B", "f.lua:1:A" } },
        { ts = 0.3, stack = { "f.lua:3:C", "f.lua:1:A" } },
    },
}

-- tree: hot frame A appears with total=3; B with total=2, C with total=1.
local tree = profile.format(fixed, "tree")
ok(type(tree) == "string",                     "format(tree) returns a string")
ok(tree:find("3 samples", 1, true) ~= nil,     "tree header reports 3 samples")
ok(tree:find("f.lua:1:A", 1, true) ~= nil,     "tree includes the root frame A")
ok(tree:find("f.lua:2:B", 1, true) ~= nil,     "tree includes the leaf frame B")
ok(tree:find("f.lua:3:C", 1, true) ~= nil,     "tree includes the leaf frame C")

-- flame: collapsed-stack format, root-to-leaf joined by ';' with a count.
-- A;B occurs twice -> "...A;...B 2"; A;C once -> "...A;...C 1".
local flame = profile.format(fixed, "flame")
ok(type(flame) == "string",                    "format(flame) returns a string")
ok(flame:find("f.lua:1:A;f.lua:2:B 2", 1, true) ~= nil,
   "flame folds the A;B stack with count 2")
ok(flame:find("f.lua:1:A;f.lua:3:C 1", 1, true) ~= nil,
   "flame folds the A;C stack with count 1")
-- flame lines are sorted (deterministic ordering); A;B sorts before A;C.
local ab = flame:find("f.lua:1:A;f.lua:2:B", 1, true)
local ac = flame:find("f.lua:1:A;f.lua:3:C", 1, true)
ok(ab ~= nil and ac ~= nil and ab < ac, "flame output is sorted deterministically")

-- chrome_trace requires json; if present it must emit valid JSON with events.
local okj, json = pcall(require, "json")
if okj and json then
    local ct = profile.format(fixed, "chrome_trace")
    ok(type(ct) == "string", "format(chrome_trace) returns a string")
    local decoded = json.decode(ct)
    ok(type(decoded.traceEvents) == "table" and #decoded.traceEvents == 3,
       "chrome_trace has one event per sample")
else
    print("[~] SKIP test_profile chrome_trace section (json unavailable)")
end

-- Unknown format kind errors.
ok(not pcall(profile.format, fixed, "bogus-format"), "format errors on an unknown kind")

if fails == 0 then print("[+] PASS test_profile") os.exit(0) else os.exit(1) end
