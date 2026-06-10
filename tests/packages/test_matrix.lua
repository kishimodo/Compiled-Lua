-- tests/packages/test_matrix.lua : matrix correctness, focused on 3x3
-- eigenvalues (a spurious sign flip made every 3x3 result wrong) plus core ops.
local matrix = require "matrix"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_matrix: " .. tostring(m)) end end
local function approx(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

-- Helper: sort a numeric eigenvalue list descending for stable comparison.
local function real_sorted(ev)
  local r = {}
  for _, v in ipairs(ev) do
    if type(v) == "number" then r[#r + 1] = v end
  end
  table.sort(r, function(a, b) return a > b end)
  return r
end

-- Diagonal matrix: eigenvalues are the diagonal entries.
do
  local ev = real_sorted(matrix.diag({ 2, 3, 5 }):eigenvalues())
  ok(#ev == 3, "diag(2,3,5): three real eigenvalues (got " .. #ev .. ")")
  ok(approx(ev[1], 5) and approx(ev[2], 3) and approx(ev[3], 2),
     "diag(2,3,5) eigenvalues == {5,3,2} (got " .. table.concat({ev[1], ev[2], ev[3]}, ",") .. ")")
end

-- Symmetric matrix [[2,1,0],[1,2,0],[0,0,3]] has spectrum {3,3,1}.
do
  local m = matrix.from_rows({ { 2, 1, 0 }, { 1, 2, 0 }, { 0, 0, 3 } })
  local ev = real_sorted(m:eigenvalues())
  ok(#ev == 3, "symmetric 3x3: three real eigenvalues")
  ok(approx(ev[1], 3, 1e-6) and approx(ev[2], 3, 1e-6) and approx(ev[3], 1, 1e-6),
     "symmetric 3x3 eigenvalues == {3,3,1} (got " .. table.concat({ev[1], ev[2], ev[3]}, ",") .. ")")
end

-- 2x2 closed form (separate code path) stays correct.
do
  local ev = real_sorted(matrix.from_rows({ { 2, 0 }, { 0, 5 } }):eigenvalues())
  ok(approx(ev[1], 5) and approx(ev[2], 2), "2x2 diag eigenvalues == {5,2}")
end

-- Core ops sanity: multiply + transpose + identity.
do
  local a = matrix.from_rows({ { 1, 2 }, { 3, 4 } })
  local id = matrix.identity(2)
  local p = a:mul(id)
  ok(p:get(1, 1) == 1 and p:get(1, 2) == 2 and p:get(2, 1) == 3 and p:get(2, 2) == 4,
     "A * I == A")
  local t = a:transpose()
  ok(t:get(1, 2) == 3 and t:get(2, 1) == 2, "transpose swaps off-diagonal")
end

if fails == 0 then print("[+] PASS test_matrix") os.exit(0) else os.exit(1) end
