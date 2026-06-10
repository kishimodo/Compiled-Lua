-- tests/packages/test_memory_info.lua : system + per-process memory reporting.
-- Determinism: actual MB figures vary, so we assert arithmetic invariants
-- (used = total - available, available <= total, load in [0,100]) and the
-- page_size() value (4096 on x64 Windows, a fixed hardware constant here).
local ok_req, mi = pcall(require, "memory_info")
if not ok_req then
    print("[~] SKIP test_memory_info (" .. tostring(mi) .. ")")
    os.exit(0)
end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_memory_info: " .. tostring(m)) end end

ok(type(mi.system) == "function",              "system is a function")
ok(type(mi.process) == "function",             "process is a function")
ok(type(mi.working_set_detail) == "function",  "working_set_detail is a function")
ok(type(mi.page_size) == "function",           "page_size is a function")

-- ===== page_size: a fixed hardware constant on x64 Windows =================
local ps = mi.page_size()
ok(type(ps) == "number",                       "page_size() returns a number")
ok(ps == 4096,                                 "page_size() is 4096 on x64 Windows")
-- power-of-two sanity (would also pass for 4096)
ok((ps & (ps - 1)) == 0,                       "page_size() is a power of two")

-- ===== system() invariants =================================================
local sys = mi.system()
ok(type(sys) == "table",                       "system() returns a table")
ok(type(sys.total_mb) == "number" and sys.total_mb > 0, "total_mb > 0")
ok(type(sys.available_mb) == "number",         "available_mb is a number")
ok(type(sys.used_mb) == "number",              "used_mb is a number")
ok(sys.available_mb >= 0,                      "available_mb non-negative")
ok(sys.available_mb <= sys.total_mb,           "available <= total")
ok(sys.used_mb <= sys.total_mb,                "used <= total")
-- used = total - available (both floored to MB; floor(total)-floor(avail) can
-- differ from floor(total-avail) by at most 1, so allow a 1 MB slack).
ok(math.abs(sys.used_mb - (sys.total_mb - sys.available_mb)) <= 1,
                                               "used_mb == total_mb - available_mb (+-1)")
ok(type(sys.memory_load) == "number" and sys.memory_load >= 0 and sys.memory_load <= 100,
                                               "memory_load in [0,100]")
ok(type(sys.free_pct) == "number" and sys.free_pct >= 0 and sys.free_pct <= 100,
                                               "free_pct in [0,100]")
ok(type(sys.total_pagefile_mb) == "number" and sys.total_pagefile_mb > 0,
                                               "total_pagefile_mb > 0")
ok(sys.available_pagefile_mb <= sys.total_pagefile_mb, "avail pagefile <= total pagefile")
ok(type(sys.total_virtual_mb) == "number" and sys.total_virtual_mb > 0,
                                               "total_virtual_mb > 0")
ok(sys.available_virtual_mb <= sys.total_virtual_mb, "avail virtual <= total virtual")
-- memory_load ~ (1 - avail/total) * 100, so roughly complements free_pct.
ok(math.abs(sys.memory_load + sys.free_pct - 100) <= 2,
                                               "memory_load + free_pct ~= 100")

-- ===== process() for the current process ===================================
local proc = mi.process()  -- nil pid -> current process
ok(type(proc) == "table",                      "process() returns a table")
ok(type(proc.working_set_mb) == "number" and proc.working_set_mb >= 0,
                                               "working_set_mb >= 0")
ok(type(proc.peak_working_set_mb) == "number", "peak_working_set_mb is a number")
ok(proc.working_set_mb <= proc.peak_working_set_mb, "working_set <= peak_working_set")
ok(type(proc.page_faults) == "number" and proc.page_faults >= 0, "page_faults >= 0")
ok(type(proc.pagefile_usage_mb) == "number",   "pagefile_usage_mb is a number")
ok(proc.pagefile_usage_mb <= proc.peak_pagefile_mb, "pagefile <= peak pagefile")
ok(type(proc.private_bytes_mb) == "number" and proc.private_bytes_mb >= 0,
                                               "private_bytes_mb >= 0")
-- private_working_set_mb is filled only for processes <= 256 MB resident.
if proc.private_working_set_mb ~= nil then
    ok(proc.private_working_set_mb >= 0,       "private_working_set_mb >= 0")
    ok(proc.private_working_set_mb <= proc.working_set_mb,
                                               "private working set <= working set")
end

-- ===== working_set_detail: shape only (count varies) =======================
local ws = mi.working_set_detail()
ok(type(ws) == "table",                        "working_set_detail() returns a table")
local ws_ok = true
local n_checked = 0
for _, p in ipairs(ws) do
    n_checked = n_checked + 1
    if n_checked > 50 then break end  -- bound the scan; shape is uniform
    if type(p.valid) ~= "boolean" then ws_ok = false end
    if type(p.shared) ~= "boolean" then ws_ok = false end
    if type(p.address) ~= "number" then ws_ok = false end
    if type(p.share_count) ~= "number" then ws_ok = false end
end
ok(ws_ok,                                      "working_set pages have valid/shared/address fields")

if fails == 0 then print("[+] PASS test_memory_info") os.exit(0) else os.exit(1) end
