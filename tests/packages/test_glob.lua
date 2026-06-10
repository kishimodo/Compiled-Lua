-- tests/packages/test_glob.lua : bash-style glob pattern matching (pure Lua).
-- Asserts glob.match / compile / expand / translate against KNOWN-CORRECT glob
-- semantics: * and ? stop at separators, ** crosses them, char classes with
-- ranges/negation, brace expansion (incl. nested + multiplied), and the
-- (path,pattern) argument-swap heuristic. Reference is bash/POSIX glob(7).
local ok_req, glob = pcall(require, "glob")
if not ok_req then print("[~] SKIP test_glob") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_glob: " .. tostring(m)) end end

-- (A) '*' : any run of chars EXCEPT a path separator.
ok(glob.match("foo.lua", "*.lua")     == true,  "*.lua matches foo.lua")
ok(glob.match("sub/foo.lua", "*.lua") == false, "*.lua does NOT cross '/' separator")
ok(glob.match("a.txt", "a*")          == true,  "a* matches a.txt")
ok(glob.match("b.txt", "a*")          == false, "a* does not match b.txt")

-- (B) '?' : exactly one char, not a separator.
ok(glob.match("a.c", "?.c")  == true,  "?.c matches a.c")
ok(glob.match("ab.c", "?.c") == false, "?.c does not match ab.c (two chars)")
ok(glob.match("/.c", "?.c")  == false, "?.c does not match separator")

-- (C) char classes: [abc], ranges [a-z], negation [!..] and [^..].
ok(glob.match("b", "[abc]")  == true,  "[abc] matches b")
ok(glob.match("d", "[abc]")  == false, "[abc] does not match d")
ok(glob.match("m", "[a-z]")  == true,  "[a-z] matches m")
ok(glob.match("M", "[a-z]")  == false, "[a-z] does not match uppercase M")
ok(glob.match("M", "[!a-z]") == true,  "[!a-z] negation matches M")
ok(glob.match("m", "[!a-z]") == false, "[!a-z] negation excludes m")
ok(glob.match("M", "[^a-z]") == true,  "[^a-z] negation matches M")

-- (D) '**' : zero or more path components (crosses separators).
ok(glob.match("a/b/c.lua", "**/*.lua") == true, "**/*.lua matches nested a/b/c.lua")
ok(glob.match("c.lua", "**/*.lua")     == true, "**/*.lua matches c.lua (zero leading components)")
ok(glob.match("a/b/d.lua", "a/**")     == true, "a/** matches a/b/d.lua")

-- (E) brace expansion via expand().
local function setEq(list, ...)
    local want, n = {}, 0
    for _, v in ipairs({...}) do want[v] = true; n = n + 1 end
    if #list ~= n then return false end
    for _, v in ipairs(list) do if not want[v] then return false end end
    return true
end
ok(setEq(glob.expand("{a,b,c}.lua"), "a.lua", "b.lua", "c.lua"),
   "expand {a,b,c}.lua -> a.lua,b.lua,c.lua")
ok(setEq(glob.expand("x{1,2}{3,4}"), "x13", "x14", "x23", "x24"),
   "expand x{1,2}{3,4} -> cartesian product of 4")
ok(setEq(glob.expand("a{b,{c,d}}e"), "abe", "ace", "ade"),
   "expand nested a{b,{c,d}}e -> abe,ace,ade")
ok(setEq(glob.expand("nobrace"), "nobrace"),
   "expand with no braces returns the literal as a single element")

-- (F) match() honors brace alternatives.
ok(glob.match("pic.jpg", "*.{png,jpg}") == true,  "*.{png,jpg} matches pic.jpg")
ok(glob.match("pic.gif", "*.{png,jpg}") == false, "*.{png,jpg} does not match pic.gif")

-- (G) compile() returns a reusable matcher fn (path -> bool).
local m = glob.compile("*.txt")
ok(m("a.txt") == true,  "compiled *.txt matches a.txt")
ok(m("a.log") == false, "compiled *.txt rejects a.log")
local mb = glob.compile("{a,b}.txt")
ok(mb("b.txt") == true,  "compiled {a,b}.txt matches b.txt")
ok(mb("c.txt") == false, "compiled {a,b}.txt rejects c.txt")

-- (H) match() argument-swap heuristic: works in (path,pattern) AND (pattern,path)
-- order when only one arg carries glob metacharacters.
ok(glob.match("*.lua", "foo.lua") == true, "match() swaps args when pattern is arg1")

-- (I) both '/' and '\\' are path separators (Windows + POSIX).
ok(glob.match("a\\b.lua", "a/b.lua") == true,  "'\\' input separator matches '/' pattern separator")
ok(glob.match("a\\b.lua", "*.lua")   == false, "* does not cross a '\\' separator either")

-- (J) translate() is the anchored Lua-pattern escape hatch.
ok(glob.translate("*.lua") == "^[^/\\\\]*%.lua$", "translate('*.lua') anchored Lua pattern")
ok(("foo.lua"):find(glob.translate("*.lua")) ~= nil,  "translate output is a usable anchored pattern (match)")
ok(("a/foo.lua"):find(glob.translate("*.lua")) == nil, "translate output stays anchored (no cross-sep)")

if fails == 0 then print("[+] PASS test_glob") os.exit(0) else os.exit(1) end
