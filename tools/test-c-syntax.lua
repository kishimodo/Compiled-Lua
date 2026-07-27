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

-- ---- 1b. `continue` emits what the hand-written goto idiom emits -----------
--
-- The reference spelling is `goto continue` + `::continue::` at the end of the
-- body, which is the documented pre-5.4 idiom and is what tests/lua/test_goto.lua
-- already uses. The <close> and upvalue cases are the ones that matter: the label
-- has to land INSIDE the body block, before leaveblock emits the per-iteration
-- OP_CLOSE, or handlers and upvalues leak across iterations.
local continue_pairs = {
  { "numeric for",
    "local s=0 for i=1,5 do if i==3 then continue end s=s+i end print(s)",
    "local s=0 for i=1,5 do if i==3 then goto continue end s=s+i ::continue:: end print(s)" },
  { "generic for",
    "local s=0 for k,v in pairs({1,2,3}) do if v==2 then continue end s=s+v end print(s)",
    "local s=0 for k,v in pairs({1,2,3}) do if v==2 then goto continue end s=s+v ::continue:: end print(s)" },
  { "while",
    "local i=0 local s=0 while i<5 do i=i+1 if i==3 then continue end s=s+i end print(s)",
    "local i=0 local s=0 while i<5 do i=i+1 if i==3 then goto continue end s=s+i ::continue:: end print(s)" },
  { "upvalue in body",
    "local fs={} for i=1,3 do local x=i if i==2 then continue end fs[i]=function() return x end end print(fs[1]())",
    "local fs={} for i=1,3 do local x=i if i==2 then goto continue end fs[i]=function() return x end ::continue:: end print(fs[1]())" },
  { "<close> in body",
    "local n=0 for i=1,3 do local g <close> = setmetatable({},{__close=function() n=n+1 end}) if i==2 then continue end end print(n)",
    "local n=0 for i=1,3 do local g <close> = setmetatable({},{__close=function() n=n+1 end}) if i==2 then goto continue end ::continue:: end print(n)" },
  { "nested loops",
    "local s=0 for i=1,3 do for j=1,3 do if j==2 then continue end s=s+1 end end print(s)",
    "local s=0 for i=1,3 do for j=1,3 do if j==2 then goto continue end s=s+1 ::continue:: end end print(s)" },
  { "continue + break",
    "local s=0 for i=1,9 do if i==2 then continue end if i>4 then break end s=s+i end print(s)",
    "local s=0 for i=1,9 do if i==2 then goto continue end if i>4 then break end s=s+i ::continue:: end print(s)" },
}
local cont_identical = 0
for _, case in ipairs(continue_pairs) do
  local label, sugar, idiom = case[1], case[2], case[3]
  local a, ea = build_bytes(sugar)
  local b, eb = build_bytes(idiom)
  if not a or not b then
    fail("continue %s: a spelling failed to compile (%s)", label, ea or eb)
  elseif a ~= b then
    fail("continue %s: emits different bytes from the goto idiom (%d vs %d)",
         label, #a, #b)
  else
    cont_identical = cont_identical + 1
  end
end

-- `continue` must remain usable as an IDENTIFIER. It is a contextual keyword
-- precisely because repl_debug/init.lua:497 defines `function M.continue()`.
-- The last case is the discriminating one: a local named `continue` and the
-- keyword in the same loop body.
local ident_cases = {
  { "method definition",  'local M={} function M.continue() return "m" end print(M.continue())', "m" },
  { "local named continue",'local continue = 5 print(continue)',                  "5" },
  { "table field",        'local t={continue=1} t.continue=3 print(t.continue)',  "3" },
  { "bracket key",        'local t={} t["continue"]=4 print(t["continue"])',      "4" },
  { "global assignment",  'continue = 9 print(continue)',                          "9" },
  { "method call",        'local o={continue=function(s) return "c" end} print(o:continue())', "c" },
  { "call via field",     'local g={continue=function(x) return x end} print(g.continue(6))',  "6" },
  { "passed as an arg",   'local continue=2 local function f(x) return x end print(f(continue))', "2" },
  { "returned",           'local continue=8 local function f() return continue end print(f())', "8" },
  { "local AND keyword",  'local t={continue=7} local s=0 for i=1,3 do local continue=i s=s+continue+t.continue if i==2 then continue end s=s+1000 end print(s)',
                          "2027" },
}
for _, case in ipairs(ident_cases) do
  local label, src, want = case[1], case[2], case[3]
  local path = TMP .. "\\ident.lua"
  local f = io.open(path, "wb"); f:write(src, "\n"); f:close()
  local code, out = run('"' .. CLUA .. '" "' .. path .. '"')
  if code ~= 0 then
    fail("continue-as-identifier %q failed: %s", label, trim(out):sub(1, 80))
  elseif trim(out) ~= want then
    fail("continue-as-identifier %q gave %q, expected %q", label, trim(out), want)
  end
end

-- The synthetic label must be UNFORGEABLE. A user's own ::continue:: keeps
-- working, and `goto continue` without one is still an error -- if the compiler's
-- label were named "continue" it would silently satisfy that goto.
do
  local checks = {
    { "user label still works",
      'local s=0 for i=1,5 do if i==2 then goto continue end s=s+i ::continue:: end print(s)', "13" },
    { "keyword and user label coexist",
      'local r=0 for i=1,5 do if i==2 then goto continue end if i==4 then continue end r=r+i ::continue:: end print(r)', "9" },
  }
  for _, c in ipairs(checks) do
    local path = TMP .. "\\lbl.lua"
    local f = io.open(path, "wb"); f:write(c[2], "\n"); f:close()
    local code, out = run('"' .. CLUA .. '" "' .. path .. '"')
    if code ~= 0 or trim(out) ~= c[3] then
      fail("%s: got %q want %q", c[1], trim(out):sub(1, 60), c[3])
    end
  end
  local path = TMP .. "\\nolbl.lua"
  local f = io.open(path, "wb"); f:write("for i=1,3 do goto continue end\n"); f:close()
  local code, out = run('"' .. CLUA .. '" "' .. path .. '"')
  if code == 0 then
    fail("`goto continue` with no user label was accepted -- the synthetic label leaked")
  elseif not out:find("no visible label 'continue'", 1, true) then
    fail("`goto continue` without a label gave the wrong error: %s", trim(out):sub(1, 80))
  end
end

-- Errors must name `continue`, not the internal label spelling.
do
  local errs = {
    { "outside a loop",        'print(1) continue print(2)',                    "continue outside loop" },
    { "inside a nested fn",    'for i=1,3 do local f = function() continue end end', "continue outside loop" },
    { "repeat scope conflict", 'local n=0 repeat n=n+1 if n==1 then continue end local a=n until a>2',
                               "<continue>" },
  }
  for _, c in ipairs(errs) do
    local path = TMP .. "\\cerr.lua"
    local f = io.open(path, "wb"); f:write(c[2], "\n"); f:close()
    local code, out = run('"' .. CLUA .. '" "' .. path .. '"')
    if code == 0 then
      fail("continue error case %q was accepted", c[1])
    elseif not out:find(c[3], 1, true) then
      fail("continue error %q should mention %q, got: %s", c[1], c[3], trim(out):sub(1, 80))
    end
    if out:find("(continue)", 1, true) then
      fail("continue error %q leaked the internal label name to the user", c[1])
    end
  end
end

-- ---- 1c. compound assignment ------------------------------------------------
--
-- For a SIMPLE target (local, upvalue, or an index whose table and key are already
-- in registers) the sugar must be byte-identical to the expanded Lua form. For a
-- target with a non-trivial prefix it deliberately is NOT: `t[f()] += 1` evaluates
-- f() ONCE where the expansion evaluates it twice. That divergence is the feature,
-- and it is asserted separately below.
local compound_pairs = {
  { "+=",   "local a=1 a += 2 print(a)",          "local a=1 a = a + 2 print(a)" },
  { "-=",   "local a=9 a -= 2 print(a)",          "local a=9 a = a - 2 print(a)" },
  { "*=",   "local a=3 a *= 4 print(a)",          "local a=3 a = a * 4 print(a)" },
  { "/=",   "local a=9 a /= 2 print(a)",          "local a=9 a = a / 2 print(a)" },
  { "//=",  "local a=9 a //= 2 print(a)",         "local a=9 a = a // 2 print(a)" },
  { "%=",   "local a=9 a %= 2 print(a)",          "local a=9 a = a % 2 print(a)" },
  { "^=",   "local a=2 a ^= 3 print(a)",          "local a=2 a = a ^ 3 print(a)" },
  { "..=",  'local s="x" s ..= "y" print(s)',     'local s="x" s = s .. "y" print(s)' },
  { "&=",   "local a=6 a &= 3 print(a)",          "local a=6 a = a & 3 print(a)" },
  { "|=",   "local a=6 a |= 3 print(a)",          "local a=6 a = a | 3 print(a)" },
  { "<<=",  "local a=1 a <<= 3 print(a)",         "local a=1 a = a << 3 print(a)" },
  { ">>=",  "local a=8 a >>= 2 print(a)",         "local a=8 a = a >> 2 print(a)" },
  { "upvalue target", "local u=1 local function g() u += 1 end g() print(u)",
                      "local u=1 local function g() u = u + 1 end g() print(u)" },
  { "t[i] local key", "local t={} local i=1 t[i] += 1 print(t[1])",
                      "local t={} local i=1 t[i] = t[i] + 1 print(t[1])" },
  { "t[1] literal",   "local t={[1]=5} t[1] += 1 print(t[1])",
                      "local t={[1]=5} t[1] = t[1] + 1 print(t[1])" },
  { "t.f field",      "local t={f=5} t.f += 1 print(t.f)",
                      "local t={f=5} t.f = t.f + 1 print(t.f)" },
  { "rhs expression", "local a=1 a += 2 * 3 print(a)", "local a=1 a = a + 2 * 3 print(a)" },
}
local comp_identical = 0
for _, case in ipairs(compound_pairs) do
  local label, sugar, lua = case[1], case[2], case[3]
  local a, ea = build_bytes(sugar)
  local b, eb = build_bytes(lua)
  if not a or not b then
    fail("compound %s: a spelling failed to compile (%s)", label, ea or eb)
  elseif a ~= b then
    fail("compound %s: emits different bytes from the expanded form (%d vs %d)",
         label, #a, #b)
  else
    comp_identical = comp_identical + 1
  end
end

-- The target must be evaluated ONCE. This is the one place the sugar is meant to
-- differ from the textual expansion, and getting it wrong is a silent miscompile:
-- without restoring fs->freereg after luaK_dischargevars, `t[f()] += 1` compiles
-- to `t[newvalue] = newvalue` and no assertion fires.
do
  local prog = [==[
local calls = 0
local function f() calls = calls + 1 return 1 end
local t = {[1] = 10}
t[f()] += 5
print(calls, t[1])
]==]
  local path = TMP .. "\\once.lua"
  local h = io.open(path, "wb"); h:write(prog); h:close()
  local code, out = run('"' .. CLUA .. '" "' .. path .. '"')
  if code ~= 0 then
    fail("target-once program failed: %s", trim(out):sub(1, 90))
  elseif trim(out) ~= "1	15" then
    fail("target-once: got %q, expected \"1\t15\" (one call, correct value)", trim(out))
  end
end

-- Metamethods must fire exactly as in the expanded form: for an indexed target
-- that means a SEPARATE __index read and __newindex write, not a fused access.
do
  local prog = [==[
local log = {}
local mt = { __index = function(t,k) log[#log+1]="get:"..k return 10 end,
             __newindex = function(t,k,v) log[#log+1]="set:"..k.."="..v end }
local p = setmetatable({}, mt)
p.z += 5
print(table.concat(log, " "))
]==]
  local path = TMP .. "\\mm.lua"
  local h = io.open(path, "wb"); h:write(prog); h:close()
  local code, out = run('"' .. CLUA .. '" "' .. path .. '"')
  if code ~= 0 or trim(out) ~= "get:z set:z=15" then
    fail("compound metamethod order: got %q, want \"get:z set:z=15\"", trim(out):sub(1,60))
  end
end

-- Rejections.
do
  local errs = {
    { "const target",    "local a <const> = 1 a += 1",       "const" },
    { "multiple target", "local a,b=1,2 a, b += 1, 2",       "'=' expected" },
    { "call target",     "local function f() end f() += 1",  "compound assignment" },
  }
  for _, c in ipairs(errs) do
    local path = TMP .. "\\cae.lua"
    local h = io.open(path, "wb"); h:write(c[2], "\n"); h:close()
    local code, out = run('"' .. CLUA .. '" "' .. path .. '"')
    if code == 0 then
      fail("compound error case %q was accepted", c[1])
    elseif not out:find(c[3], 1, true) then
      fail("compound error %q should mention %q, got: %s", c[1], c[3], trim(out):sub(1,80))
    end
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
print(("[+] PASS %s (%d/%d operator + %d/%d continue + %d/%d compound pairs emit byte-identical EXEs, %d compatibility "
       .. "cases unchanged, continue-as-identifier and error paths verified)")
      :format(NAME, identical, #pairs_to_check, cont_identical, #continue_pairs,
              comp_identical, #compound_pairs, #compat))
os.exit(0)
