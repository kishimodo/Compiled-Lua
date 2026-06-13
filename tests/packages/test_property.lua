-- tests/packages/test_property.lua : QuickCheck-style property testing.
-- Determinism: we always pass a FIXED opts.seed so generation is replayable,
-- and we assert outcomes/invariants that hold for ANY generated value.
local ok_req, property = pcall(require, "property")
if not ok_req then print("[~] SKIP test_property (" .. tostring(property) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_property: " .. tostring(m)) end end
-- XFAIL helper (CLAUDE.md convention): keep the CORRECT invariant for a known,
-- unfixed bug visible without failing the run.
local function xfail(cond, desc, bug)
    if cond then print(("[!] XPASS test_property: %s -- bug %s appears FIXED, remove this xfail"):format(desc, bug))
    else        print(("[x] XFAIL test_property: %s (known bug %s)"):format(desc, bug)) end
end

local SEED = 12345  -- fixed seed -> deterministic generation

-- int generator respects bounds across every generated value.
local g_int = property.int(0, 9)
local res = property.check(function(x)
    return x >= 0 and x <= 9 and math.type(x) == "integer"
end, { g_int }, { seed = SEED, num_tests = 50 })
ok(res.ok == true,            "int(0,9) always produces in-range integers")
ok(res.tests_run == 50,       "all 50 tests ran for a passing property")
ok(res.seed == SEED,          "the seed is echoed back for replay")

-- A property that is always true should never produce a counterexample.
local res_true = property.check(function(x) return type(x) == "boolean" end,
                                { property.bool() }, { seed = SEED, num_tests = 30 })
ok(res_true.ok == true,       "bool generator always yields a boolean")

-- A property that is always FALSE must fail and report a counterexample.
local res_false = property.check(function(_) return false end,
                                 { property.int(1, 100) }, { seed = SEED, num_tests = 20 })
ok(res_false.ok == false,     "an always-false property fails")
ok(res_false.counterexample ~= nil, "a counterexample is reported on failure")
ok(res_false.tests_run >= 1,  "failure recorded on the first failing test")

-- Shrinking: a property 'x < 5' fails for big ints; the shrunk counterexample
-- should be the boundary value 5 (smallest int violating x < 5 within range).
local res_shrink = property.check(function(x) return x < 5 end,
                                  { property.int(0, 1000) }, { seed = SEED, num_tests = 100 })
ok(res_shrink.ok == false,    "x<5 fails on a 0..1000 generator")
ok(res_shrink.counterexample[1] == 5,
   "shrinking finds the minimal counterexample 5 (got " ..
   tostring(res_shrink.counterexample[1]) .. ")")

-- string generator always yields a string value (type is correct).
local g_str = property.string({ min_len = 2, max_len = 6 })
local res_type = property.check(function(s) return type(s) == "string" end,
                                { g_str }, { seed = SEED, num_tests = 40 })
ok(res_type.ok == true,       "string generator always yields a string value")

-- PROP-STRLEN-001 fixed: string()'s char picker now uses ONE random index
-- (alphabet:sub(j, j)), so each element is exactly one character and the final
-- length respects [min_len, max_len]. (The old code passed two independent
-- indices to string.sub, yielding variable-length slices that undershot min_len
-- and overshot max_len.)
local res_bounds = property.check(function(s)
    return type(s) == "string" and #s >= 2 and #s <= 6
end, { g_str }, { seed = SEED, num_tests = 40 })
ok(res_bounds.ok == true,
   "string(min=2,max=6) keeps 2 <= #s <= 6 (PROP-STRLEN-001)")

-- array_of generator honors length bounds and element type.
local g_arr = property.array_of(property.int(0, 5), 1, 4)
local res_arr = property.check(function(a)
    if type(a) ~= "table" then return false end
    if #a < 1 or #a > 4 then return false end
    for i = 1, #a do if a[i] < 0 or a[i] > 5 then return false end end
    return true
end, { g_arr }, { seed = SEED, num_tests = 40 })
ok(res_arr.ok == true,        "array_of(int,1,4) respects length + element bounds")

-- map: post-transform applies. Generate ints, map to their double; assert even.
local g_even = property.map(property.int(0, 50), function(x) return x * 2 end)
local res_even = property.check(function(x) return x % 2 == 0 end,
                                { g_even }, { seed = SEED, num_tests = 30 })
ok(res_even.ok == true,       "map doubling always yields an even number")

-- filter: only values passing the predicate are produced.
local g_pos = property.filter(property.int(-50, 50), function(x) return x > 0 end)
local res_pos = property.check(function(x) return x > 0 end,
                               { g_pos }, { seed = SEED, num_tests = 30 })
ok(res_pos.ok == true,        "filter keeps only positive ints")

-- record: generated table has exactly the declared fields, each in range.
local g_rec = property.record({ a = property.int(1, 3), b = property.bool() })
local res_rec = property.check(function(r)
    return type(r.a) == "number" and r.a >= 1 and r.a <= 3 and type(r.b) == "boolean"
end, { g_rec }, { seed = SEED, num_tests = 30 })
ok(res_rec.ok == true,        "record yields the declared typed fields")

-- Two generators at once: property over both args.
local res_two = property.check(function(x, y) return (x + y) == (y + x) end,
                               { property.int(0, 10), property.int(0, 10) },
                               { seed = SEED, num_tests = 30 })
ok(res_two.ok == true,        "addition commutes across two int generators")

-- prop() builder: name + gens + body, runnable via :run.
local p = property.prop("nonneg-square", property.int(-20, 20), function(x)
    return (x * x) >= 0
end)
ok(p.name == "nonneg-square", "prop() records the property name")
local pres = p.run({ seed = SEED, num_tests = 25 })
ok(pres.ok == true,           "prop():run executes the body as a property")

-- Determinism check: same seed -> same first generated int.
local g = property.int(0, 1000000)
local function first_value(seed)
    local captured
    property.check(function(x) captured = x; return true end, { g },
                   { seed = seed, num_tests = 1 })
    return captured
end
ok(first_value(777) == first_value(777),
   "same seed reproduces the same first generated value")

if fails == 0 then print("[+] PASS test_property") os.exit(0) else os.exit(1) end
