-- tests/packages/test_assert_ex.lua : rich-assertion library behavior.
-- Pure-Lua package; the runner compiles it with compiler.exe then runs it.
-- We assert that each helper PASSES on the true case and RAISES on the false
-- case (and that fluent chains / negation / custom matchers behave).
local ok_req, assert_ex = pcall(require, "assert_ex")
if not ok_req then print("[~] SKIP test_assert_ex") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_assert_ex: " .. tostring(m)) end end

-- A helper that PASSES iff the assertion call returns without raising.
local function passes(fn) return (pcall(fn)) end
-- A helper that PASSES iff the assertion call raises.
local function raises(fn) return not (pcall(fn)) end

-- ===== equal / not_equal (deep) =====
ok(passes(function() assert_ex.equal(1, 1) end),                     "equal: scalars match")
ok(passes(function() assert_ex.equal({a=1,b={2,3}}, {a=1,b={2,3}}) end), "equal: deep tables match")
ok(raises(function() assert_ex.equal(1, 2) end),                     "equal: distinct scalars raise")
ok(raises(function() assert_ex.equal({1,2}, {1,2,3}) end),           "equal: extra key raises")
ok(raises(function() assert_ex.equal({a=1}, {a=2}) end),            "equal: differing value raises")
-- NaN is treated as equal to NaN per the source contract.
local nan = 0/0
ok(passes(function() assert_ex.equal(nan, nan) end),                "equal: NaN equals NaN")
ok(passes(function() assert_ex.not_equal(1, 2) end),               "not_equal: distinct passes")
ok(raises(function() assert_ex.not_equal({1}, {1}) end),           "not_equal: equal raises")

-- ===== near =====
ok(passes(function() assert_ex.near(1.0, 1.0 + 1e-12) end),         "near: within default eps")
ok(raises(function() assert_ex.near(1.0, 1.5, 0.1) end),            "near: outside eps raises")
ok(raises(function() assert_ex.near("x", 1) end),                  "near: non-number raises")
ok(passes(function() assert_ex.near(10, 11, 2) end),               "near: custom eps passes")

-- ===== truthy / falsy =====
ok(passes(function() assert_ex.truthy(1) end),                      "truthy: number passes")
ok(passes(function() assert_ex.truthy("") end),                    "truthy: empty string is truthy")
ok(raises(function() assert_ex.truthy(false) end),                 "truthy: false raises")
ok(raises(function() assert_ex.truthy(nil) end),                   "truthy: nil raises")
ok(passes(function() assert_ex.falsy(false) end),                  "falsy: false passes")
ok(passes(function() assert_ex.falsy(nil) end),                    "falsy: nil passes")
ok(raises(function() assert_ex.falsy(0) end),                      "falsy: 0 is truthy so raises")

-- ===== is_nil / not_nil / nil_ =====
ok(passes(function() assert_ex.is_nil(nil) end),                    "is_nil: nil passes")
ok(raises(function() assert_ex.is_nil(0) end),                      "is_nil: 0 raises")
ok(passes(function() assert_ex.nil_(nil) end),                      "nil_: alias passes")
ok(passes(function() assert_ex.not_nil(0) end),                     "not_nil: value passes")
ok(raises(function() assert_ex.not_nil(nil) end),                   "not_nil: nil raises")

-- ===== is_type / is_a =====
ok(passes(function() assert_ex.is_type("x", "string") end),         "is_type: string passes")
ok(raises(function() assert_ex.is_type(1, "string") end),           "is_type: mismatch raises")
ok(passes(function() assert_ex.is_a({}, "table") end),              "is_a: alias passes")

-- ===== contains (string + table) =====
ok(passes(function() assert_ex.contains("hello world", "world") end), "contains: substring passes")
ok(raises(function() assert_ex.contains("hello", "zzz") end),       "contains: missing substring raises")
ok(passes(function() assert_ex.contains({1,2,3}, 2) end),           "contains: table value passes")
ok(passes(function() assert_ex.contains({{x=1}}, {x=1}) end),       "contains: deep table value passes")
ok(raises(function() assert_ex.contains({1,2,3}, 9) end),           "contains: missing value raises")
-- contains uses PLAIN find: a Lua pattern char must be literal, not magic.
ok(raises(function() assert_ex.contains("abc", "a.c") end),         "contains: plain (non-pattern) miss raises")

-- ===== matches / not_match (Lua patterns) =====
ok(passes(function() assert_ex.matches("abc123", "%a+%d+") end),    "matches: pattern passes")
ok(raises(function() assert_ex.matches("abc", "%d+") end),          "matches: no digit raises")
ok(passes(function() assert_ex.not_match("abc", "%d+") end),        "not_match: absent pattern passes")
ok(raises(function() assert_ex.not_match("abc1", "%d+") end),       "not_match: present pattern raises")

-- ===== pcontains (pattern find) =====
ok(passes(function() assert_ex.pcontains("abc", "a.c") end),        "pcontains: pattern matches")
ok(raises(function() assert_ex.pcontains("abc", "%d") end),         "pcontains: no digit raises")

-- ===== throws / not_throws =====
local function boom() error("kaboom 42") end
ok(passes(function() assert_ex.throws(boom) end),                   "throws: throwing fn passes")
ok(passes(function() assert_ex.throws(boom, "kaboom") end),         "throws: pattern matches")
ok(raises(function() assert_ex.throws(function() end) end),         "throws: non-throwing raises")
ok(raises(function() assert_ex.throws(boom, "no_such") end),        "throws: wrong pattern raises")
-- throws returns the captured error object.
local captured = assert_ex.throws(boom)
ok(type(captured) == "string" and captured:match("kaboom 42"),     "throws: returns error message")
ok(passes(function() assert_ex.not_throws(function() return 1 end) end), "not_throws: clean fn passes")
ok(raises(function() assert_ex.not_throws(boom) end),              "not_throws: throwing raises")

-- ===== has_key =====
ok(passes(function() assert_ex.has_key({k=1}, "k") end),            "has_key: present passes")
ok(raises(function() assert_ex.has_key({k=1}, "z") end),            "has_key: absent raises")
ok(raises(function() assert_ex.has_key("notatable", "k") end),      "has_key: non-table raises")

-- ===== length / len =====
ok(passes(function() assert_ex.length({1,2,3}, 3) end),             "length: table count passes")
ok(passes(function() assert_ex.length("abcd", 4) end),              "length: string len passes")
ok(raises(function() assert_ex.length({1,2}, 5) end),              "length: mismatch raises")
ok(passes(function() assert_ex.len("ab", 2) end),                  "len: alias passes")

-- ===== empty =====
ok(passes(function() assert_ex.empty({}) end),                      "empty: empty table passes")
ok(passes(function() assert_ex.empty("") end),                     "empty: empty string passes")
ok(raises(function() assert_ex.empty({1}) end),                    "empty: non-empty table raises")
ok(raises(function() assert_ex.empty("x") end),                    "empty: non-empty string raises")

-- ===== same / same_shape =====
ok(passes(function() assert_ex.same({a=1}, {a=1}) end),             "same: alias of equal passes")
ok(passes(function() assert_ex.same_shape({a=1,b={2}}, {a=99,b={7}}) end), "same_shape: shape match ignores values")
ok(raises(function() assert_ex.same_shape({a=1}, {a=1,b=2}) end),  "same_shape: extra key raises")

-- ===== keys =====
ok(passes(function() assert_ex.keys({a=1,b=2}, {"a","b"}) end),     "keys: exact key set passes")
ok(raises(function() assert_ex.keys({a=1}, {"a","b"}) end),         "keys: missing key raises")
ok(raises(function() assert_ex.keys({a=1,b=2,c=3}, {"a","b"}) end), "keys: extra key raises")

-- ===== register (custom matcher) =====
assert_ex.register("even", function(v) return type(v) == "number" and v % 2 == 0 end)
ok(passes(function() assert_ex.even(4) end),                        "register: custom matcher passes")
ok(raises(function() assert_ex.even(3) end),                        "register: custom matcher raises")
ok(raises(function() assert_ex.register("x", 5) end),              "register: bad args raise")

-- ===== fluent chain: expect(...) =====
ok(passes(function() assert_ex.expect(5).to.equal(5) end),          "expect: .to.equal passes")
ok(raises(function() assert_ex.expect(5).to.equal(6) end),          "expect: .to.equal mismatch raises")
-- The working type-check verb is `.type(name)`.
ok(passes(function() assert_ex.expect("hi").to.type("string") end), "expect: .to.type(name) passes")
ok(raises(function() assert_ex.expect("hi").to.type("number") end), "expect: .to.type mismatch raises")
-- BUG: the module documents `.to.be.a("string")` (init.lua header + the
-- `Chain:type` doc comment promising `:a()/:an()`), but `a`/`an` are registered
-- only as no-op sugar nouns that resolve to the chain table itself -- so calling
-- `.a("string")` is "attempt to call a table value". This assertion asserts the
-- DOCUMENTED behavior and therefore fails until the package wires `a`/`an` to
-- the type check.
ok(passes(function() assert_ex.expect("hi").to.be.a("string") end), "expect: .to.be.a(type) passes (DOCUMENTED API)")
ok(passes(function() assert_ex.expect({1,2,3}).to.contain(2) end),  "expect: .contain passes")
ok(passes(function() assert_ex.expect("abc1").to.match("%d") end),  "expect: .match passes")
ok(passes(function() assert_ex.expect({1,2,3}).to.length(3) end),   "expect: .length passes")
ok(passes(function() assert_ex.expect(1).to.truthy() end),          "expect: .truthy passes")
ok(passes(function() assert_ex.expect(nil).to.falsy() end),         "expect: .falsy passes")
ok(passes(function() assert_ex.expect(1.0).to.near(1.0, 1e-6) end), "expect: .near passes")

-- chained multiple expectations on one value (using working verbs)
ok(passes(function()
    assert_ex.expect("string").to.type("string").and_to.equal("string")
end), "expect: chained and_to passes")

-- throw via chain (value must be a function)
ok(passes(function() assert_ex.expect(boom).to.throw("kaboom") end), "expect: .throw passes")
ok(raises(function() assert_ex.expect(function() end).to.throw() end), "expect: .throw on clean fn raises")

-- ===== fluent chain: negation via :not_() =====
ok(passes(function() assert_ex.expect(5):not_():equal(6) end),      "expect: not_ equal differs passes")
ok(raises(function() assert_ex.expect(5):not_():equal(5) end),      "expect: not_ equal same raises")

if fails == 0 then print("[+] PASS test_assert_ex") os.exit(0) else os.exit(1) end
