-- 0b/0o numeric literal prefixes + `_` digit separators must be PURE sugar for
-- their canonical Lua spellings: bytecode-identical EXEs for the accepted forms,
-- clean lex errors for the rejected ones.
--
-- Same shape as tools/test-c-syntax.lua: compile both spellings to the SAME
-- file path (so chunk names match) and diff the emitted EXE bytes. That is
-- stronger than diffing a `luac -l` listing -- it proves the full pipeline
-- (lexer -> parser -> bytecode -> IR -> x64 -> PE) cannot distinguish the two
-- spellings. It is the load-bearing check: no existing test uses '_' or 0b/0o,
-- so a lexer defect that produced almost-correct numbers would go unnoticed
-- by every other test.

local NAME = "test-lang-numeric-literals"
local failures = {}
local function fail(fmt, ...) failures[#failures + 1] = string.format(fmt, ...) end

local function run(cmd)
  local p = io.popen('"' .. cmd .. ' 2>&1"')
  if not p then return -1, "" end
  local out = p:read("*a") or ""
  local ok, _, code = p:close()
  return (ok == true) and 0 or (code or 1), out
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local ROOT = trim(select(2, run("git rev-parse --show-toplevel"))):gsub("/", "\\")
local CLUA = ROOT .. "\\build\\bin\\clua-interp.exe"
local AOTC = ROOT .. "\\build\\bin\\aotc.exe"
local TMP  = (os.getenv("TEMP") or ".") .. "\\clua-numlit-" .. tostring(os.time())

local function exists(p)
  local f = io.open(p, "rb"); if f then f:close(); return true end; return false
end
if not exists(CLUA) then
  print("[~] SKIP " .. NAME .. " (clua-interp.exe not built)")
  os.exit(0)
end
if not exists(AOTC) then
  print("[~] SKIP " .. NAME .. " (aotc.exe not built)")
  os.exit(0)
end
os.execute('mkdir "' .. TMP .. '" >nul 2>nul')

-- ---- 1. byte-identity: new spelling vs canonical spelling ------------------
local SRC = TMP .. "\\same.lua"           -- one path, so chunk name matches
local function build_bytes(src)
  local f = io.open(SRC, "wb"); if not f then return nil, "cannot write" end
  f:write(src, "\n"); f:close()
  local exe = TMP .. "\\same.exe"
  os.remove(exe)
  local code, txt = run('"' .. AOTC .. '" -O0 "' .. SRC .. '" -o "' .. exe .. '"')
  if code ~= 0 then return nil, trim(txt):sub(1, 120) end
  local h = io.open(exe, "rb"); if not h then return nil, "no exe produced" end
  local bytes = h:read("*a"); h:close()
  return bytes
end

-- Each pair: sugar-form vs canonical Lua spelling. They must compile to the
-- SAME EXE bytes. `1e1_000` overflows to +inf; both spellings must produce the
-- SAME inf value (float bits identical), which the byte-diff check enforces.
local pairs_to_check = {
  { "0b1010 = 10",             "return 0b1010",        "return 10" },
  { "0B1010 uppercase",        "return 0B1010",        "return 10" },
  { "0o777 = 511",             "return 0o777",         "return 511" },
  { "0O777 uppercase",         "return 0O777",         "return 511" },
  { "0xff still 255",          "return 0xff",          "return 255" },
  { "1_000_000 decimal sep",   "return 1_000_000",     "return 1000000" },
  { "0xdead_beef hex sep",     "return 0xdead_beef",   "return 0xdeadbeef" },
  { "1_000.5 float mantissa",  "return 1_000.5",       "return 1000.5" },
  { "1e1_000 exponent sep",    "return 1e1_000",       "return 1e1000" },
  -- extra coverage, still within the D5 spec
  { "0b0101_0011 binary sep",  "return 0b0101_0011",   "return 83" },
  { "0o12_34 octal sep",       "return 0o12_34",       "return 668" },
  { "1_000_000.5e-2 dec+frac", "return 1_000_000.5e-2","return 1000000.5e-2" },
  { "0xAA_BB uppercase hex",   "return 0xAA_BB",       "return 0xAABB" },
  { "single _ in the middle",  "return 12_34",         "return 1234" },
  -- Wrap-around must match Lua's existing 0xffffffffffffffff = -1 rule:
  -- the 64th bit set wraps to a negative signed value. This encodes -1.
  { "0b wraps like hex",
    "return 0b1111111111111111111111111111111111111111111111111111111111111111",
    "return 0xffffffffffffffff" },
}
local identical = 0
for _, case in ipairs(pairs_to_check) do
  local label, sugar, lua = case[1], case[2], case[3]
  local a, ea = build_bytes(sugar)
  local b, eb = build_bytes(lua)
  if not a or not b then
    fail("%s: a spelling failed to compile (%s)", label, ea or eb)
  elseif a ~= b then
    fail("%s: two spellings emit DIFFERENT bytes (%d vs %d) -- new literal is "
         .. "not pure sugar", label, #a, #b)
  else
    identical = identical + 1
  end
end

-- ---- 2. rejection: malformed spellings must fail to compile ----------------
--
-- Every case here MUST be rejected by the lexer with a clear error. Cases
-- that are structurally valid Lua identifiers (`_1`) are checked separately:
-- `_1` is a legal identifier per Lua's rules, and turning that into a lex
-- error would break `local _1 = 1` everywhere. The right invariant is that
-- `_1` is NOT parsed as the number 1.
local errcases = {
  { "0b_1 sep right after prefix", "return 0b_1",
                                   "'_' digit separator" },
  { "0o_7 sep right after prefix", "return 0o_7",
                                   "'_' digit separator" },
  { "0x_ff sep right after prefix","return 0x_ff",
                                   "'_' digit separator" },
  { "1_ trailing separator",       "return 1_",
                                   "'_' digit separator" },
  { "1__2 doubled separator",      "return 1__2",
                                   "'_' digit separator" },
  { "0b12 non-binary digit",       "return 0b12",
                                   "malformed binary" },
  { "0o89 non-octal digit",        "return 0o89",
                                   "malformed octal" },
  { "0b (no digits)",              "return 0b",
                                   "malformed binary" },
  { "0o (no digits)",              "return 0o",
                                   "malformed octal" },
  { "1_.5 sep before dot",         "return 1_.5",
                                   "'_' digit separator" },
  { "1._5 sep right after dot",    "return 1._5",
                                   "'_' digit separator" },
  { "1e_5 sep right after exp",    "return 1e_5",
                                   "'_' digit separator" },
  { "1e+_5 sep right after sign",  "return 1e+_5",
                                   "'_' digit separator" },
  { "0xdead_ trailing sep in hex", "return 0xdead_",
                                   "'_' digit separator" },
}
local rejected = 0
for _, c in ipairs(errcases) do
  local label, src, want = c[1], c[2], c[3]
  local path = TMP .. "\\err.lua"
  local h = io.open(path, "wb"); h:write(src, "\n"); h:close()
  local code, out = run('"' .. CLUA .. '" "' .. path .. '"')
  if code == 0 then
    fail("rejection %q was accepted (should be a lex error)", label)
  elseif not out:find(want, 1, true) then
    fail("rejection %q gave the wrong error: got %q, expected substring %q",
         label, trim(out):sub(1, 100), want)
  else
    rejected = rejected + 1
  end
end

-- ---- 3. `_1` must still parse as an identifier, NOT the number 1 -----------
--
-- The D5 spec says '_' at the start is invalid AS A DIGIT SEPARATOR. But `_1`
-- is a legal Lua identifier and the lexer never enters read_numeral on `_`.
-- Assert the two behaviours coexist: `_1` used as an identifier still works,
-- and `_1` in expression position resolves to nil (undefined global), NOT to
-- the integer 1 that would result from a bogus leading-'_' acceptance.
do
  local checks = {
    { "local _1 works",              "local _1 = 42 print(_1)",  "42" },
    { "global _1 is nil, not 1",     "print(_1 == nil, _1)",     "true\tnil" },
    { "arithmetic on _1 errors",     "print(1 + _1)",            "attempt to perform arithmetic" },
  }
  for _, c in ipairs(checks) do
    local path = TMP .. "\\id.lua"
    local h = io.open(path, "wb"); h:write(c[2], "\n"); h:close()
    local code, out = run('"' .. CLUA .. '" "' .. path .. '"')
    out = trim(out)
    if c[1] == "arithmetic on _1 errors" then
      if code == 0 or not out:find(c[3], 1, true) then
        fail("_1 check %q: expected failure with %q, got code=%d out=%q",
             c[1], c[3], code, out:sub(1, 80))
      end
    else
      if code ~= 0 or out ~= c[3] then
        fail("_1 check %q: got %q, expected %q", c[1], out, c[3])
      end
    end
  end
end

-- ---- 4. positive behaviour: values match expectations at runtime -----------
--
-- The byte-identity check above already proves the semantics match the
-- canonical Lua spelling. This section is a sanity print so a human running
-- the test sees the numbers the new syntax actually produces.
do
  local prog = [[
print(0b1010, 0o777, 0xff, 1_000_000, 0xdead_beef, 1_000.5, 1e1_000)
print(0b0, 0o0, 0x0, 0b1111_1111)
print(0.5_5, 1_2.3_4, 1e0_5)
]]
  local path = TMP .. "\\pos.lua"
  local h = io.open(path, "wb"); h:write(prog); h:close()
  local code, out = run('"' .. CLUA .. '" "' .. path .. '"')
  if code ~= 0 then
    fail("positive-behaviour program failed: %s", trim(out):sub(1, 100))
  else
    -- 1e1000 overflows to inf on IEEE-754 doubles.
    local want = "10\t511\t255\t1000000\t3735928559\t1000.5\tinf\n"
              .. "0\t0\t0\t255\n"
              .. "0.55\t12.34\t100000.0"
    if trim(out) ~= want then
      fail("positive-behaviour: got %q, want %q",
           trim(out):gsub("\n", " | "), want:gsub("\n", " | "))
    end
  end
end

-- ---- 5. backward-compat: existing numeric syntax unchanged -----------------
--
-- Every Lua numeral that was legal before must remain legal AND parse to the
-- same value.  This is the "we did not regress the 5.4 lexer" gate.
local compat = {
  { "plain int",         'print(42)',              "42" },
  { "plain float",       'print(3.14)',            "3.14" },
  { "hex int",           'print(0xff, 0xFF)',      "255\t255" },
  { "hex float",         'print(0x1p4)',           "16.0" },
  { "exponent",          'print(1e2, 1E2, 2e-3)',  "100.0\t100.0\t0.002" },
  { "leading dot",       'print(.5, .25)',         "0.5\t0.25" },
  { "trailing dot",      'print(5., 10.)',         "5.0\t10.0" },
  { "hex with fraction", 'print(0x1.8p0)',         "1.5" },
  { "integer 0",         'print(0)',               "0" },
  { "big int",           'print(1234567890)',      "1234567890" },
}
for _, case in ipairs(compat) do
  local label, src, want = case[1], case[2], case[3]
  local path = TMP .. "\\compat.lua"
  local f = io.open(path, "wb"); f:write(src, "\n"); f:close()
  local code, out = run('"' .. CLUA .. '" "' .. path .. '"')
  if code ~= 0 then
    fail("compat %q failed to run: %s", label, trim(out):sub(1, 80))
  elseif trim(out) ~= want then
    fail("compat %q gave %q, expected %q", label, trim(out), want)
  end
end

os.execute('rmdir /s /q "' .. TMP .. '" >nul 2>nul')

if #failures > 0 then
  for _, why in ipairs(failures) do print("[-] FAIL " .. NAME .. ": " .. why) end
  os.exit(1)
end
print(("[+] PASS %s (%d/%d spellings emit byte-identical EXEs, %d/%d malformed "
       .. "spellings rejected with a lex error, %d compat cases unchanged)")
      :format(NAME, identical, #pairs_to_check, rejected, #errcases, #compat))
os.exit(0)
