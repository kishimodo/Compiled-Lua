-- tests/packages/test_slug.lua : slug separator escaping + basic slugify.
-- Regression for Lua-pattern injection via the separator: a digit sep used
-- to raise "invalid capture index %5" and an alpha sep ("x" -> pattern "%x"
-- hex class) corrupted output to "xxxxx".
local slug = require "slug"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_slug: " .. tostring(m)) end end

-- slugify: default separator
ok(slug.slugify("a b c") == "a-b-c",                       "default sep '-'")
ok(slug.slugify("Hello World") == "hello-world",           "default lowercases + joins")

-- slugify: alternate separators must be treated literally, not as patterns
ok(slug.slugify("a b c", {separator="_"}) == "a_b_c",      "underscore sep")
ok(slug.slugify("a b c", {separator="x"}) == "axbxc",      "alpha sep 'x' (no '%x' hex-class corruption)")

-- digit sep used to raise "invalid capture index %5"
local okd, rd = pcall(slug.slugify, "a b c", {separator="5"})
ok(okd, "digit sep '5' must not raise: " .. tostring(rd))
ok(rd == "a5b5c", "digit sep '5' yields a5b5c")

-- collapse runs + trim still work with the default separator
ok(slug.slugify("a  b -- c") == "a-b-c",                   "collapse separator runs")
ok(slug.slugify("  hi  ") == "hi",                         "trim leading/trailing sep")

-- unicode_slug honours an alternate separator without pattern injection
ok(slug.unicode_slug("a b c", {separator="x"}) == "axbxc", "unicode_slug alpha sep 'x'")
local oku, ru = pcall(slug.unicode_slug, "a b c", {separator="5"})
ok(oku and ru == "a5b5c", "unicode_slug digit sep '5' yields a5b5c")

-- slug() `allowed` whitelist must re-collapse / trim separators left behind when
-- disallowed bytes are dropped (e.g. "a 1 b" -> "a-1-b", drop '1' -> "a--b" ->
-- "a-b"; leading/trailing separators trimmed too).
ok(slug.slug("a 1 b", {allowed="a-z", separator="-"}) == "a-b",
   "allowed-pass collapses an interior separator run, got '" .. tostring(slug.slug("a 1 b", {allowed="a-z", separator="-"})) .. "'")
ok(slug.slug("1 a b", {allowed="a-z", separator="-"}) == "a-b",
   "allowed-pass trims a leading separator")
ok(slug.slug("a b 9", {allowed="a-z", separator="-"}) == "a-b",
   "allowed-pass trims a trailing separator")
ok(slug.slug("a b c", {allowed="a-z0-9"}) == "a-b-c",
   "allowed-pass leaves a clean slug unchanged")

if fails == 0 then print("[+] PASS test_slug") os.exit(0) else os.exit(1) end
