-- LUAC-001: ci->u.l.savedpc must name the EXACT bytecode pc of the throwing op,
-- not merely its line -- ldebug's varinfo decodes the instruction at that pc to
-- annotate the operand ("local 'x'" / "upvalue 'y'" / "field 'z'"). This test
-- pins that precision after the savedpc base was hoisted into the frame
-- prologue (RBP = P->code + bias; the per-site displacement is now the only
-- pc-dependent part, so an off-by-one bias or a wrong disp8/disp32 split shows
-- up here as a wrong line or a wrong variable name).
--
-- Covered on purpose:
--   * a tiny function      (sizecode <= 31 -> bias 0, every site disp8)
--   * a large function     (sizecode >> 63 -> nonzero bias, sites on BOTH
--                           sides of it, and sites beyond the disp8 window at
--                           each end -> disp32)
--   * several throw sites sharing ONE source line but different pcs
--   * the first and the last throw-capable op of a body

local nil_a, nil_b, nil_c = nil, nil, nil

local function tiny(k)
  if k == 1 then return nil_a.x end
  if k == 2 then return nil_b.y end
  return "tiny-ok"
end

-- Two sites on ONE line: a line-precise-but-pc-sloppy savedpc still reports the
-- right line here, and the wrong variable name.
local function sameline(k)
  if k == 1 then return nil_a.first elseif k == 2 then return nil_b.second end
  return "sameline-ok"
end

-- Long body. The filler statements exist only to push sizecode well past the
-- +-127-byte disp8 window on either side of the centering bias.
local function big(k)
  local acc = 0
  if k == 1 then return nil_a.at_the_top end        -- earliest site
  local t1 = { 1, 2, 3 }
  acc = acc + t1[1]; acc = acc + t1[2]; acc = acc + t1[3]
  local s1 = tostring(acc) .. "/" .. tostring(#t1)
  local t2 = { a = 1, b = 2, c = 3 }
  acc = acc + t2.a; acc = acc + t2.b; acc = acc + t2.c
  local s2 = s1 .. tostring(acc)
  if k == 2 then return nil_b.early end
  local t3 = { s1, s2 }
  acc = acc + #t3[1]; acc = acc + #t3[2]
  local s3 = table.concat(t3, ",")
  acc = acc + #s3
  local t4 = { x = t1, y = t2, z = t3 }
  acc = acc + t4.x[1] + t4.y.a + #t4.z
  local s4 = string.format("%s|%s|%d", s2, s3, acc)
  acc = acc + #s4
  if k == 3 then return acc + nil_c.middle_arith end
  local t5 = {}
  for i = 1, 4 do t5[i] = i * acc end
  acc = acc + t5[1] + t5[2] + t5[3] + t5[4]
  local s5 = s4 .. tostring(acc)
  acc = acc + #s5
  local t6 = { p = s5, q = t5 }
  acc = acc + #t6.p + #t6.q
  local s6 = table.concat({ s1, s2, s3, s4, s5 }, ";")
  acc = acc + #s6
  local t7 = { s6:sub(1, 4), s6:sub(5, 8) }
  acc = acc + #t7[1] + #t7[2]
  if k == 4 then return t7.deep.deeper end
  local s7 = s6:upper():lower():rep(2)
  acc = acc + #s7
  local t8 = { s7, t7, t6, t5 }
  acc = acc + #t8
  local s8 = string.format("%d-%d", acc, #s7)
  acc = acc + #s8
  local t9 = { u = s8, v = t8 }
  acc = acc + #t9.u + #t9.v
  if k == 5 then return acc .. nil_a end            -- concat error, late
  local s9 = tostring(acc) .. s8 .. s7:sub(1, 2)
  acc = acc + #s9
  if k == 6 then return undefined_global_at_the_end() end  -- latest site
  return acc
end

local function show(...)
  print(...)
end

for k = 1, 3 do show(pcall(tiny, k)) end
for k = 1, 3 do show(pcall(sameline, k)) end
for k = 1, 7 do show(pcall(big, k)) end

-- error() with a level: luaL_where(1) also reads savedpc of the caller frame.
local function thrower() error("boom") end
local function level2() error("deeper", 2) end
local function callsite() level2() end
show(pcall(thrower))
show(pcall(callsite))

-- xpcall + traceback exercises savedpc for every live frame at once.
show(xpcall(function() return big(4) end, function(m) return "handled: " .. m end))

-- A method call on a nil field: OP_SELF then OP_CALL, adjacent pcs.
local obj = {}
show(pcall(function() return obj:missing_method() end))
show(pcall(function() local o = nil; return o:anything() end))
