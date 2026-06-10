-- tests/packages/test_cpu.lua : processor identification / topology / utilization.
-- Determinism: live hardware values (counts, freq, temp) are NOT printed or
-- asserted to fixed numbers -- only structural invariants and type/shape checks
-- that hold on any x64 Windows host are asserted.
local ok_req, cpu = pcall(require, "cpu")
if not ok_req then
    print("[~] SKIP test_cpu (" .. tostring(cpu) .. ")")
    os.exit(0)
end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_cpu: " .. tostring(m)) end end

-- ===== API surface =========================================================
ok(type(cpu.info) == "function",                 "info is a function")
ok(type(cpu.count) == "function",                "count is a function")
ok(type(cpu.count_physical) == "function",       "count_physical is a function")
ok(type(cpu.utilization) == "function",          "utilization is a function")
ok(type(cpu.per_core_utilization) == "function", "per_core_utilization is a function")
ok(type(cpu.frequency) == "function",            "frequency is a function")
ok(type(cpu.topology) == "function",             "topology is a function")

-- ===== counts ==============================================================
local logical = cpu.count()
ok(type(logical) == "number" and logical >= 1,   "count() >= 1 logical core")
ok(math.floor(logical) == logical,               "count() is integer")

local physical = cpu.count_physical()
ok(type(physical) == "number" and physical >= 1, "count_physical() >= 1")
ok(physical <= logical,                           "physical <= logical cores")

-- ===== utilization in [0,100] ==============================================
local util = cpu.utilization(1)  -- 1ms interval keeps the test fast
ok(type(util) == "number",                        "utilization() returns number")
ok(util >= 0 and util <= 100,                     "utilization() within [0,100]")

local per = cpu.per_core_utilization(1)
ok(type(per) == "table",                          "per_core_utilization() returns table")
-- It may be {} on permission failure; if populated, every entry is in range.
local per_in_range = true
for _, p in ipairs(per) do
    if type(p) ~= "number" or p < 0 or p > 100 then per_in_range = false end
end
ok(per_in_range,                                  "every per-core utilization in [0,100]")

-- ===== topology shape ======================================================
local topo = cpu.topology()
ok(type(topo) == "table",                         "topology() returns table")
ok(type(topo.cores) == "table",                   "topology.cores is a table")
ok(type(topo.caches) == "table",                  "topology.caches is a table")
ok(type(topo.numa_nodes) == "table",              "topology.numa_nodes is a table")
ok(type(topo.packages) == "table",                "topology.packages is a table")
-- Each cache record (if any) has a sane level/type.
local caches_ok = true
local cache_type_set = { unified=true, instruction=true, data=true, trace=true, unknown=true }
for _, c in ipairs(topo.caches) do
    if type(c.level) ~= "number" or not cache_type_set[c.type] then caches_ok = false end
end
ok(caches_ok,                                     "topology caches have numeric level + known type")

-- ===== info() structure ====================================================
local info = cpu.info()
ok(type(info) == "table",                         "info() returns table")
ok(info.cores_logical == logical,                 "info.cores_logical matches count()")
ok(info.cores_physical == physical,               "info.cores_physical matches count_physical()")
ok(type(info.threads_per_core) == "number" and info.threads_per_core >= 1,
                                                  "info.threads_per_core >= 1")
ok(type(info.architecture) == "string",           "info.architecture is a string")
local arch_set = { x86=true, x86_64=true, arm=true, arm64=true, ia64=true, unknown=true }
ok(arch_set[info.architecture],                    "info.architecture is a known value")
ok(type(info.cache) == "table",                    "info.cache is a table")
ok(type(info.features) == "table",                 "info.features is a list table")
-- features list (from feature_list) must be sorted strings.
local feats_sorted, feats_strings = true, true
for i, name in ipairs(info.features) do
    if type(name) ~= "string" then feats_strings = false end
    if i > 1 and info.features[i] < info.features[i-1] then feats_sorted = false end
end
ok(feats_strings,                                  "info.features entries are strings")
ok(feats_sorted,                                   "info.features list is sorted")

-- frequency() returns a positive number or nil; never throws.
local f = cpu.frequency()
ok(f == nil or (type(f) == "number" and f > 0),    "frequency() is nil or positive MHz")
if info.frequency_mhz ~= nil then
    ok(info.frequency_mhz > 0,                      "info.frequency_mhz positive when present")
end

if fails == 0 then print("[+] PASS test_cpu") os.exit(0) else os.exit(1) end
