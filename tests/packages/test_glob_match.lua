-- tests/packages/test_glob_match.lua : gitignore-style matcher. Asserts the two
-- regression fixes -- '**' doublestar (Lua patterns reject a quantifier on a
-- capture group) and anchored '/...' rules must NOT fall back to the basename.
-- Reference behavior is gitignore(5). match() returns (matched, negated).
local glob_match = require "glob_match"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_glob_match: " .. tostring(m)) end end

-- (A) '**' doublestar.
ok(glob_match.compile("**/foo"):match("a/b/foo") == true,  "**/foo matches a/b/foo")
ok(glob_match.compile("**/foo"):match("foo")     == true,  "**/foo matches foo (zero leading components)")
ok(glob_match.compile("a/**/b"):match("a/x/y/b") == true,  "a/**/b matches a/x/y/b")
ok(glob_match.compile("a/**/b"):match("a/b")     == true,  "a/**/b matches a/b (zero components)")
ok(glob_match.compile("doc/**"):match("doc/a/b") == true,  "doc/** matches doc/a/b (trailing-** control)")

-- (B) anchored basename over-match.
ok(glob_match.compile("/*.lua"):match("a/b.lua") == false, "/*.lua does NOT match a/b.lua (anchored)")
ok(glob_match.compile("/*.lua"):match("a.lua")   == true,  "/*.lua matches top-level a.lua")
ok(glob_match.compile("/build"):match("build")   == true,  "/build matches build (anchored at root)")
ok(glob_match.compile("/build"):match("x/build") == false, "/build does NOT match x/build")

if fails == 0 then print("[+] PASS test_glob_match") os.exit(0) else os.exit(1) end
