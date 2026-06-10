-- tests/packages/test_bezier.lua : quadratic + cubic Bezier math vs
-- hand-computed reference values (De Casteljau, derivatives, split,
-- bounding box, projection, SVG path). Pure Lua, no DLL needed.
local ok_req, bezier = pcall(require, "bezier")
if not ok_req then print("[~] SKIP test_bezier") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_bezier: " .. tostring(m)) end end

local function close(a, b, eps) return math.abs(a - b) <= (eps or 1e-9) end
local function px(p) return p.x or p[1] end
local function py(p) return p.y or p[2] end

-- ===== Quadratic: B(t)=(1-t)^2 p0 + 2(1-t)t p1 + t^2 p2 ================
-- p0=(0,0) p1=(10,20) p2=(20,0)
local q = bezier.quadratic({0, 0}, {10, 20}, {20, 0})

local q0 = q:at(0)
ok(close(px(q0), 0) and close(py(q0), 0),    "quad at t=0 equals p0")
local q1 = q:at(1)
ok(close(px(q1), 20) and close(py(q1), 0),   "quad at t=1 equals p2")
-- t=0.5 -> 0.25*(0,0)+0.5*(10,20)+0.25*(20,0) = (10,10)
local qh = q:at(0.5)
ok(close(px(qh), 10) and close(py(qh), 10),  "quad at t=0.5 = (10,10)")

-- Derivative B'(0.5) = 2*0.5*(p1-p0) + 2*0.5*(p2-p1)
--   = (10,20) + (10,-20) = (20,0)
local qd = q:derivative_at(0.5)
ok(close(px(qd), 20) and close(py(qd), 0),   "quad derivative at t=0.5 = (20,0)")
-- B'(0) = 2*(p1-p0) = (20,40)
local qd0 = q:derivative_at(0)
ok(close(px(qd0), 20) and close(py(qd0), 40),"quad derivative at t=0 = 2(p1-p0)")

-- ===== Cubic: p0=(0,0) p1=(0,1) p2=(1,1) p3=(1,0) =====================
local c = bezier.cubic({0, 0}, {0, 1}, {1, 1}, {1, 0})

local c0 = c:at(0)
ok(close(px(c0), 0) and close(py(c0), 0),    "cubic at t=0 equals p0")
local c1 = c:at(1)
ok(close(px(c1), 1) and close(py(c1), 0),    "cubic at t=1 equals p3")
-- t=0.5 coeffs 0.125,0.375,0.375,0.125:
--   x = 0.375*0 + 0.375*1 + 0.125*1 = 0.5
--   y = 0.375*1 + 0.375*1           = 0.75
local ch = c:at(0.5)
ok(close(px(ch), 0.5) and close(py(ch), 0.75), "cubic at t=0.5 = (0.5,0.75)")

-- Derivative B'(0.5)=3*0.25*(p1-p0)+6*0.25*(p2-p1)+3*0.25*(p3-p2)
--   = 0.75*(0,1) + 1.5*(1,0) + 0.75*(0,-1) = (1.5, 0)
local cd = c:derivative_at(0.5)
ok(close(px(cd), 1.5) and close(py(cd), 0),  "cubic derivative at t=0.5 = (1.5,0)")

-- ===== Split: pieces meet at B(t); endpoints preserved ================
local cl, cr = c:split(0.5)
ok(close(px(cl.p0), 0) and close(py(cl.p0), 0),   "split left p0 = original p0")
ok(close(px(cr.p3), 1) and close(py(cr.p3), 0),   "split right p3 = original p3")
-- Junction: cl.p3 == cr.p0 == B(0.5) = (0.5, 0.75)
ok(close(px(cl.p3), 0.5) and close(py(cl.p3), 0.75), "split left p3 = B(0.5)")
ok(close(px(cr.p0), px(cl.p3)) and close(py(cr.p0), py(cl.p3)), "split halves share junction")
-- A point on the left half re-parameterizes: left:at(0.5) == orig:at(0.25)
local lhalf = cl:at(0.5)
local oquart = c:at(0.25)
ok(close(px(lhalf), px(oquart)) and close(py(lhalf), py(oquart)), "split left reparam matches original")

-- ===== Bounding box of the cubic above ================================
-- x ranges [0,1]; y peaks at t=0.5 -> 0.75, min 0.
local bb = c:bounding_box()
ok(close(bb.min_x, 0) and close(bb.max_x, 1), "cubic bbox x = [0,1]")
ok(close(bb.min_y, 0) and close(bb.max_y, 0.75), "cubic bbox y = [0,0.75]")

-- Quadratic bbox: p0=(0,0) p1=(10,20) p2=(20,0). y root at t=0.5 -> y=10.
local qbb = q:bounding_box()
ok(close(qbb.min_x, 0) and close(qbb.max_x, 20), "quad bbox x = [0,20]")
ok(close(qbb.min_y, 0) and close(qbb.max_y, 10), "quad bbox y = [0,10]")

-- ===== Projection: closest t to a sampled point ======================
-- Point exactly on the curve at t=0.25 must project back near 0.25.
local on = c:at(0.25)
local pt_t = c:project(on)
ok(close(pt_t, 0.25, 1e-3), "project recovers t of on-curve point")
-- Endpoints project to 0 and 1.
ok(close(c:project(c.p0), 0, 1e-6), "project p0 -> t=0")
ok(close(c:project(c.p3), 1, 1e-6), "project p3 -> t=1")

-- ===== SVG path emission ==============================================
ok(q:to_path() == "M 0.000000 0.000000 Q 10.000000 20.000000 20.000000 0.000000",
   "quad to_path SVG string")
ok(c:to_path() == "M 0.000000 0.000000 C 0.000000 1.000000 1.000000 1.000000 1.000000 0.000000",
   "cubic to_path SVG string")

-- ===== Flatten: polyline starts at p0, ends at last point ============
local poly = c:flatten(0.01)
ok(#poly >= 2, "flatten yields a polyline")
ok(close(px(poly[1]), 0) and close(py(poly[1]), 0), "flatten starts at p0")
ok(close(px(poly[#poly]), 1) and close(py(poly[#poly]), 0), "flatten ends at p3")

-- ===== Length: straight-line degenerate case is exact =================
-- A cubic whose controls are colinear from (0,0) to (3,0) has length 3.
local line = bezier.cubic({0, 0}, {1, 0}, {2, 0}, {3, 0})
ok(close(line:length(), 3, 1e-4), "straight cubic length = chord")

if fails == 0 then print("[+] PASS test_bezier") os.exit(0) else os.exit(1) end
