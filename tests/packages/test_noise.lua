-- test_noise -- regression test for the builtin `noise` package (pure Lua).
-- Asserts against KNOWN-CORRECT references: gradient noise is exactly 0 at
-- integer lattice points, value noise is bounded to [0,1], perlin/simplex to
-- [-1,1], plus determinism, seed independence, continuity, and the documented
-- voronoi/fbm/ridged return shapes & invariants.
local ok_req, noise = pcall(require, "noise")
if not ok_req then print("[~] SKIP test_noise") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_noise: " .. tostring(m)) end end
local function approx(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end

-- 1. Determinism: identical input + seed must yield bit-exact output.
ok(noise.perlin(1.5, 2.5, { seed = 42 }) == noise.perlin(1.5, 2.5, { seed = 42 }),
   "perlin2 not deterministic")
ok(noise.simplex(0.3, 0.7, 0.9, { seed = 7 }) == noise.simplex(0.3, 0.7, 0.9, { seed = 7 }),
   "simplex3 not deterministic")
ok(noise.value(2.2, 3.3, { seed = 1 }) == noise.value(2.2, 3.3, { seed = 1 }),
   "value2 not deterministic")

-- 2. KNOWN-CORRECT reference value: Perlin gradient noise is EXACTLY 0 at integer
--    lattice points (fractional parts are 0, so every gradient dot vanishes).
for _, p in ipairs({ {0,0}, {1,1}, {5,3}, {-2,4}, {100,-100} }) do
  local pv = noise.perlin(p[1], p[2], { seed = 3 })
  ok(approx(pv, 0, 1e-12),
     ("perlin(%d,%d) must be 0 at lattice, got %s"):format(p[1], p[2], tostring(pv)))
end
ok(approx(noise.perlin(2, 3, 4, { seed = 9 }), 0, 1e-12), "perlin3 not 0 at integer lattice")

-- 3. Output ranges (documented): perlin/simplex in [-1,1], value in [0,1].
--    Sweep a deterministic set of off-lattice samples.
for i = 1, 300 do
  local x = i * 0.137
  local y = i * 0.071 + 0.5
  local pn = noise.perlin(x, y, { seed = 11 })
  ok(pn >= -1.0001 and pn <= 1.0001, "perlin2 out of [-1,1]: " .. tostring(pn))
  local sn = noise.simplex(x, y, { seed = 11 })
  ok(sn >= -1.0001 and sn <= 1.0001, "simplex2 out of [-1,1]: " .. tostring(sn))
  local vn = noise.value(x, y, { seed = 11 })
  ok(vn >= 0 and vn <= 1, "value2 out of [0,1]: " .. tostring(vn))
  -- 3D variants too.
  local p3 = noise.perlin(x, y, x * 0.5, { seed = 11 })
  ok(p3 >= -1.0001 and p3 <= 1.0001, "perlin3 out of [-1,1]: " .. tostring(p3))
  local v3 = noise.value(x, y, x * 0.5, { seed = 11 })
  ok(v3 >= 0 and v3 <= 1, "value3 out of [0,1]: " .. tostring(v3))
end

-- 4. Seed independence: distinct seeds must produce a distinct field somewhere.
local diff = false
for i = 1, 50 do
  local x = i * 0.31
  if noise.perlin(x, x + 0.5, { seed = 1 }) ~= noise.perlin(x, x + 0.5, { seed = 2 }) then
    diff = true; break
  end
end
ok(diff, "different seeds produced identical perlin field")

-- 5. Continuity / gradient sanity: a tiny step in input -> a tiny step in output.
local base = noise.perlin(3.21, 1.77, { seed = 5 })
local near = noise.perlin(3.21 + 1e-4, 1.77, { seed = 5 })
ok(math.abs(base - near) < 0.01,
   "perlin discontinuous: small dx gave dn=" .. tostring(math.abs(base - near)))

-- 6. Voronoi: documented return shape { f1, f2, cell_id } with f1 <= f2.
local vor = noise.voronoi(1.4, 2.6, { seed = 8 })
ok(type(vor) == "table", "voronoi did not return a table")
ok(type(vor.f1) == "number" and type(vor.f2) == "number", "voronoi missing f1/f2")
ok(vor.f1 >= 0, "voronoi f1 negative: " .. tostring(vor.f1))
ok(vor.f1 <= vor.f2, "voronoi invariant f1 <= f2 violated")
ok(math.type(vor.cell_id) == "integer", "voronoi cell_id not an integer")
local vor2 = noise.voronoi(1.4, 2.6, { seed = 8 })
ok(vor.f1 == vor2.f1 and vor.cell_id == vor2.cell_id, "voronoi not deterministic")

-- 7. fbm: a single octave (amp 1, freq 1, persistence default) must equal the raw
--    noise sample exactly -- a known-correct algebraic identity (total/max_amp = raw/1).
local single = noise.fbm(noise.perlin, 2.5, 3.5, { seed = 4, octaves = 1, frequency = 1, amplitude = 1 })
local raw    = noise.perlin(2.5, 3.5, { seed = 4 })
ok(approx(single, raw, 1e-12),
   ("fbm 1-octave should equal raw noise: %s vs %s"):format(tostring(single), tostring(raw)))
ok(noise.fbm(noise.perlin, 1.1, 2.2, { seed = 4 }) ==
   noise.fbm(noise.perlin, 1.1, 2.2, { seed = 4 }), "fbm not deterministic")
-- fbm of perlin is a normalized (weighted-average) sum, so it stays in perlin's range.
local fb = noise.fbm(noise.perlin, 1.1, 2.2, { seed = 4, octaves = 6 })
ok(fb >= -1.0001 and fb <= 1.0001, "fbm not normalized into [-1,1]: " .. tostring(fb))
-- octaves = 0 -> max_amp == 0 -> documented 0 result.
ok(noise.fbm(noise.perlin, 1, 1, { octaves = 0 }) == 0, "fbm octaves=0 should return 0")

-- 8. ridged_multifractal: contributions are (offset - |n|)^2 * weight, all >= 0,
--    so the normalized total is non-negative.
local rm = noise.ridged_multifractal(noise.perlin, 1.3, 4.2, { seed = 6, octaves = 4 })
ok(rm >= 0, "ridged_multifractal returned negative: " .. tostring(rm))
ok(noise.ridged_multifractal(noise.perlin, 1.3, 4.2, { seed = 6 }) ==
   noise.ridged_multifractal(noise.perlin, 1.3, 4.2, { seed = 6 }), "ridged not deterministic")

if fails == 0 then print("[+] PASS test_noise") os.exit(0) else os.exit(1) end
