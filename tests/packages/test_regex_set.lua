local ok_req, regex_set = pcall(require, "regex_set")
if not ok_req then print("[~] SKIP test_regex_set") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_regex_set: " .. tostring(m)) end end

-- Classic Aho-Corasick textbook example: patterns {he, she, his, hers} over "ushers".
-- Known-correct matches (positions are 1-based into "ushers" = u(1) s(2) h(3) e(4) r(5) s(6)):
--   "she" : start=2 finish=4
--   "he"  : start=3 finish=4
--   "hers": start=3 finish=6
--   "his" : no match
local pats = { "he", "she", "his", "hers" }
local m = regex_set.compile(pats)

ok(m:pattern_count() == 4, "pattern_count should be 4")

-- find_all: collect into a set keyed by "pattern:start:finish" for order-independent checks.
local found = {}
for _, hit in ipairs(m:find_all("ushers")) do
  found[hit.pattern .. ":" .. hit.start .. ":" .. hit.finish] = hit.index
  -- substring integrity: the reported span must equal the pattern text.
  ok(("ushers"):sub(hit.start, hit.finish) == hit.pattern,
     "span " .. hit.start .. ".." .. hit.finish .. " should equal pattern " .. hit.pattern)
end
ok(found["she:2:4"] == 2, "she should match at start=2 finish=4 with index 2")
ok(found["he:3:4"]  == 1, "he should match at start=3 finish=4 with index 1")
ok(found["hers:3:6"] == 4, "hers should match at start=3 finish=6 with index 4")
ok(found["his:1:1"] == nil and found["his:1:3"] == nil, "his should NOT match in ushers")

-- exactly three matches total in ushers
local count = 0
for _ in pairs(found) do count = count + 1 end
ok(count == 3, "exactly 3 matches expected in ushers, got " .. count)

-- matches(): unique, sorted pattern indices. she=2, he=1, hers=4 -> {1,2,4}
local idxs = m:matches("ushers")
ok(#idxs == 3, "matches should return 3 unique indices, got " .. #idxs)
ok(idxs[1] == 1 and idxs[2] == 2 and idxs[3] == 4, "matches should be sorted {1,2,4}")

-- contains_any
ok(m:contains_any("ushers") == true, "contains_any ushers should be true")
ok(m:contains_any("xyz") == false, "contains_any xyz should be false")
ok(m:contains_any("") == false, "contains_any empty should be false")

-- No-overlap / no-match sanity: matches() on a string with none of the patterns
ok(#m:matches("abcdef") == 0, "no patterns in abcdef")

-- Overlapping at end-of-text: pattern equal to whole text.
local m2 = regex_set.compile({ "abc" })
local r2 = m2:find_all("abc")
ok(#r2 == 1 and r2[1].start == 1 and r2[1].finish == 3 and r2[1].pattern == "abc",
   "single full-text match abc -> start=1 finish=3")
ok(m2:contains_any("zzabczz") == true, "abc found inside zzabczz")

-- case_insensitive option: "HE" needle should match lowercase text and vice versa.
local mci = regex_set.compile({ "abc" }, { case_insensitive = true })
ok(mci:contains_any("xxABCxx") == true, "case_insensitive: ABC matches needle abc")
local rci = mci:find_all("xxABCxx")
ok(#rci == 1 and rci[1].start == 3 and rci[1].finish == 5, "case_insensitive span start=3 finish=5")
-- pattern field preserves the ORIGINAL needle (lowercase as compiled)
ok(rci[1].pattern == "abc", "case_insensitive preserves original pattern text 'abc'")

-- Without case_insensitive, "abc" must NOT match "ABC".
local mcs = regex_set.compile({ "abc" })
ok(mcs:contains_any("ABC") == false, "case-sensitive: abc must not match ABC")

-- Duplicate / multiple occurrences: "aa" over "aaaa" -> 3 overlapping matches.
local m3 = regex_set.compile({ "aa" })
local r3 = m3:find_all("aaaa")
ok(#r3 == 3, "aa over aaaa should yield 3 overlapping matches, got " .. #r3)
for _, h in ipairs(r3) do
  ok(h.finish - h.start == 1 and h.pattern == "aa", "each aa match spans 2 chars")
end

-- Empty pattern must error (per source contract).
local okerr = pcall(regex_set.compile, { "" })
ok(okerr == false, "empty pattern should raise an error")

if fails == 0 then print("[+] PASS test_regex_set") os.exit(0) else os.exit(1) end
