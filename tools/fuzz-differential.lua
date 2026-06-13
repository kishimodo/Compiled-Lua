-- tools/fuzz-differential.lua : differential fuzzer -- compiled exe vs interpreter.
--
--   build\bin\clua-interp.exe tools\fuzz-differential.lua [start_seed] [count] [--keep]
--
-- Generates deterministic Lua programs from a seeded PRNG, compiles each with
-- aotc.exe at -O1 into a native PE, runs it, and byte-compares its stdout
-- against the bytecode interpreter (clua-interp.exe -i). The interpreter is the
-- oracle: any divergence is an AOT codegen/optimizer bug. A divergence is
-- re-run once to confirm (filters environmental flakiness), then the case is
-- saved to tests/fuzz-failures/fuzz_seed_<n>.lua with a header ready for
-- promotion into tests/conformance/ (add `-- DIFF-XFAIL: <reason>` while the
-- bug lives; the conformance phase flips it to XPASS when fixed).
--
-- The grammar is weighted toward the constructs that historically produced
-- real codegen bugs here (in the since-removed v1 JIT and the AOT backend):
-- generic-for + vararg forwarding (JIT-VARARG-001), <close> variables
-- (JIT-001), stack-relocating metamethods (Round-3/4 stale register/pointer
-- class), tail calls (JIT-003), numeric-for loop-variable mutation (R4-001),
-- immediate-operand comparisons (EQI/LTI/GTI/...), long method names
-- (R4-006), and fiber coroutines (R4-009).
--
-- Determinism rules (load-bearing -- the oracle compares across PROCESSES):
--   * never print raw pairs() iteration order (per-process string-hash seed
--     reorders it) -- aggregate (count/sum) or sort keys first
--   * never print tables/functions/userdata (addresses)
--   * bounded loops and recursion; no clock/time/random in generated code

-- clua-interp.exe passes script arguments via the global `arg` table (stock-Lua
-- convention: arg[0] = script name, arg[1..] = arguments), not as chunk `...`.
local args  = arg or { ... }
local START = tonumber(args[1] or "1")  or 1
local COUNT = tonumber(args[2] or "100") or 100
-- Remaining args (any order): "--keep" retains generated cases; "-O<n>" sets the
-- compile level (default -O1, as run-tests uses). Fuzzing at -O2/-O3 stresses
-- the whole-program / memory passes the suite's seeds 1-25 also cover.
local KEEP  = false
local OLEVEL = "-O1"
for i = 3, #args do
  if args[i] == "--keep" then KEEP = true
  elseif type(args[i]) == "string" and args[i]:match("^%-O%d$") then OLEVEL = args[i] end
end

local BIN      = "build\\bin"
local CLUA    = BIN .. "\\clua-interp.exe"
local AOTC     = BIN .. "\\aotc.exe"
local CASE     = BIN .. "\\tests\\_fuzz_case.lua"
local CASEEXE  = BIN .. "\\tests\\_fuzz_case.exe"
local WATCHDOG = BIN .. "\\tests\\timeout-run.exe"
local FAILDIR  = "tests\\fuzz-failures"
local CHILD_TIMEOUT_MS = 30000

-- ---- PRNG: xorshift64* (pure Lua 5.4 integer math, fully deterministic) ----

local Rng = {}
Rng.__index = Rng

local function rng_new(seed)
  -- splitmix64 once to spread small seeds
  local x = seed + 0x9E3779B97F4A7C15
  x = (x ~ (x >> 30)) * 0xBF58476D1CE4E5B9
  x = (x ~ (x >> 27)) * 0x94D049BB133111EB
  x = x ~ (x >> 31)
  if x == 0 then x = 0x2545F4914F6CDD1D end
  return setmetatable({ s = x }, Rng)
end

function Rng:next()
  local x = self.s
  x = x ~ (x >> 12)
  x = x ~ (x << 25)
  x = x ~ (x >> 27)
  self.s = x
  return x * 0x2545F4914F6CDD1D
end

function Rng:int(lo, hi)        -- uniform integer in [lo, hi]
  local span = hi - lo + 1
  local v = self:next() % span
  if v < 0 then v = v + span end
  return lo + v
end

function Rng:pick(list) return list[self:int(1, #list)] end
function Rng:chance(pct) return self:int(1, 100) <= pct end

-- ---- expression generators (type-disciplined so programs always compile) ---

local function gen_int_expr(rng, vars, depth)
  if depth <= 0 or rng:chance(35) then
    if #vars > 0 and rng:chance(50) then return rng:pick(vars) end
    return tostring(rng:int(-99, 99))
  end
  local op = rng:pick({ "+", "-", "*", "//", "%", "&", "|", "~", "<<", ">>" })
  local a = gen_int_expr(rng, vars, depth - 1)
  if op == "//" or op == "%" then
    -- nonzero literal divisor: integer division by zero raises
    return "(" .. a .. " " .. op .. " " .. tostring(rng:int(1, 9)) .. ")"
  end
  if op == "<<" or op == ">>" then
    return "(" .. a .. " " .. op .. " " .. tostring(rng:int(0, 7)) .. ")"
  end
  local b = gen_int_expr(rng, vars, depth - 1)
  return "(" .. a .. " " .. op .. " " .. b .. ")"
end

local function gen_num_expr(rng, vars, depth)
  if depth <= 0 or rng:chance(35) then
    if #vars > 0 and rng:chance(40) then return rng:pick(vars) end
    if rng:chance(50) then
      return string.format("%d.%d", rng:int(-20, 20), rng:int(0, 99))
    end
    return tostring(rng:int(-99, 99))
  end
  local op = rng:pick({ "+", "-", "*", "/", "+", "-" })
  local a = gen_num_expr(rng, vars, depth - 1)
  local b = gen_num_expr(rng, vars, depth - 1)
  return "(" .. a .. " " .. op .. " " .. b .. ")"
end

-- ---- statement templates (each returns a self-contained chunk of code) ------
-- Every template prints something deterministic; `id` uniquifies names.

local T = {}

-- JIT-VARARG-001 family: vararg forwarding right after a generic-for.
T[#T + 1] = { w = 10, gen = function(rng, id)
  local nargs  = rng:int(0, 5)
  local argv   = {}
  for i = 1, nargs do argv[i] = tostring(rng:int(-50, 50)) end
  local iter   = rng:pick({ "pairs", "ipairs" })
  local twoVar = rng:chance(50) and "k, v" or "_"
  local mode   = rng:pick({ "count", "ret", "pack", "fwd" })
  local body
  if mode == "count" then body = 'return select("#", ...)'
  elseif mode == "ret" then body = "return ..."
  elseif mode == "pack" then body = "local p = table.pack(...) return p.n"
  else body = "return math.max(-1000, ...)" end
  return string.format([[
local function vf%d(...)
  local t = { 5, 9, 13, x = 1, y = 2 }
  for %s in %s(t) do end
  %s
end
print("vf%d", select("#", vf%d(%s)), (vf%d(%s)))
]], id, twoVar, iter, body, id, id, table.concat(argv, ", "), id, table.concat(argv, ", "))
end }

-- <close> variables: side-effect counter, return value survival, break paths.
T[#T + 1] = { w = 8, gen = function(rng, id)
  local v = rng:int(1, 999)
  local brk = rng:chance(40) and "if i == 2 then break end" or ""
  return string.format([[
do
  local closed%d = 0
  local function cf%d()
    local g <close> = setmetatable({}, { __close = function() closed%d = closed%d + 1 end })
    for i = 1, 3 do %s end
    return %d
  end
  print("cl%d", cf%d(), closed%d)
end
]], id, id, id, id, brk, v, id, id, id)
end }

-- numeric-for with loop-variable mutation (R4-001) + varying steps.
T[#T + 1] = { w = 7, gen = function(rng, id)
  local from = rng:int(-5, 5)
  local step = rng:pick({ 1, 2, 3, -1, -2 })
  local to   = from + step * rng:int(2, 6)
  local mut  = rng:chance(60) and string.format("i = i + %d", rng:int(10, 99)) or ""
  local isFloat = rng:chance(30)
  local f = isFloat and ".0" or ""
  return string.format([[
do
  local acc%d = {}
  for i = %d%s, %d%s, %d%s do acc%d[#acc%d + 1] = i %s end
  print("nf%d", table.concat(acc%d, ","))
end
]], id, from, f, to, f, step, f, id, id, mut, id, id)
end }

-- stack-relocating metamethods: handlers allocate tables under load.
T[#T + 1] = { w = 9, gen = function(rng, id)
  local mm = rng:pick({ "__index", "__newindex", "__concat", "__len", "__call" })
  local alloc = [[local j = {} for q = 1, 20 do j[q] = q * 2 end]]
  local setup, use
  if mm == "__index" then
    setup = string.format("{ __index = function(_, k) %s return #k + j[5] end }", alloc)
    use   = string.format('print("mm%d", o%d.alpha + o%d.bz)', id, id, id)
  elseif mm == "__newindex" then
    setup = string.format("{ __newindex = function(t, k, v) %s rawset(t, k, v + j[3]) end }", alloc)
    use   = string.format('o%d.f = 10 o%d.g = 20 print("mm%d", o%d.f + o%d.g)', id, id, id, id, id)
  elseif mm == "__concat" then
    setup = string.format('{ __concat = function(a, b) %s return "C" .. tostring(j[7]) .. tostring(type(a) == "table" and "T" or a) end }', alloc)
    use   = string.format('print("mm%d", o%d .. "x", "y" .. o%d)', id, id, id)
  elseif mm == "__len" then
    setup = string.format("{ __len = function() %s return j[11] end }", alloc)
    use   = string.format('print("mm%d", #o%d + 1)', id, id)
  else
    setup = string.format("{ __call = function(_, a, b) %s return a * b + j[2] end }", alloc)
    use   = string.format('print("mm%d", o%d(3, 4))', id, id)
  end
  return string.format("do\n  local o%d = setmetatable({}, %s)\n  %s\nend\n", id, setup, use)
end }

-- comparison metamethods + immediate-operand comparisons (register & K forms).
T[#T + 1] = { w = 7, gen = function(rng, id)
  local lit  = rng:pick({ "2", "2.0", "5", "0", "-3", "7.5" })
  local kind = rng:pick({ "<", "<=", ">", ">=", "==", "~=" })
  local x    = rng:pick({ tostring(rng:int(-9, 9)), string.format("%d.5", rng:int(-9, 9)) })
  local nan  = rng:chance(25) and string.format('print("nan%d", (0/0) %s %s)', id, rng:pick({ "<", "<=", ">", ">=" }), lit) or ""
  return string.format([[
do
  local x%d = %s
  print("cmp%d", x%d %s %s, %s %s x%d, x%d == x%d)
  %s
end
]], id, x, id, id, kind, lit, lit, kind, id, id, id, nan)
end }

-- tail calls: deep self-recursion (TCO), mutual pair, multret tail return.
T[#T + 1] = { w = 6, gen = function(rng, id)
  local depth = rng:int(500, 3000)
  local mode = rng:pick({ "self", "mutual", "multret" })
  if mode == "self" then
    return string.format([[
local function tc%d(n, acc) if n == 0 then return acc end return tc%d(n - 1, acc + n) end
print("tc%d", tc%d(%d, 0))
]], id, id, id, id, depth)
  elseif mode == "mutual" then
    return string.format([[
local ta%d, tb%d
ta%d = function(n) if n == 0 then return "A" end return tb%d(n - 1) end
tb%d = function(n) if n == 0 then return "B" end return ta%d(n - 1) end
print("tm%d", ta%d(%d))
]], id, id, id, id, id, id, id, id, depth)
  end
  return string.format([[
local function tr%d(n) if n == 0 then return 1, 2, 3 end return tr%d(n - 1) end
print("tr%d", select("#", tr%d(%d)), tr%d(%d))
]], id, id, id, id, rng:int(50, 400), id, rng:int(50, 400))
end }

-- fiber coroutines: yield/resume value threading, wrap iterator, error path.
T[#T + 1] = { w = 5, gen = function(rng, id)
  local mode = rng:pick({ "thread", "wrap", "err" })
  if mode == "thread" then
    return string.format([[
do
  local co%d = coroutine.create(function(a, b)
    local c = coroutine.yield(a + b)
    return a, b, c
  end)
  local _, s%d = coroutine.resume(co%d, %d, %d)
  print("co%d", s%d, select("#", coroutine.resume(co%d, 9)))
end
]], id, id, id, rng:int(1, 50), rng:int(1, 50), id, id, id)
  elseif mode == "wrap" then
    return string.format([[
do
  local g%d = coroutine.wrap(function() for i = 1, %d do coroutine.yield(i * i) end end)
  local s%d = 0
  for v in g%d do s%d = s%d + v end
  print("cw%d", s%d)
end
]], id, rng:int(3, 8), id, id, id, id, id, id)
  end
  return string.format([[
do
  local ok%d, e%d = coroutine.resume(coroutine.create(function() error("boom%d") end))
  print("ce%d", ok%d, type(e%d) == "string" and (e%d:match("boom%d") ~= nil) or type(e%d))
end
]], id, id, id, id, id, id, id, id, id)
end }

-- long method names (>40 chars: long-string OP_SELF) + short control.
T[#T + 1] = { w = 4, gen = function(rng, id)
  local long = "method_with_a_very_long_identifier_name_number_" .. tostring(rng:int(10, 99))
  return string.format([[
do
  local obj%d = {}
  function obj%d:%s(x) return x * 3 end
  function obj%d:m(x) return x + 1 end
  print("sm%d", obj%d:%s(%d), obj%d:m(%d))
end
]], id, id, long, id, id, id, long, rng:int(1, 30), id, rng:int(1, 30))
end }

-- pairs aggregation (order-independent: count + numeric sum + sorted keys).
T[#T + 1] = { w = 5, gen = function(rng, id)
  local n = rng:int(2, 6)
  local fields = {}
  for i = 1, n do fields[i] = string.format("k%d = %d", i, rng:int(1, 99)) end
  return string.format([[
do
  local t%d = { %s }
  local cnt%d, sum%d, keys%d = 0, 0, {}
  for k, v in pairs(t%d) do cnt%d = cnt%d + 1 sum%d = sum%d + v keys%d[#keys%d + 1] = k end
  table.sort(keys%d)
  print("pa%d", cnt%d, sum%d, table.concat(keys%d, ","))
end
]], id, table.concat(fields, ", "), id, id, id, id, id, id, id, id, id, id, id, id, id, id, id)
end }

-- big table constructors (SETLIST/EXTRAARG path) + index probes.
T[#T + 1] = { w = 4, gen = function(rng, id)
  local n = rng:pick({ 30, 60, 300, 600 })
  local vals = {}
  for i = 1, n do vals[i] = tostring((i * 7 + id) % 100) end
  return string.format([[
do
  local big%d = { %s }
  print("bt%d", #big%d, big%d[1], big%d[%d], big%d[#big%d])
end
]], id, table.concat(vals, ","), id, id, id, id, math.max(1, n // 2), id, id)
end }

-- closures capturing loop variables (fresh local per iteration).
T[#T + 1] = { w = 4, gen = function(rng, id)
  return string.format([[
do
  local fns%d = {}
  for i = 1, %d do fns%d[i] = function() return i * %d end end
  local s%d = 0
  for i = 1, #fns%d do s%d = s%d + fns%d[i]() end
  print("cap%d", s%d)
end
]], id, rng:int(3, 7), id, rng:int(2, 9), id, id, id, id, id, id, id)
end }

-- pcall / error propagation with deterministic messages.
T[#T + 1] = { w = 4, gen = function(rng, id)
  local mode = rng:pick({ "str", "tbl", "nested" })
  if mode == "str" then
    return string.format([[
do
  local ok%d, e%d = pcall(function() error("E%d", 0) end)
  print("pc%d", ok%d, e%d)
end
]], id, id, id, id, id, id)
  elseif mode == "tbl" then
    return string.format([[
do
  local ok%d, e%d = pcall(function() error({ code = %d }) end)
  print("pt%d", ok%d, type(e%d), e%d.code)
end
]], id, id, rng:int(1, 99), id, id, id, id)
  end
  return string.format([[
do
  local ok%d = pcall(function() return pcall(error, "inner") end)
  print("pn%d", ok%d)
end
]], id, id, id)
end }

-- goto-driven loop (branch resolution seasoning).
T[#T + 1] = { w = 3, gen = function(rng, id)
  return string.format([[
do
  local i%d, s%d = 0, 0
  ::top%d::
  i%d = i%d + 1
  s%d = s%d + i%d
  if i%d < %d then goto top%d end
  print("gt%d", s%d)
end
]], id, id, id, id, id, id, id, id, id, rng:int(3, 12), id, id, id)
end }

-- string ops: concat chains, format, sub/rep/byte, # operator.
T[#T + 1] = { w = 5, gen = function(rng, id)
  local n1, n2 = rng:int(0, 99), rng:int(-50, 50)
  return string.format([[
do
  local s%d = "ab" .. %d .. "cd" .. (%d) .. "ef"
  print("st%d", s%d, #s%d, s%d:sub(2, 5), string.format("%%d|%%x|%%s", %d, %d, s%d:upper()))
  print("sr%d", string.rep("xy", %d, "-"), ("hello"):byte(1, 3))
end
]], id, n1, n2, id, id, id, id, n1, n1 % 256 + 1, id, id, rng:int(1, 5))
end }

-- random typed expressions (int + float lanes) and math.type probes.
T[#T + 1] = { w = 6, gen = function(rng, id)
  local iv = string.format("local a%d, b%d = %d, %d", id, id, rng:int(-30, 30), rng:int(1, 30))
  local ie = gen_int_expr(rng, { "a" .. id, "b" .. id }, 3)
  local ne = gen_num_expr(rng, { "a" .. id, "b" .. id }, 3)
  return string.format([[
do
  %s
  local ir%d = %s
  local nr%d = %s
  print("ex%d", ir%d, math.type(ir%d), nr%d, math.type(nr%d))
end
]], iv, id, ie, id, ne, id, id, id, id, id)
end }

-- table library: insert/remove/sort/concat/move on deterministic data.
T[#T + 1] = { w = 4, gen = function(rng, id)
  local vals = {}
  for i = 1, rng:int(4, 9) do vals[i] = tostring(rng:int(-99, 99)) end
  return string.format([[
do
  local tl%d = { %s }
  table.insert(tl%d, %d)
  table.insert(tl%d, 1, %d)
  table.remove(tl%d, 2)
  table.sort(tl%d, function(x, y) return x < y end)
  local mv%d = table.move(tl%d, 1, 3, 1, {})
  print("tb%d", table.concat(tl%d, ","), table.concat(mv%d, ","), #tl%d)
end
]], id, table.concat(vals, ", "), id, rng:int(-9, 9), id, rng:int(-9, 9), id, id, id, id, id, id, id, id)
end }

-- ---- program assembly --------------------------------------------------------

local TOTAL_W = 0
for _, t in ipairs(T) do TOTAL_W = TOTAL_W + t.w end

local function pick_template(rng)
  local roll = rng:int(1, TOTAL_W)
  for _, t in ipairs(T) do
    roll = roll - t.w
    if roll <= 0 then return t end
  end
  return T[#T]
end

local function generate(seed)
  local rng = rng_new(seed)
  local chunks = { string.format("-- fuzz case: seed %d (tools/fuzz-differential.lua)", seed) }
  local n = rng:int(3, 7)
  for i = 1, n do
    chunks[#chunks + 1] = pick_template(rng).gen(rng, i)
  end
  return table.concat(chunks, "\n")
end

-- ---- harness -----------------------------------------------------------------

local function wrap(cmd) return '"' .. cmd .. '"' end

local function capture(cmd)
  local p = io.popen(wrap(cmd))
  if not p then return "", -1 end
  local out = p:read("*a") or ""
  local ok, _, code = p:close()
  return out, (ok == true) and 0 or (code or 1)
end

local function file_exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end

local have_watchdog = file_exists(WATCHDOG)
local function guard(cmd)
  if not have_watchdog then return cmd end
  return '"' .. WATCHDOG .. '" ' .. CHILD_TIMEOUT_MS .. ' ' .. cmd
end

local function write_file(path, text)
  local f = assert(io.open(path, "w"))
  f:write(text)
  f:close()
end

-- Engine 1: aotc-compiled native exe (-O1). Engine 2: the interpreter oracle.
-- An aotc compile/link failure is reported as exit code 125 in `ra` so it
-- diverges loudly (a generated program must always compile -- the generator
-- emits no closed-world-banned constructs).
local function run_case()
  local _, rc = capture(guard('"' .. AOTC .. '" ' .. OLEVEL .. ' "' .. CASE
                              .. '" -o "' .. CASEEXE .. '" 2>&1'))
  local oa, ra
  if rc ~= 0 then
    oa, ra = "", 125
  else
    oa, ra = capture(guard('"' .. CASEEXE .. '" 2>nul'))
  end
  local oi, ri = capture(guard('"' .. CLUA .. '" -i "' .. CASE .. '" 2>nul'))
  return oa, ra, oi, ri
end

os.execute('if not exist "' .. BIN .. '\\tests" mkdir "' .. BIN .. '\\tests" >nul 2>&1')

if not file_exists(AOTC) then
  print("[-] FAIL fuzz: " .. AOTC .. " not built (run build\\build-luac.bat)")
  os.exit(1)
end

local divergences, oracle_fails = {}, {}

for seed = START, START + COUNT - 1 do
  local program = generate(seed)
  write_file(CASE, program)
  local oa, ra, oi, ri = run_case()

  local diverged = (ri == 0) and (ra ~= 0 or oa ~= oi)
  if diverged then
    -- confirm: re-run once; only report stable divergences
    local oa2, ra2, oi2, ri2 = run_case()
    diverged = (ri2 == 0) and (ra2 ~= 0 or oa2 ~= oi2)
  end

  if ri ~= 0 then
    oracle_fails[#oracle_fails + 1] = seed
    print(string.format("  [-] FAIL fuzz seed %d (interpreter oracle exit %d -- generator bug?)", seed, ri))
    os.execute('if not exist "' .. FAILDIR .. '" mkdir "' .. FAILDIR .. '" >nul 2>&1')
    write_file(FAILDIR .. "\\genbad_seed_" .. seed .. ".lua", program)
  elseif diverged then
    divergences[#divergences + 1] = seed
    os.execute('if not exist "' .. FAILDIR .. '" mkdir "' .. FAILDIR .. '" >nul 2>&1')
    local saved = FAILDIR .. "\\fuzz_seed_" .. seed .. ".lua"
    write_file(saved,
      "-- compiled-vs-interpreter DIVERGENCE found by tools/fuzz-differential.lua (seed " .. seed .. ").\n" ..
      "-- Reproduce:  build\\bin\\aotc.exe -O1 <this file> -o case.exe && case.exe   vs   build\\bin\\clua-interp.exe -i <this file>\n" ..
      "-- To track as a known bug: add `-- DIFF-XFAIL: <reason>` and move into tests/conformance/.\n" ..
      program)
    print(string.format("  [-] FAIL fuzz seed %d (compiled exe vs -i divergence%s) -> %s",
                        seed, ra == 125 and "; aotc compile failed" or "", saved))
    -- show the first differing line for instant triage
    local aa, ia = {}, {}
    for l in oa:gmatch("[^\r\n]+") do aa[#aa + 1] = l end
    for l in oi:gmatch("[^\r\n]+") do ia[#ia + 1] = l end
    for i = 1, math.max(#aa, #ia) do
      if aa[i] ~= ia[i] then
        print("        exe: " .. tostring(aa[i]))
        print("        -i : " .. tostring(ia[i]))
        break
      end
    end
  elseif KEEP then
    write_file(BIN .. "\\tests\\fuzz_seed_" .. seed .. ".lua", program)
  end
end

if not KEEP then os.remove(CASE) os.remove(CASEEXE) end

print(string.format("[fuzz] %d case(s), seeds %d..%d: %d divergence(s), %d oracle-failure(s)%s",
                    COUNT, START, START + COUNT - 1, #divergences, #oracle_fails,
                    have_watchdog and "" or "  [no watchdog]"))
if #divergences > 0 then
  print("[fuzz] divergent seeds: " .. table.concat(divergences, ", "))
end
if #divergences > 0 or #oracle_fails > 0 then os.exit(1) end
print("[+] PASS fuzz (" .. COUNT .. " cases, compiled exe == interpreter)")
os.exit(0)
