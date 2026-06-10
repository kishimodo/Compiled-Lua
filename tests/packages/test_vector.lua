-- tests/packages/test_vector.lua : N-dimensional vector math round-trips and
-- hand-computed reference values. Pure-Lua package, no native DLL needed.
local ok_req, vector = pcall(require, "vector")
if not ok_req then print("[~] SKIP test_vector") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_vector: " .. tostring(m)) end end

local function close(a, b) return math.abs(a - b) < 1e-9 end

-- ===== construction & indexing =========================================
local a = vector.new({ 3, 4 })
ok(a.n == 2,                  "new(table) sets dim")
ok(a:dim() == 2,              "dim() method")
ok(a[1] == 3 and a[2] == 4,   "raw component index")
ok(a.x == 3 and a.y == 4,     "x/y aliases read first two components")

local z = vector.new(3)
ok(z.n == 3 and z[1] == 0 and z[2] == 0 and z[3] == 0, "new(number) -> zero vec")

local v3 = vector.vec3(1, 2, 3)
ok(v3.n == 3 and v3.x == 1 and v3.y == 2 and v3.z == 3, "vec3 positional ctor")
ok(vector.vec2(5).y == 0,     "vec2 missing args default to 0")
ok(vector.vec4(1, 2, 3, 4).w == 4, "vec4 w alias")

-- alias write through __newindex
local wv = vector.vec3(0, 0, 0)
wv.x = 7
ok(wv[1] == 7,                "writing .x updates component 1")

-- ===== arithmetic (hand-computed) ======================================
-- (1,2,3) + (4,5,6) = (5,7,9)
local s = vector.add(vector.vec3(1, 2, 3), vector.vec3(4, 5, 6))
ok(s[1] == 5 and s[2] == 7 and s[3] == 9, "add componentwise")
-- (4,5,6) - (1,2,3) = (3,3,3)
local d = vector.sub(vector.vec3(4, 5, 6), vector.vec3(1, 2, 3))
ok(d[1] == 3 and d[2] == 3 and d[3] == 3, "sub componentwise")
-- scale (1,2,3)*2 = (2,4,6)
local sc = vector.scale(vector.vec3(1, 2, 3), 2)
ok(sc[1] == 2 and sc[2] == 4 and sc[3] == 6, "scale by scalar")
-- neg
local ng = vector.neg(vector.vec2(3, -4))
ok(ng[1] == -3 and ng[2] == 4, "neg")
-- mul scalar both sides, and hadamard
ok(vector.mul(2, vector.vec2(3, 4))[1] == 6, "scalar * vector")
ok(vector.mul(vector.vec2(3, 4), 2)[2] == 8, "vector * scalar")
local had = vector.mul(vector.vec3(2, 3, 4), vector.vec3(5, 6, 7))
ok(had[1] == 10 and had[2] == 18 and had[3] == 28, "vector * vector hadamard")
-- div by scalar and componentwise
ok(vector.div(vector.vec2(8, 4), 2)[1] == 4, "vector / scalar")
local dv = vector.div(vector.vec2(8, 9), vector.vec2(2, 3))
ok(dv[1] == 4 and dv[2] == 3, "vector / vector componentwise")

-- operator metamethods
local op = vector.vec2(1, 2) + vector.vec2(3, 4)
ok(op[1] == 4 and op[2] == 6, "__add metamethod")
ok((vector.vec2(5, 6) - vector.vec2(1, 2))[1] == 4, "__sub metamethod")
ok((vector.vec2(1, 2) * 3)[2] == 6, "__mul metamethod")
ok((-vector.vec2(1, -2))[2] == 2, "__unm metamethod")
ok(#vector.vec3(0, 0, 0) == 3, "__len returns dim")

-- ===== geometry (hand-computed) ========================================
-- dot((1,2,3),(4,5,6)) = 4+10+18 = 32
ok(vector.dot(vector.vec3(1, 2, 3), vector.vec3(4, 5, 6)) == 32, "dot 3D")
-- dot 2D (3,4).(2,1) = 6+4 = 10
ok(vector.dot(vector.vec2(3, 4), vector.vec2(2, 1)) == 10, "dot 2D")
-- method-style dot
ok(vector.vec3(1, 2, 3):dot(vector.vec3(4, 5, 6)) == 32, "dot method-style")

-- cross(x_hat, y_hat) = z_hat ; (1,0,0) x (0,1,0) = (0,0,1)
local cx = vector.cross(vector.vec3(1, 0, 0), vector.vec3(0, 1, 0))
ok(cx[1] == 0 and cx[2] == 0 and cx[3] == 1, "cross x*y = z")
-- cross((2,3,4),(5,6,7)) = (3*7-4*6, 4*5-2*7, 2*6-3*5) = (-3, 6, -3)
local cg = vector.cross(vector.vec3(2, 3, 4), vector.vec3(5, 6, 7))
ok(cg[1] == -3 and cg[2] == 6 and cg[3] == -3, "cross general")

-- length((3,4)) = 5
ok(vector.length(vector.vec2(3, 4)) == 5, "length 2D = 5")
-- length((1,2,2)) = 3
ok(vector.length(vector.vec3(1, 2, 2)) == 3, "length 3D = 3")
-- length((1,2,2,4)) = sqrt(1+4+4+16)=sqrt(25)=5
ok(vector.length(vector.vec4(1, 2, 2, 4)) == 5, "length 4D = 5")
-- norm is alias of length
ok(vector.norm(vector.vec2(3, 4)) == 5, "norm alias of length")
-- length_sq((3,4)) = 25
ok(vector.length_sq(vector.vec2(3, 4)) == 25, "length_sq")

-- normalize((3,4)) -> (0.6, 0.8), unit length
local nz = vector.normalize(vector.vec2(3, 4))
ok(close(nz[1], 0.6) and close(nz[2], 0.8), "normalize (3,4)")
ok(close(vector.length(nz), 1), "normalized vector has unit length")
-- normalize zero vector errors
ok(not pcall(vector.normalize, vector.vec2(0, 0)), "normalize zero vector errors")

-- lerp((0,0),(10,20), 0.5) = (5,10)
local lp = vector.lerp(vector.vec2(0, 0), vector.vec2(10, 20), 0.5)
ok(lp[1] == 5 and lp[2] == 10, "lerp midpoint")
local lp0 = vector.lerp(vector.vec2(1, 1), vector.vec2(9, 9), 0)
ok(lp0[1] == 1 and lp0[2] == 1, "lerp t=0 returns a")

-- distance((0,0),(3,4)) = 5
ok(vector.distance(vector.vec2(0, 0), vector.vec2(3, 4)) == 5, "distance = 5")

-- angle_between perpendicular vectors = pi/2
ok(close(vector.angle_between(vector.vec2(1, 0), vector.vec2(0, 1)), math.pi / 2),
   "angle_between perpendicular = pi/2")
-- angle_between same direction = 0
ok(close(vector.angle_between(vector.vec2(2, 0), vector.vec2(5, 0)), 0),
   "angle_between parallel = 0")
-- angle_between opposite = pi (also tests the clamp path)
ok(close(vector.angle_between(vector.vec2(1, 0), vector.vec2(-1, 0)), math.pi),
   "angle_between opposite = pi")

-- reflect((1,-1),(0,1)) : bounce off horizontal floor -> (1,1)
local rf = vector.reflect(vector.vec2(1, -1), vector.vec2(0, 1))
ok(close(rf[1], 1) and close(rf[2], 1), "reflect off (0,1) normal")

-- project((3,4) onto (1,0)) = (3,0)
local pr = vector.project(vector.vec2(3, 4), vector.vec2(1, 0))
ok(close(pr[1], 3) and close(pr[2], 0), "project onto x axis")

-- ===== equality, clone, tostring =======================================
ok(vector.eq(vector.vec3(1, 2, 3), vector.vec3(1, 2, 3)), "eq same")
ok(not vector.eq(vector.vec3(1, 2, 3), vector.vec3(1, 2, 4)), "eq differing component")
ok(not vector.eq(vector.vec2(1, 2), vector.vec3(1, 2, 0)), "eq differing dim")
ok(vector.vec2(1, 2) == vector.vec2(1, 2), "__eq metamethod")

local cl = vector.clone(vector.vec3(1, 2, 3))
cl[1] = 99
ok(cl[1] == 99, "clone is independent (mutated copy)")

ok(vector.tostring(vector.vec3(1, 2, 3)) == "(1, 2, 3)", "tostring format")

-- dimension-mismatch guard
ok(not pcall(vector.add, vector.vec2(1, 2), vector.vec3(1, 2, 3)), "add dim mismatch errors")
ok(not pcall(vector.cross, vector.vec2(1, 2), vector.vec2(3, 4)), "cross non-3D errors")

if fails == 0 then print("[+] PASS test_vector") os.exit(0) else os.exit(1) end
