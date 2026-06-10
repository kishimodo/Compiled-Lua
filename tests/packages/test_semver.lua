-- tests/packages/test_semver.lua : semver parse / compare / satisfies / inc.
local semver = require "semver"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_semver: " .. tostring(m)) end end

-- parse: fields (use method-call form -- .major/.minor/.patch return functions in the
-- wrapped API; use :major() etc., or access raw inner fields via v._inner.major)
local v = semver.parse("1.2.3")
ok(v ~= nil,          "parse returns non-nil")
ok(v:major() == 1,    "major() == 1")
ok(v:minor() == 2,    "minor() == 2")
ok(v:patch() == 3,    "patch() == 3")
ok(v:prerelease() == nil, "no prerelease")

-- parse: pre-release
local vp = semver.parse("2.0.0-alpha.1")
ok(vp ~= nil,             "parse pre-release")
ok(vp:major() == 2,       "pre-release :major()")
ok(vp:prerelease() ~= nil, "pre-release field present")

-- parse: leading 'v'
local vv = semver.parse("v3.4.5")
ok(vv ~= nil and vv:major() == 3 and vv:minor() == 4 and vv:patch() == 5,
   "parse strips leading v")

-- valid / invalid
ok(semver.valid("1.0.0"),  "valid('1.0.0') true")
ok(not semver.valid("foo"), "valid('foo') false")

-- compare
ok(semver.compare("1.0.0", "2.0.0") == -1, "compare lt")
ok(semver.compare("2.0.0", "1.0.0") == 1,  "compare gt")
ok(semver.compare("1.2.3", "1.2.3") == 0,  "compare eq")

-- lt / gt / eq
ok(semver.lt("1.0.0", "1.0.1"),   "lt")
ok(semver.gt("1.0.1", "1.0.0"),   "gt")
ok(semver.eq("1.0.0", "1.0.0"),   "eq")
ok(not semver.eq("1.0.0", "1.0.1"), "not eq")
ok(semver.lte("1.0.0", "1.0.0"),  "lte equal")
ok(semver.lte("1.0.0", "1.0.1"),  "lte less")
ok(semver.gte("1.0.1", "1.0.0"),  "gte greater")

-- pre-release ordering: 1.0.0-alpha < 1.0.0
ok(semver.lt("1.0.0-alpha", "1.0.0"), "pre-release < release")
ok(semver.gt("1.0.0", "1.0.0-alpha"), "release > pre-release")

-- satisfies: exact
ok(semver.satisfies("1.2.3", "1.2.3"),   "satisfies exact")
ok(not semver.satisfies("1.2.4", "1.2.3"), "satisfies exact mismatch")

-- satisfies: range operators
ok(semver.satisfies("1.2.3", ">=1.0.0"),      "satisfies >=")
ok(semver.satisfies("1.2.3", "<2.0.0"),       "satisfies <")
ok(semver.satisfies("1.2.3", ">=1.0.0 <2.0.0"), "satisfies compound range")
ok(not semver.satisfies("2.0.0", ">=1.0.0 <2.0.0"), "compound range excludes upper")

-- satisfies: caret
ok(semver.satisfies("1.2.9", "^1.2.3"), "satisfies caret")
ok(not semver.satisfies("2.0.0", "^1.2.3"), "caret excludes major bump")

-- satisfies: tilde
ok(semver.satisfies("1.2.5", "~1.2.3"), "satisfies tilde")
ok(not semver.satisfies("1.3.0", "~1.2.3"), "tilde excludes minor bump")

-- satisfies: OR
ok(semver.satisfies("2.0.0", "1.x || 2.x"), "satisfies OR second branch")
ok(semver.satisfies("1.5.0", "1.x || 2.x"), "satisfies OR first branch")

-- inc
ok(semver.inc("1.2.3", "patch") == "1.2.4",   "inc patch")
ok(semver.inc("1.2.3", "minor") == "1.3.0",   "inc minor")
ok(semver.inc("1.2.3", "major") == "2.0.0",   "inc major")

-- clean
ok(semver.clean("v1.2.3") == "1.2.3", "clean strips v")
ok(semver.clean("1.2")    == "1.2.0", "clean pads to three components")

-- max_satisfying / min_satisfying
local list = {"1.0.0", "1.2.3", "1.5.0", "2.0.0"}
ok(semver.max_satisfying(list, "^1") == "1.5.0", "max_satisfying ^1")
ok(semver.min_satisfying(list, "^1") == "1.0.0", "min_satisfying ^1")

if fails == 0 then print("[+] PASS test_semver") os.exit(0) else os.exit(1) end
