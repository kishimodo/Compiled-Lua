local ok_req, hll = pcall(require, "hll")
if not ok_req then print("[~] SKIP test_hll") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_hll: " .. tostring(m)) end end

-- ===== basic shape =====================================================
local h = hll.new(14)
ok(h:size() == 2 ^ 14, "size() should be 2^p = 16384 for p=14, got " .. tostring(h:size()))
ok(hll.new(4):size() == 16, "size() for p=4 should be 16")
ok(hll.new(10):size() == 1024, "size() for p=10 should be 1024")

-- empty estimator counts 0 distinct (all registers zero -> linear counting)
ok(h:count() == 0, "empty hll should count() == 0, got " .. tostring(h:count()))

-- add returns self (chainable)
ok(h:add("x") == h, "add() should return self")

-- ===== precision bounds reject ========================================
ok(not pcall(hll.new, 3), "precision 3 (<4) must be rejected")
ok(not pcall(hll.new, 19), "precision 19 (>18) must be rejected")

-- ===== cardinality within HLL error bound =============================
-- For p registers, standard relative error ~= 1.04 / sqrt(m).
-- We use a tolerance generous enough to never flake but tight enough
-- to catch a broken estimator (e.g. one off by >2x). Distinct inputs
-- are deterministic strings, so the estimate is reproducible.
local function estimate_for(p, n)
    local e = hll.new(p)
    for i = 1, n do e:add("item-" .. i) end
    return e:count()
end

-- p=14, m=16384, std error ~0.81%. Use a wide 6x-the-stderr band so the
-- test is robust across the (fixed, deterministic) hash but still flags a
-- grossly wrong estimate. Allow +/- 8% here.
local function within(actual, expected, frac, label)
    local lo, hi = expected * (1 - frac), expected * (1 + frac)
    ok(actual >= lo and actual <= hi,
       (label or "estimate") .. ": expected ~" .. expected ..
       " (+/-" .. (frac * 100) .. "%), got " .. tostring(actual))
end

within(estimate_for(14, 1000),   1000,  0.08, "p14 n=1000")
within(estimate_for(14, 10000),  10000, 0.08, "p14 n=10000")
within(estimate_for(14, 50000),  50000, 0.08, "p14 n=50000")

-- A lower-precision sketch has a larger error bound; still must be in the
-- right ballpark (not off by 2x). p=10 -> std err ~3.25%; allow +/-15%.
within(estimate_for(10, 5000), 5000, 0.15, "p10 n=5000")

-- Adding the SAME item many times must not inflate the count.
local dup = hll.new(14)
for i = 1, 2000 do dup:add("only-one") end
ok(dup:count() == 1 or dup:count() == 0, -- linear counting on 1 reg rounds to ~1
   "2000x the same item should count ~1, got " .. tostring(dup:count()))

-- ===== merge = union ===================================================
-- Two disjoint sets; merged sketch should estimate the union size.
local a = hll.new(14)
local b = hll.new(14)
for i = 1, 10000 do a:add("a-" .. i) end
for i = 1, 10000 do b:add("b-" .. i) end
ok(a:merge(b) == a, "merge() should return self")
within(a:count(), 20000, 0.08, "merge union p14 2x10000")

-- merge of overlapping sets -> union (not sum). Build x and y sharing items.
local x = hll.new(14)
local y = hll.new(14)
for i = 1, 8000 do x:add("k-" .. i) end
for i = 4001, 12000 do y:add("k-" .. i) end  -- overlap 4001..8000
x:merge(y)
-- union of {1..8000} and {4001..12000} = {1..12000} = 12000 distinct
within(x:count(), 12000, 0.08, "merge overlapping union -> 12000")

-- mismatched precision merge must error
ok(not pcall(function() hll.new(14):merge(hll.new(10)) end),
   "merging different-precision HLLs must error")

-- ===== serialize / deserialize round-trip =============================
-- A sketch and its deserialized copy must report the exact same count and
-- have identical registers (we verify via identical count + identical blob).
local src = hll.new(12)
for i = 1, 3000 do src:add("ser-" .. i) end
local blob = src:serialize()
ok(type(blob) == "string", "serialize() should return a string")
ok(blob:sub(1, 6) == "HLL1|1", "serialized blob should start with header HLL1|<p>")

local restored = hll.deserialize(blob)
ok(restored ~= nil, "module-level deserialize should succeed on a valid blob")
ok(restored:size() == src:size(), "restored size must match source size")
ok(restored:count() == src:count(),
   "restored count must EXACTLY match source count: src=" ..
   tostring(src:count()) .. " restored=" .. tostring(restored:count()))
-- re-serializing the restored sketch must reproduce the identical blob
ok(restored:serialize() == blob, "round-trip serialize(deserialize(blob)) must be identical")

-- instance-method deserialize mutates self and returns self
local inst = hll.new(4)              -- start with a DIFFERENT precision
local ret = inst:deserialize(blob)
ok(ret == inst, "h:deserialize() should return self")
ok(inst:size() == src:size(), "instance deserialize should adopt source size (p=12 -> 4096)")
ok(inst:count() == src:count(), "instance deserialize should adopt source count")

-- corrupt blob is rejected (returns nil + err, does not throw)
local bad, err = hll.deserialize("not a valid hll blob")
ok(bad == nil, "deserialize of garbage should return nil")
ok(type(err) == "string", "deserialize of garbage should return an error message")

-- length-mismatch blob (valid header, wrong body length) rejected
local short = hll.deserialize("HLL1|14|abc")
ok(short == nil, "deserialize with wrong body length should return nil")

if fails == 0 then print("[+] PASS test_hll") os.exit(0) else os.exit(1) end
