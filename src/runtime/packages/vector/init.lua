-- vector -- N-dimensional vectors with fast paths for 2D/3D/4D.
--
-- Representation:
--   v[1..n]  -- numeric components (Lua arrays remain hot in LuaJIT)
--   v.n      -- dimension (stored so we avoid #v repeatedly)
-- Component aliases v.x / v.y / v.z / v.w resolve to v[1..4] via __index.
--
-- The fast paths matter because 2-4 dim vectors dominate graphics workloads;
-- avoiding the generic loop saves loop overhead per component.
--
-- Public surface:
--   vector.new(n_or_table)              -- new(3) -> zero vec3, new({1,2,3}) -> vec3
--   v:dim()                             -- dimension
--   v:dot(o), v:cross(o), v:length(),
--   v:norm() [alias of length], v:normalize(), v:lerp(o, t)
--   v:clone(), v:tostring()
--   Module versions mirror methods.
--
-- Indexing:
--   v[1]/v[2]/...   -- raw component
--   v.x/v.y/v.z/v.w -- alias for first 4 components

local M  = {}
local mt = {}

local sqrt, acos = math.sqrt, math.acos

local _AXIS = { x = 1, y = 2, z = 3, w = 4 }

local function is_v(x) return type(x) == "table" and getmetatable(x) == mt end

local function alloc(n)
    local v = setmetatable({ n = n }, mt)
    for i = 1, n do v[i] = 0 end
    return v
end

function M.new(arg)
    if type(arg) == "number" then return alloc(arg) end
    if type(arg) == "table" then
        if is_v(arg) then
            local v = setmetatable({ n = arg.n }, mt)
            for i = 1, arg.n do v[i] = arg[i] end
            return v
        end
        local n = #arg
        local v = setmetatable({ n = n }, mt)
        for i = 1, n do v[i] = arg[i] end
        return v
    end
    error("vector.new: bad argument type " .. type(arg))
end

function M.dim(v) return v.n end

-- Fixed-dim constructors with positional args (also accept a single table).
local function fixed_ctor(dim)
    return function(a, b, c, d)
        local v = setmetatable({ n = dim }, mt)
        if type(a) == "table" then
            for i = 1, dim do v[i] = a[i] or 0 end
            return v
        end
        local args = { a or 0, b or 0, c or 0, d or 0 }
        for i = 1, dim do v[i] = args[i] end
        return v
    end
end

M.vec2 = fixed_ctor(2)
M.vec3 = fixed_ctor(3)
M.vec4 = fixed_ctor(4)

-- Alias: scale(v, s) -> v * s
function M.scale(v, s)
    local out = setmetatable({ n = v.n }, mt)
    for i = 1, v.n do out[i] = v[i] * s end
    return out
end

function M.clone(v)
    local out = setmetatable({ n = v.n }, mt)
    for i = 1, v.n do out[i] = v[i] end
    return out
end

-- ===== Element-wise arithmetic =========================================

local function check_dim(a, b, op)
    if a.n ~= b.n then
        error(string.format("vector.%s: dimension mismatch (%d vs %d)", op, a.n, b.n))
    end
end

function M.add(a, b)
    check_dim(a, b, "add")
    local out = setmetatable({ n = a.n }, mt)
    if a.n == 2 then out[1] = a[1] + b[1]; out[2] = a[2] + b[2]
    elseif a.n == 3 then out[1] = a[1] + b[1]; out[2] = a[2] + b[2]; out[3] = a[3] + b[3]
    elseif a.n == 4 then out[1] = a[1] + b[1]; out[2] = a[2] + b[2]; out[3] = a[3] + b[3]; out[4] = a[4] + b[4]
    else for i = 1, a.n do out[i] = a[i] + b[i] end end
    return out
end

function M.sub(a, b)
    check_dim(a, b, "sub")
    local out = setmetatable({ n = a.n }, mt)
    if a.n == 2 then out[1] = a[1] - b[1]; out[2] = a[2] - b[2]
    elseif a.n == 3 then out[1] = a[1] - b[1]; out[2] = a[2] - b[2]; out[3] = a[3] - b[3]
    elseif a.n == 4 then out[1] = a[1] - b[1]; out[2] = a[2] - b[2]; out[3] = a[3] - b[3]; out[4] = a[4] - b[4]
    else for i = 1, a.n do out[i] = a[i] - b[i] end end
    return out
end

function M.neg(a)
    local out = setmetatable({ n = a.n }, mt)
    for i = 1, a.n do out[i] = -a[i] end
    return out
end

local function scalar_mul(v, s)
    local out = setmetatable({ n = v.n }, mt)
    if v.n == 2 then out[1] = v[1] * s; out[2] = v[2] * s
    elseif v.n == 3 then out[1] = v[1] * s; out[2] = v[2] * s; out[3] = v[3] * s
    elseif v.n == 4 then out[1] = v[1] * s; out[2] = v[2] * s; out[3] = v[3] * s; out[4] = v[4] * s
    else for i = 1, v.n do out[i] = v[i] * s end end
    return out
end

function M.mul(a, b)
    -- vector * scalar OR scalar * vector OR vector * vector (hadamard)
    if type(a) == "number" then return scalar_mul(b, a) end
    if type(b) == "number" then return scalar_mul(a, b) end
    check_dim(a, b, "mul")
    local out = setmetatable({ n = a.n }, mt)
    for i = 1, a.n do out[i] = a[i] * b[i] end
    return out
end

function M.div(a, b)
    if type(b) == "number" then
        local inv = 1 / b
        return scalar_mul(a, inv)
    end
    check_dim(a, b, "div")
    local out = setmetatable({ n = a.n }, mt)
    for i = 1, a.n do out[i] = a[i] / b[i] end
    return out
end

-- ===== Geometry ========================================================

function M.dot(a, b)
    check_dim(a, b, "dot")
    if a.n == 2 then return a[1] * b[1] + a[2] * b[2] end
    if a.n == 3 then return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
    if a.n == 4 then return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4] end
    local s = 0
    for i = 1, a.n do s = s + a[i] * b[i] end
    return s
end

function M.cross(a, b)
    if a.n ~= 3 or b.n ~= 3 then error("vector.cross: only defined in 3D") end
    local out = setmetatable({ n = 3 }, mt)
    out[1] = a[2] * b[3] - a[3] * b[2]
    out[2] = a[3] * b[1] - a[1] * b[3]
    out[3] = a[1] * b[2] - a[2] * b[1]
    return out
end

function M.length(v)
    if v.n == 2 then return sqrt(v[1] * v[1] + v[2] * v[2]) end
    if v.n == 3 then return sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3]) end
    if v.n == 4 then return sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3] + v[4] * v[4]) end
    local s = 0
    for i = 1, v.n do s = s + v[i] * v[i] end
    return sqrt(s)
end

M.norm = M.length

function M.length_sq(v)
    local s = 0
    for i = 1, v.n do s = s + v[i] * v[i] end
    return s
end

function M.normalize(v)
    local len = M.length(v)
    if len == 0 then error("vector.normalize: zero vector") end
    return scalar_mul(v, 1 / len)
end

function M.lerp(a, b, t)
    check_dim(a, b, "lerp")
    local out = setmetatable({ n = a.n }, mt)
    for i = 1, a.n do out[i] = a[i] + (b[i] - a[i]) * t end
    return out
end

function M.distance(a, b)
    check_dim(a, b, "distance")
    local s = 0
    for i = 1, a.n do local d = a[i] - b[i]; s = s + d * d end
    return sqrt(s)
end

function M.angle_between(a, b)
    -- result in radians, clamped to handle floating-point drift past +/-1
    local d = M.dot(a, b) / (M.length(a) * M.length(b))
    if d >  1 then d =  1
    elseif d < -1 then d = -1 end
    return acos(d)
end

function M.reflect(v, normal)
    -- v - 2 * dot(v, n) * n
    local d = 2 * M.dot(v, normal)
    return M.sub(v, scalar_mul(normal, d))
end

function M.project(v, onto)
    -- (v . onto / onto . onto) * onto
    local d = M.dot(v, onto) / M.dot(onto, onto)
    return scalar_mul(onto, d)
end

function M.eq(a, b)
    if a.n ~= b.n then return false end
    for i = 1, a.n do if a[i] ~= b[i] then return false end end
    return true
end

function M.tostring(v)
    local parts = {}
    for i = 1, v.n do parts[i] = tostring(v[i]) end
    return "(" .. table.concat(parts, ", ") .. ")"
end

-- ===== Metatable =======================================================

mt.__index = function(t, k)
    -- xyzw component aliases
    local idx = _AXIS[k]
    if idx and idx <= t.n then return rawget(t, idx) end
    return M[k]
end

mt.__newindex = function(t, k, v)
    local idx = _AXIS[k]
    if idx and idx <= rawget(t, "n") then
        rawset(t, idx, v)
    else
        rawset(t, k, v)
    end
end

mt.__add      = M.add
mt.__sub      = M.sub
mt.__mul      = M.mul
mt.__div      = M.div
mt.__unm      = M.neg
mt.__eq       = M.eq
mt.__tostring = M.tostring
mt.__len      = function(v) return v.n end

setmetatable(M, { __call = function(_, arg) return M.new(arg) end })

return M
