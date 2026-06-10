-- tests/lua/test_lua54_corners.lua : asserts a batch of Lua 5.4 corner
-- semantics that the JIT/runtime must honor exactly -- string.pack error paths,
-- string.format %q numeric round-tripping and %a, integer/float subtype edges,
-- table.move's overflow guard and metamethod behavior, table.sort's invalid-
-- comparator guard, and pattern back-references / %g / %f / malformed-pattern
-- errors. Runs under the JIT (default). A failure here is a real conformance bug.
local name = "test_lua54_corners"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL " .. name .. ": " .. tostring(m)) end end
local function eq(label, got, exp) ok(got == exp, label .. " (got " .. tostring(got) .. ", want " .. tostring(exp) .. ")") end
local function errs(label, fn, ...) ok(not (pcall(fn, ...)), label .. " (expected error)") end

-- string.pack / unpack error + bounds checks
errs("pack i1 overflow",      string.pack, "i1", 256)
errs("pack c2 too long",      string.pack, "c2", "abc")
errs("unpack past end",       string.unpack, "i4", "ab")
errs("packsize variable 's'", string.packsize, "s4")
eq("pack roundtrip i4", (string.unpack("<i4", string.pack("<i4", -123456))), -123456)
eq("pack roundtrip I8", (string.unpack(">I8", string.pack(">I8", 0xfffffffffffffff))), 0xfffffffffffffff)

-- string.format %q round-trips numbers (Lua 5.4 feature) and %a
eq("%q integer", string.format("%q", 42), "42")
eq("%q 0.1 round-trips", (load("return " .. string.format("%q", 0.1)))(), 0.1)
eq("%q maxinteger round-trips", (load("return " .. string.format("%q", math.maxinteger)))(), math.maxinteger)
eq("%a 1.0", string.format("%a", 1.0), "0x1p+0")

-- integer / float subtype rules
eq("decimal overflow is float", math.type(9223372036854775808), "float")
eq("hex literal wraps to integer", math.type(0x8000000000000000), "integer")
eq("0x8000...=mininteger", 0x8000000000000000, math.mininteger)
eq("tointeger(-2^63)=mininteger", math.tointeger(-(2.0 ^ 63)), math.mininteger)
eq("tointeger(2^63)=nil", math.tointeger(2.0 ^ 63), nil)
errs("tonumber base 37", tonumber, "10", 37)

-- table.move: overflow guard, metamethod-respecting writes (Lua 5.4 uses
-- lua_geti/lua_seti, so __newindex IS honored), and a plain move copies values.
errs("move overflow guard", table.move, { 1 }, 1, math.maxinteger, 2)
do
  local t = setmetatable({}, { __newindex = function() error("newindex fired") end })
  errs("move honors __newindex", table.move, { 10, 20, 30 }, 1, 3, 1, t)
end
do
  local dst = {}
  table.move({ 7, 8, 9 }, 1, 3, 1, dst)
  ok(dst[1] == 7 and dst[2] == 8 and dst[3] == 9, "move copies values into a plain table")
  local ov = { 1, 2, 3, 4, 5 }
  table.move(ov, 2, 5, 1)          -- overlapping shift-left within one table
  ok(ov[1] == 2 and ov[4] == 5, "move handles overlap (shift left)")
end

-- table.sort: an inconsistent comparator must raise, not corrupt memory
do
  local big = {}; for i = 1, 64 do big[i] = i end
  errs("sort invalid order function", table.sort, big, function() return true end)
end

-- pattern matching corners
eq("back-reference", string.match("abcabc", "(%a+)%1"), "abc")
eq("%g printable-non-space", string.match("a b", "%g+"), "a")
eq("%f frontier at start", (string.find("THE", "%f[%a]")), 1)
errs("malformed pattern '('", string.match, "x", "(")
errs("malformed pattern '%'", string.match, "x", "%")

if fails == 0 then print("[+] PASS " .. name) os.exit(0) else os.exit(1) end
