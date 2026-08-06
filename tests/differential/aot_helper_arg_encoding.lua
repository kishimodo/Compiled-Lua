-- Differential: helper-call argument encoding.
--
-- LcCg_EmitHelperCall3 loads its three int arguments with X64Emit_MovImm32ToReg,
-- which picks one of three encodings per argument by the value's sign:
--
--   zero      xor r32, r32        (and for R8/R9 this needs REX.R *and* REX.B)
--   positive  mov r32, imm32      (zero-extends, correct for a positive value)
--   negative  mov r64, imm32 sx   (sign-extends, so the 64-bit register is
--                                  bit-identical to the old imm64 form)
--
-- A wrong REX prefix on the zero tier loads the wrong register and passes a
-- garbage argument; a zero-extending encoding in the negative tier passes
-- 0x00000000FFFFFFFF where -1 was meant. Neither shows up as a crash in ordinary
-- code, and both would make the binary SMALLER -- so a size measurement would
-- report the broken version as a bigger win. This test drives each argument
-- register through each tier and diffs stdout against the interpreter.
--
-- Deterministic; prints only. No load()/require, so it is closed-world clean.

local out = {}
local function say(...) out[#out + 1] = table.concat({ ... }, " ") end

-- ---- R8/R9 negative: multret call shapes pass NArgs/NResults == -1 --------

local function three() return 1, 2, 3 end
local function sum(...)
  local t = { ... }
  local s = 0
  for i = 1, select("#", ...) do s = s + t[i] end
  return s, select("#", ...)
end

-- f(g()) -> Rt_Call with NArgs = -1 (all of g's results)
say("multret-args", sum(three()))
-- call in multret position -> NResults = -1
local function forward(...) return sum(...) end
say("multret-results", forward(three()))
-- return f() -> Rt_PrepReturn with N = -1
local function tailforward(...) return three() end
say("multret-return", tailforward())

-- vararg consume -> Rt_Vararg with NRequired = -1
local function varargs(...)
  local t = { ... }
  return #t, select("#", ...)
end
say("vararg-open", varargs(10, 20, 30, 40))

local function fixed_then_open(a, b, ...)
  return a + b, select("#", ...)
end
say("vararg-fixed", fixed_then_open(1, 2, 3, 4, 5))

-- ---- R9 negative: the lift's Ck encoding (-C-1) for constant keys ---------
-- SETFIELD / SETTABLE / SETI / SETTABUP with a constant key all pass the
-- encoded key index, which is negative when the key is a constant.

local t = {}
t.x = "field-const"
t[1] = "index-const"
local k = "computed"
t[k] = "dynamic-key"
say("setfield", t.x, t[1], t[k])

Global_probe = "global-const"          -- SETTABUP _ENV "Global_probe" k
say("settabup", Global_probe)

-- OP_SELF carries a Ck-encoded method name
local obj = {}
function obj:method(n) return "self:" .. tostring(n) end
say("self-call", obj:method(7))

-- ---- R9 large positive: a big table constructor folds EXTRAARG ------------

local big = {}
for i = 1, 300 do big[i] = i end
local bigsum = 0
for i = 1, #big do bigsum = bigsum + big[i] end
say("setlist-300", #big, bigsum)

-- ---- R8/R9 packed instruction words: metamethod dispatch -----------------
-- Rt_ArithIK / Rt_ShiftI / Rt_OrderISlow receive the trailing MMBIN
-- instruction word itself, a large positive value whose low bits carry the
-- metamethod selector and the k/C flag. A truncated or mis-signed argument
-- picks the wrong metamethod.

-- Written order-agnostically: a reversed operand (100 - x) hands the metamethod
-- the plain number first, which is itself one of the arms being tested.
local function shown(v)
  if type(v) == "table" then return "T" .. tostring(v.v) end
  return tostring(v)
end
local function op(name)
  return function(a, b) return name .. "(" .. shown(a) .. "," .. shown(b) .. ")" end
end

local mt = {}
mt.__sub  = op("sub")
mt.__add  = op("add")
mt.__shl  = op("shl")
mt.__shr  = op("shr")
mt.__idiv = op("idiv")
mt.__mod  = op("mod")
mt.__band = op("band")
mt.__lt   = function(a, b) return true end
mt.__le   = function(a, b) return false end
mt.__eq   = function(a, b) return true end

local x = setmetatable({ v = 41 }, mt)

say("mm-sub", x - 1)
say("mm-add", x + 2)
say("mm-shl", x << 3)
say("mm-shr", x >> 4)
say("mm-idiv", x // 5)
say("mm-mod", x % 6)
say("mm-band", x & 7)
-- __lt against a float immediate exercises the raw-word C flag in R8
say("mm-lt", tostring(x < 2.0))
say("mm-le", tostring(x <= 2.0))
say("mm-eq", tostring(x == setmetatable({ v = 41 }, mt)))

-- reversed operand order takes the other arm of the same helpers
say("mm-rsub", 100 - x)
say("mm-radd", 200 + x)

-- ---- ordinary arithmetic must be untouched -------------------------------

local acc = 0
for i = 1, 50 do
  acc = acc + i * 2 - 1
  if acc % 7 == 0 then acc = acc + 1 end
end
say("arith", acc)

local f = 0.0
for i = 1, 20 do f = f + 1.5 * i end
say("float", string.format("%.4f", f))

-- ---- upvalue get/set pass (A, B) pairs through the same shim -------------

local counter = 0
local function bump(n) counter = counter + n; return counter end
say("upval", bump(3), bump(4), counter)

-- ---- error paths still report the right operand --------------------------

local ok, err = pcall(function() local z = nil; return z.field end)
say("err-index", tostring(ok), (tostring(err):gsub(".*:%d+: ", "")))

local ok2, err2 = pcall(function() return ("x") + 1 end)
say("err-arith", tostring(ok2), (tostring(err2):gsub(".*:%d+: ", "")))

for _, line in ipairs(out) do print(line) end
