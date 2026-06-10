-- tests/packages/test_cpuid.lua : x86/x64 CPUID feature detection.
-- Determinism: the actual vendor/brand/features differ per host, so we do NOT
-- print or compare them to fixed strings. We assert structural invariants
-- (string lengths, value ranges, boolean-ness, self-consistency) that hold on
-- ANY x86-64 CPU, plus exercise the package's own decode logic (regs->string,
-- bit decoding) which is what could regress.
local ok_req, cpuid = pcall(require, "cpuid")
if not ok_req then
    print("[~] SKIP test_cpuid (" .. tostring(cpuid) .. ")")
    os.exit(0)
end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_cpuid: " .. tostring(m)) end end

-- ===== raw leaf 0: vendor =================================================
-- This is the most fundamental CPUID call. If the hand-rolled x64 stub /
-- VirtualAlloc trampoline is broken, this is where it shows.
local ok_raw, r0 = pcall(cpuid.raw, 0, 0)
if not ok_raw then
    -- CPUID trampoline could not be created (e.g. non-x86). Skip cleanly.
    print("[~] SKIP test_cpuid (raw CPUID unavailable: " .. tostring(r0) .. ")")
    os.exit(0)
end
ok(type(r0) == "table",                            "raw() returns a table")
ok(type(r0.eax) == "number" and type(r0.ebx) == "number"
   and type(r0.ecx) == "number" and type(r0.edx) == "number",
                                                   "raw() has eax/ebx/ecx/edx numbers")
ok(r0.eax >= 0,                                    "leaf-0 EAX (max basic leaf) >= 0")

-- ===== vendor string ======================================================
local vendor = cpuid.vendor()
ok(type(vendor) == "string",                       "vendor() returns a string")
ok(#vendor == 12,                                  "vendor() is exactly 12 bytes")
-- Vendor is printable ASCII (GenuineIntel / AuthenticAMD / etc).
ok(vendor:match("^[%w_]+$") ~= nil,                "vendor() is printable alnum")

-- ===== family / model / stepping ==========================================
local fam = cpuid.family()
local mod = cpuid.model()
local step = cpuid.stepping()
ok(type(fam) == "number" and fam >= 0,             "family() is a non-negative number")
ok(type(mod) == "number" and mod >= 0 and mod <= 255, "model() in [0,255]")
ok(type(step) == "number" and step >= 0 and step <= 15, "stepping() in [0,15]")
ok(math.floor(fam) == fam,                         "family() is integer")

-- ===== features ===========================================================
local feats = cpuid.features()
ok(type(feats) == "table",                         "features() returns a table")
-- Every feature flag must be a boolean.
local all_bool = true
local count_features = 0
for _, v in pairs(feats) do
    count_features = count_features + 1
    if type(v) ~= "boolean" then all_bool = false end
end
ok(all_bool,                                       "all feature values are booleans")
ok(count_features >= 20,                           "features() exposes many flags")
-- Any x86-64 CPU running this build supports at least SSE2 (it's mandated by
-- the x86-64 baseline) and long mode.
ok(feats.sse2 == true,                             "sse2 present on x86-64 baseline")
ok(feats.fpu == true,                              "fpu present")

-- has() must agree with features().
ok(cpuid.has("sse2") == feats.sse2,                "has('sse2') agrees with features()")
ok(cpuid.has("definitely_not_a_real_feature") == false,
                                                   "has() of unknown feature is false")

-- ===== cache_info =========================================================
local ci = cpuid.cache_info()
ok(type(ci) == "table",                            "cache_info() returns a table")
-- Cache sizes, when present, are positive and line sizes are sane (>= 32 bytes).
local cache_sane = true
for _, k in ipairs({ "l1d", "l1i", "l2", "l3" }) do
    if ci[k] ~= nil and (type(ci[k]) ~= "number" or ci[k] <= 0) then cache_sane = false end
end
for _, k in ipairs({ "l1d_line", "l1i_line", "l2_line", "l3_line" }) do
    if ci[k] ~= nil and (type(ci[k]) ~= "number" or ci[k] < 16) then cache_sane = false end
end
ok(cache_sane,                                     "cache sizes positive, line sizes >= 16")

-- ===== topology ===========================================================
local topo = cpuid.topology()
ok(type(topo) == "table",                          "topology() returns a table")
ok(type(topo.logical) == "number" and topo.logical >= 1,  "topology.logical >= 1")
ok(type(topo.physical) == "number" and topo.physical >= 1, "topology.physical >= 1")
ok(topo.physical <= topo.logical,                  "topology physical <= logical")
ok(type(topo.smt_per_core) == "number" and topo.smt_per_core >= 1, "smt_per_core >= 1")

-- ===== os_support =========================================================
local osr = cpuid.os_support()
ok(type(osr) == "table",                           "os_support() returns a table")
ok(type(osr.xsave) == "boolean",                   "os_support.xsave is boolean")
ok(type(osr.avx) == "boolean",                     "os_support.avx is boolean")
ok(type(osr.avx512) == "boolean",                  "os_support.avx512 is boolean")
-- AVX OS support implies XSAVE OS support (logical invariant of the decode).
if osr.avx then ok(osr.xsave == true,              "avx OS-support implies xsave") end

-- ===== caching consistency: repeated calls return equal values ============
ok(cpuid.vendor() == vendor,                       "vendor() is stable across calls")
ok(cpuid.family() == fam,                          "family() is stable across calls")

if fails == 0 then print("[+] PASS test_cpuid") os.exit(0) else os.exit(1) end
