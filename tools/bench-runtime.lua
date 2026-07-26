-- Runtime speed benchmark for the CLua session A/B.
--
-- Deliberately weighted toward what this session's codegen changes touched:
-- helper-call argument loading (every table/global/upvalue/call op goes through
-- LcCg_EmitHelperCall3), plus the arithmetic and loop paths that surround them.
-- Prints one total so two builds can be compared, and a per-section breakdown so
-- a regression can be located rather than just observed.
--
-- Deterministic: no clock inside the measured sections, no randomness, fixed
-- iteration counts. The harness times the whole process.

local N = tonumber(os.getenv("BENCH_N") or "1") or 1

local acc = 0

-- 1. integer arithmetic in a tight loop (savedpc sites + typed fastpaths)
for _ = 1, N do
  local s = 0
  for i = 1, 400000 do s = s + i * 2 - 1 end
  acc = acc + s % 1000
end

-- 2. float arithmetic (xmm residency path)
for _ = 1, N do
  local f = 0.0
  for i = 1, 200000 do f = f + 1.5 * i - 0.25 end
  acc = acc + math.floor(f) % 1000
end

-- 3. table field access: GETFIELD/SETFIELD -> helper calls with constant keys
for _ = 1, N do
  local t = { x = 0, y = 1, z = 2 }
  for _ = 1, 150000 do
    t.x = t.x + t.y
    t.z = t.x - t.y
  end
  acc = acc + t.z % 1000
end

-- 4. array indexing: GETI/SETI
for _ = 1, N do
  local a = {}
  for i = 1, 2000 do a[i] = i end
  local s = 0
  for _ = 1, 100 do
    for i = 1, 2000 do s = s + a[i] end
  end
  acc = acc + s % 1000
end

-- 5. function calls (Rt_Call: NArgs/NResults through the shim)
for _ = 1, N do
  local function add3(a, b, c) return a + b + c end
  local s = 0
  for i = 1, 150000 do s = s + add3(i, 1, 2) end
  acc = acc + s % 1000
end

-- 6. upvalue read/write (Rt_GetUpval/Rt_SetUpval)
for _ = 1, N do
  local up = 0
  local function bump(n) up = up + n return up end
  for i = 1, 150000 do bump(1) end
  acc = acc + up % 1000
end

-- 7. global access (GETTABUP/SETTABUP through _ENV)
GlobalCounter = 0
for _ = 1, N do
  for _ = 1, 100000 do GlobalCounter = GlobalCounter + 1 end
  acc = acc + GlobalCounter % 1000
end

-- 8. string ops + metamethod dispatch (Rt_ArithIK slow path)
for _ = 1, N do
  local mt = { __add = function(a, b) return setmetatable({ v = a.v + 1 }, getmetatable(a)) end }
  local o = setmetatable({ v = 0 }, mt)
  for _ = 1, 40000 do o = o + 1 end
  acc = acc + o.v % 1000
  local parts = {}
  for i = 1, 5000 do parts[i] = tostring(i) end
  acc = acc + #table.concat(parts, ",") % 1000
end

print("checksum", acc)
