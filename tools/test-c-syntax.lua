-- C-style syntax must be PURE SUGAR: identical bytecode to the Lua spelling.
--
-- This is the load-bearing test for the whole feature. "The suite passes" would
-- not be enough -- a lexer alias that quietly produced different code would still
-- run correctly on every existing test, because no existing test uses the new
-- syntax. Comparing the emitted bytecode of the two spellings is what actually
-- proves the sugar is sugar.
--
-- Method: compile both spellings to the SAME file path (so the chunk name in the
-- header matches) and diff the full `luac -l -l` listing -- instructions,
-- constants and upvalues. Heap addresses in CLOSURE comments are normalised, since
-- they vary run to run.
--
-- The other half of the contract is backward compatibility, asserted at the end:
-- every construct the new tokens could have broken must still parse and still mean
-- what it meant. In particular `//` must stay floor division and `&`/`|` must stay
-- bitwise -- those are the operators the new doubled forms sit next to.

local NAME = "test-c-syntax"
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
local TMP  = (os.getenv("TEMP") or ".") .. "\\clua-csyn-" .. tostring(os.time())

local function exists(p)
  local f = io.open(p, "rb"); if f then f:close(); return true end; return false
end
if not exists(CLUA) then
  print("[~] SKIP " .. NAME .. " (clua-interp.exe not built)")
  os.exit(0)
end
os.execute('mkdir "' .. TMP .. '" >nul 2>nul')

-- ---- 1. byte-identity: sugar vs the Lua spelling ---------------------------
--
-- Compiled through aotc at -O0 and compared as EMITTED EXE BYTES. That is a
-- stronger claim than comparing bytecode listings: it proves the whole pipeline
-- (parser -> bytecode -> IR -> x64 -> PE) cannot tell the two spellings apart.
local SRC = TMP .. "\\same.lua"          -- one path, so the chunk name matches
local function build_bytes(src)
  local f = io.open(SRC, "wb"); if not f then return nil, "cannot write" end
  f:write(src, "\n"); f:close()
  local exe = TMP .. "\\same.exe"
  os.remove(exe)
  local code, txt = run('"' .. AOTC .. '" -O0 "' .. SRC .. '" -o "' .. exe .. '"')
  if code ~= 0 then return nil, trim(txt):sub(1, 90) end
  local h = io.open(exe, "rb"); if not h then return nil, "no exe produced" end
  local bytes = h:read("*a"); h:close()
  return bytes
end

local pairs_to_check = {
  { "&& -> and",        "local a,b=1,2 print(a && b)",  "local a,b=1,2 print(a and b)" },
  { "|| -> or",         "local a,b=1,2 print(a || b)",  "local a,b=1,2 print(a or b)" },
  { "! -> not",         "local a=1 print(!a)",          "local a=1 print(not a)" },
  { "!= -> ~=",         "local a,b=1,2 print(a != b)",  "local a,b=1,2 print(a ~= b)" },
  { "nested mix",       "local a,b=1,2 print(!(a && b) || !a)",
                        "local a,b=1,2 print(not (a and b) or not a)" },
  { "block comment",    "/* c */ local a=1 print(a)",   "--[[ c ]] local a=1 print(a)" },
  { "multiline comment","local a=1\n/* one\n two */\nprint(a)",
                        "local a=1\n--[[ one\n two ]]\nprint(a)" },
  { "stars in comment", "/** a ** b **/ print(1)",      "--[[* a ** b **]] print(1)" },
  -- short-circuit is the case a naive alias could get wrong: the right operand
  -- must not be evaluated when the left decides the result.
  { "short-circuit &&", "local function f() return 1 end local a=false print(a && f())",
                        "local function f() return 1 end local a=false print(a and f())" },
  { "short-circuit ||", "local function f() return 1 end local a=true print(a || f())",
                        "local function f() return 1 end local a=true print(a or f())" },
  { "! on a call",      "local function f() return nil end print(!f())",
                        "local function f() return nil end print(not f())" },
  { "inside a closure", "local function g(x) return !x && true end print(g(false))",
                        "local function g(x) return not x and true end print(g(false))" },
  { "method call + &&", "local t={n=1,f=function(s) return s.n end} print(t:f() && 2)",
                        "local t={n=1,f=function(s) return s.n end} print(t:f() and 2)" },
  { "chained",          "local a,b,c=1,2,3 print(a && b || c && a)",
                        "local a,b,c=1,2,3 print(a and b or c and a)" },
  { "!= in a while",    "local i=0 while i != 3 do i=i+1 end print(i)",
                        "local i=0 while i ~= 3 do i=i+1 end print(i)" },
  { "&& in an if",      "for i=1,3 do if i>1 && i<3 then print(i) end end",
                        "for i=1,3 do if i>1 and i<3 then print(i) end end" },
}

local identical = 0
for _, case in ipairs(pairs_to_check) do
  local label, sugar, lua = case[1], case[2], case[3]
  local a, ea = build_bytes(sugar)
  local b, eb = build_bytes(lua)
  if not a or not b then
    fail("%s: a spelling failed to compile (%s)", label, ea or eb)
  elseif a ~= b then
    fail("%s: the two spellings emit DIFFERENT bytes (%d vs %d) -- the alias is "
         .. "not pure sugar", label, #a, #b)
  else
    identical = identical + 1
  end
end

-- ---- 2. backward compatibility: nothing existing changed meaning -----------
--
-- Each entry is a program plus the exact output it must produce. The operators
-- adjacent to the new tokens are the point: // must stay floor division, & and |
-- must stay bitwise, and -- must still start a comment.
local compat = {
  { "floor division",   'print(7 // 2)',                    "3" },
  { "bitwise and",      'print(6 & 3)',                     "2" },
  { "bitwise or",       'print(6 | 3)',                      "7" },
  { "bitwise xor/not",  'print(6 ~ 3, ~0)',                 "5\t-1" },
  { "shifts",           'print(1 << 4, 256 >> 4)',          "16\t16" },
  { "line comment",     'print(1) -- print(2)',             "1" },
  { "long comment",     'print(1) --[[ x ]] print(2)',      "1\n2" },
  { "not equal tilde",  'print(1 ~= 2)',                    "true" },
  { "and/or still work",'print(1 and 2, nil or 3)',         "2\t3" },
  { "not still works",  'print(not nil)',                   "true" },
  -- '!' and '/' inside strings and comments must be untouched
  { "bang in a string", 'print("a!=b", "x && y", "/* z */")', "a!=b\tx && y\t/* z */" },
  { "div then unary",   'print(6 / 2, -(3))',               "3.0\t-3" },
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

-- ---- 3. the new syntax actually behaves correctly --------------------------
do
  local prog = [[
local t, f = true, false
print(t && f, f && t, t && t, f && f)
print(t || f, f || t, t || t, f || f)
print(!t, !f, !nil, !0)
print(1 != 2, 2 != 2, "a" != "b")
/* short-circuit: g must NOT be called */
local called = false
local function g() called = true return true end
local _ = f && g()
print("short-circuited:", not called)
local _ = t || g()
print("still short-circuited:", not called)
]]
  local path = TMP .. "\\behave.lua"
  local h = io.open(path, "wb"); h:write(prog); h:close()
  local code, out = run('"' .. CLUA .. '" "' .. path .. '"')
  local want = "false\tfalse\ttrue\tfalse\n"
            .. "true\ttrue\ttrue\tfalse\n"
            .. "false\ttrue\ttrue\tfalse\n"
            .. "true\tfalse\ttrue\n"
            .. "short-circuited:\ttrue\n"
            .. "still short-circuited:\ttrue"
  if code ~= 0 then
    fail("behaviour program failed: %s", trim(out):sub(1, 100))
  elseif trim(out) ~= want then
    fail("behaviour mismatch.\n  got:  %s\n  want: %s",
         (trim(out):gsub("\n", " | ")), (want:gsub("\n", " | ")))
  end
end

-- ---- 4. an unterminated block comment names the OPENING line ---------------
do
  local path = TMP .. "\\unterm.lua"
  local f = io.open(path, "wb")
  f:write('print(1)\n/* opened here\nstill going\nand going\n')
  f:close()
  local code, out = run('"' .. CLUA .. '" "' .. path .. '"')
  if code == 0 then
    fail("an unterminated block comment was accepted")
  elseif not out:find("unfinished block comment", 1, true) then
    fail("unterminated comment error does not say so: %s", trim(out):sub(1, 90))
  elseif not out:find("line 2", 1, true) then
    fail("unterminated comment should name the OPENING line (2), got: %s",
         trim(out):sub(1, 90))
  end
end

os.execute('rmdir /s /q "' .. TMP .. '" >nul 2>nul')

if #failures > 0 then
  for _, why in ipairs(failures) do print("[-] FAIL " .. NAME .. ": " .. why) end
  os.exit(1)
end
print(("[+] PASS %s (%d/%d sugar pairs emit byte-identical EXEs, %d compatibility "
       .. "cases unchanged, short-circuit and comment errors verified)")
      :format(NAME, identical, #pairs_to_check, #compat))
os.exit(0)
