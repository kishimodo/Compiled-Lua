-- bezier -- Quadratic + cubic Bezier curve math.
--
-- Points are { x = ..., y = ... } or { [1] = x, [2] = y }.
--
-- Public surface:
--   bezier.quadratic(p0, p1, p2)          -> curve
--   bezier.cubic(p0, p1, p2, p3)          -> curve
--   bezier.fit(points, opts?)             -> cubic curve approximating points
--
-- Curve methods:
--   c:at(t)             -> {x, y}
--   c:derivative_at(t)  -> {x, y} tangent
--   c:length(opts?)     -> arc length (opts.tolerance, opts.max_depth)
--   c:split(t)          -> (left, right)
--   c:project(p, opts?) -> closest_t
--   c:flatten(tol?)     -> polyline {{x, y}, ...}
--   c:bounding_box()    -> {min_x, min_y, max_x, max_y}
--   c:to_path()         -> SVG path string

local M = {}

-- ===== Point helpers ===================================================

local function px(p) return p.x or p[1] end
local function py(p) return p.y or p[2] end

local function pt(x, y) return { x = x, y = y } end

local function sub_p(a, b) return pt(px(a) - px(b), py(a) - py(b)) end
local function add_p(a, b) return pt(px(a) + px(b), py(a) + py(b)) end
local function scale_p(a, k) return pt(px(a) * k, py(a) * k) end
local function dot(a, b) return px(a) * px(b) + py(a) * py(b) end
local function dist(a, b)
    local dx, dy = px(a) - px(b), py(a) - py(b)
    return math.sqrt(dx * dx + dy * dy)
end

local function lerp(a, b, t)
    return pt(px(a) + (px(b) - px(a)) * t,
              py(a) + (py(b) - py(a)) * t)
end

-- ===== Curve metatables ================================================

local quad_mt = {}; quad_mt.__index = quad_mt
local cube_mt = {}; cube_mt.__index = cube_mt

function M.quadratic(p0, p1, p2)
    return setmetatable({
        kind = "quadratic",
        p0   = pt(px(p0), py(p0)),
        p1   = pt(px(p1), py(p1)),
        p2   = pt(px(p2), py(p2)),
    }, quad_mt)
end

function M.cubic(p0, p1, p2, p3)
    return setmetatable({
        kind = "cubic",
        p0   = pt(px(p0), py(p0)),
        p1   = pt(px(p1), py(p1)),
        p2   = pt(px(p2), py(p2)),
        p3   = pt(px(p3), py(p3)),
    }, cube_mt)
end

-- ===== De Casteljau evaluation =========================================

function quad_mt:at(t)
    local mt = 1 - t
    local x = mt*mt*px(self.p0) + 2*mt*t*px(self.p1) + t*t*px(self.p2)
    local y = mt*mt*py(self.p0) + 2*mt*t*py(self.p1) + t*t*py(self.p2)
    return pt(x, y)
end

function cube_mt:at(t)
    local mt = 1 - t
    local mt2 = mt * mt
    local t2  = t * t
    local x = mt2*mt*px(self.p0) + 3*mt2*t*px(self.p1) +
              3*mt*t2*px(self.p2) + t2*t*px(self.p3)
    local y = mt2*mt*py(self.p0) + 3*mt2*t*py(self.p1) +
              3*mt*t2*py(self.p2) + t2*t*py(self.p3)
    return pt(x, y)
end

-- Derivative curves (quadratic -> linear, cubic -> quadratic) are evaluated
-- inline below.

function quad_mt:derivative_at(t)
    -- B'(t) = 2(1-t)(p1 - p0) + 2t(p2 - p1)
    local mt = 1 - t
    local d0 = sub_p(self.p1, self.p0)
    local d1 = sub_p(self.p2, self.p1)
    return pt(2 * mt * px(d0) + 2 * t * px(d1),
              2 * mt * py(d0) + 2 * t * py(d1))
end

function cube_mt:derivative_at(t)
    -- B'(t) = 3(1-t)^2 (p1-p0) + 6(1-t)t (p2-p1) + 3t^2 (p3-p2)
    local mt = 1 - t
    local d0 = sub_p(self.p1, self.p0)
    local d1 = sub_p(self.p2, self.p1)
    local d2 = sub_p(self.p3, self.p2)
    local a = 3 * mt * mt
    local b = 6 * mt * t
    local c = 3 * t * t
    return pt(a*px(d0) + b*px(d1) + c*px(d2),
              a*py(d0) + b*py(d1) + c*py(d2))
end

-- ===== Splitting (De Casteljau) =======================================

function quad_mt:split(t)
    local q0 = lerp(self.p0, self.p1, t)
    local q1 = lerp(self.p1, self.p2, t)
    local r  = lerp(q0, q1, t)
    return M.quadratic(self.p0, q0, r),
           M.quadratic(r, q1, self.p2)
end

function cube_mt:split(t)
    local q0 = lerp(self.p0, self.p1, t)
    local q1 = lerp(self.p1, self.p2, t)
    local q2 = lerp(self.p2, self.p3, t)
    local r0 = lerp(q0, q1, t)
    local r1 = lerp(q1, q2, t)
    local s  = lerp(r0, r1, t)
    return M.cubic(self.p0, q0, r0, s),
           M.cubic(s, r1, q2, self.p3)
end

-- ===== Arc length via adaptive Simpson ================================

local function speed_quad(c, t)
    local d = c:derivative_at(t)
    return math.sqrt(px(d) * px(d) + py(d) * py(d))
end

local function speed_cube(c, t)
    local d = c:derivative_at(t)
    return math.sqrt(px(d) * px(d) + py(d) * py(d))
end

-- Iterative composite Simpson on a fixed number of subdivisions. Adaptive
-- subdivision via deep recursion proved to interact badly with the JIT's tail
-- handling on some inputs, so we use a uniform composite rule which is more
-- than adequate for arc-length estimation of polynomial curves.
local function composite_simpson(f, a, b, n)
    if n % 2 == 1 then n = n + 1 end
    local h = (b - a) / n
    local sum = f(a) + f(b)
    for i = 1, n - 1 do
        local x = a + i * h
        if i % 2 == 1 then sum = sum + 4 * f(x)
        else               sum = sum + 2 * f(x) end
    end
    return sum * h / 3
end

local function arc_length(speed_fn, opts)
    opts = opts or {}
    local n = opts.samples or 64
    -- Richardson-extrapolated estimate: compute with n and 2n, accept if close.
    local tol = opts.tolerance or 1e-6
    local prev = composite_simpson(speed_fn, 0, 1, n)
    for _ = 1, 6 do
        n = n * 2
        local cur = composite_simpson(speed_fn, 0, 1, n)
        if math.abs(cur - prev) < tol * math.max(1, math.abs(cur)) then
            return cur
        end
        prev = cur
    end
    return prev
end

function quad_mt:length(opts)
    return arc_length(function(t) return speed_quad(self, t) end, opts)
end

function cube_mt:length(opts)
    return arc_length(function(t) return speed_cube(self, t) end, opts)
end

-- ===== Bounding box ====================================================

local function in_bounds(v, lo, hi)
    if v < lo then lo = v end
    if v > hi then hi = v end
    return lo, hi
end

function quad_mt:bounding_box()
    -- Roots of B'(t)=0 per axis: derivative is linear -> single root each.
    local function endpoints(p0v, p1v, p2v)
        local lo = math.min(p0v, p2v)
        local hi = math.max(p0v, p2v)
        local denom = p0v - 2 * p1v + p2v
        if denom ~= 0 then
            local t = (p0v - p1v) / denom
            if t > 0 and t < 1 then
                local mt = 1 - t
                local v = mt*mt*p0v + 2*mt*t*p1v + t*t*p2v
                lo, hi = in_bounds(v, lo, hi)
            end
        end
        return lo, hi
    end
    local minx, maxx = endpoints(px(self.p0), px(self.p1), px(self.p2))
    local miny, maxy = endpoints(py(self.p0), py(self.p1), py(self.p2))
    return { min_x = minx, max_x = maxx, min_y = miny, max_y = maxy }
end

function cube_mt:bounding_box()
    -- Derivative is quadratic; up to two roots per axis.
    local function endpoints(p0v, p1v, p2v, p3v)
        local lo = math.min(p0v, p3v)
        local hi = math.max(p0v, p3v)
        local a = -p0v + 3 * p1v - 3 * p2v + p3v
        local b =  2 * p0v - 4 * p1v + 2 * p2v
        local c = -p0v + p1v
        local function eval(t)
            local mt = 1 - t
            return mt*mt*mt*p0v + 3*mt*mt*t*p1v +
                   3*mt*t*t*p2v + t*t*t*p3v
        end
        -- B'(t) = 3 * (a t^2 + b t + c). Solve a t^2 + b t + c = 0.
        local roots = {}
        if math.abs(a) < 1e-12 then
            if math.abs(b) > 1e-12 then roots[1] = -c / b end
        else
            local disc = b * b - 4 * a * c
            if disc >= 0 then
                local sq = math.sqrt(disc)
                roots[1] = (-b + sq) / (2 * a)
                roots[2] = (-b - sq) / (2 * a)
            end
        end
        for _, t in ipairs(roots) do
            if t > 0 and t < 1 then
                lo, hi = in_bounds(eval(t), lo, hi)
            end
        end
        return lo, hi
    end
    local minx, maxx = endpoints(px(self.p0), px(self.p1), px(self.p2), px(self.p3))
    local miny, maxy = endpoints(py(self.p0), py(self.p1), py(self.p2), py(self.p3))
    return { min_x = minx, max_x = maxx, min_y = miny, max_y = maxy }
end

-- ===== Flatten (adaptive subdivision) =================================

local function is_flat_quad(c, tol)
    -- Distance from p1 to the chord p0->p2.
    local ax, ay = px(c.p0), py(c.p0)
    local bx, by = px(c.p2), py(c.p2)
    local cx, cy = px(c.p1), py(c.p1)
    local lx, ly = bx - ax, by - ay
    local L2 = lx*lx + ly*ly
    if L2 == 0 then return true end
    local t = ((cx - ax) * lx + (cy - ay) * ly) / L2
    local sx = ax + t * lx - cx
    local sy = ay + t * ly - cy
    return (sx*sx + sy*sy) <= tol * tol
end

local function is_flat_cube(c, tol)
    -- Maximum perpendicular distance from p1, p2 to the chord p0->p3.
    local ax, ay = px(c.p0), py(c.p0)
    local bx, by = px(c.p3), py(c.p3)
    local lx, ly = bx - ax, by - ay
    local L2 = lx*lx + ly*ly
    if L2 == 0 then
        local d1 = dist(c.p0, c.p1)
        local d2 = dist(c.p0, c.p2)
        return math.max(d1, d2) <= tol
    end
    local function perp(cx, cy)
        local t = ((cx - ax) * lx + (cy - ay) * ly) / L2
        local sx = ax + t * lx - cx
        local sy = ay + t * ly - cy
        return sx*sx + sy*sy
    end
    local d1 = perp(px(c.p1), py(c.p1))
    local d2 = perp(px(c.p2), py(c.p2))
    return math.max(d1, d2) <= tol * tol
end

local function flatten_into(c, out, tol, is_flat, depth, max_depth)
    if depth >= max_depth or is_flat(c, tol) then
        out[#out + 1] = pt(px(c.p0), py(c.p0))
        return
    end
    local l, r = c:split(0.5)
    flatten_into(l, out, tol, is_flat, depth + 1, max_depth)
    flatten_into(r, out, tol, is_flat, depth + 1, max_depth)
end

function quad_mt:flatten(tolerance)
    local tol = tolerance or 0.5
    local out = {}
    flatten_into(self, out, tol, is_flat_quad, 0, 24)
    out[#out + 1] = pt(px(self.p2), py(self.p2))
    return out
end

function cube_mt:flatten(tolerance)
    local tol = tolerance or 0.5
    local out = {}
    flatten_into(self, out, tol, is_flat_cube, 0, 24)
    out[#out + 1] = pt(px(self.p3), py(self.p3))
    return out
end

-- ===== Projection (closest t to point) ================================

local function project_curve(c, target, opts)
    opts = opts or {}
    local samples = opts.samples or 32
    local best_t, best_d2 = 0, math.huge
    for i = 0, samples do
        local t = i / samples
        local p = c:at(t)
        local dx, dy = px(p) - px(target), py(p) - py(target)
        local d2 = dx*dx + dy*dy
        if d2 < best_d2 then best_d2, best_t = d2, t end
    end
    -- Newton refinement using B(t)-P . B'(t) = 0.
    local iters = opts.refine_iters or 12
    for _ = 1, iters do
        local p  = c:at(best_t)
        local d  = c:derivative_at(best_t)
        local diff = sub_p(p, target)
        local num = dot(diff, d)
        local denom = dot(d, d)
        if denom == 0 then break end
        local delta = num / denom
        local nt = best_t - delta
        if nt < 0 then nt = 0 end
        if nt > 1 then nt = 1 end
        if math.abs(nt - best_t) < 1e-9 then best_t = nt; break end
        best_t = nt
    end
    return best_t
end

function quad_mt:project(target, opts) return project_curve(self, target, opts) end
function cube_mt:project(target, opts) return project_curve(self, target, opts) end

-- ===== SVG path emission ==============================================

function quad_mt:to_path()
    return string.format("M %.6f %.6f Q %.6f %.6f %.6f %.6f",
        px(self.p0), py(self.p0),
        px(self.p1), py(self.p1),
        px(self.p2), py(self.p2))
end

function cube_mt:to_path()
    return string.format("M %.6f %.6f C %.6f %.6f %.6f %.6f %.6f %.6f",
        px(self.p0), py(self.p0),
        px(self.p1), py(self.p1),
        px(self.p2), py(self.p2),
        px(self.p3), py(self.p3))
end

-- ===== Cubic fitting (Schneider-style, single curve) ==================
-- Given an ordered sequence of points, returns a single cubic that
-- approximates them (start and end clamped to first/last point, tangents
-- chosen from local secants, control magnitudes solved via least squares).

local function chord_lengths(points)
    local n = #points
    local d = { 0 }
    for i = 2, n do d[i] = d[i - 1] + dist(points[i - 1], points[i]) end
    local total = d[n]
    if total == 0 then total = 1 end
    local u = {}
    for i = 1, n do u[i] = d[i] / total end
    return u
end

local function normalize(v)
    local m = math.sqrt(px(v) * px(v) + py(v) * py(v))
    if m == 0 then return pt(0, 0) end
    return pt(px(v) / m, py(v) / m)
end

local function bern(i, t)
    -- Bernstein basis for cubic.
    local mt = 1 - t
    if i == 0 then return mt*mt*mt end
    if i == 1 then return 3*mt*mt*t end
    if i == 2 then return 3*mt*t*t end
    if i == 3 then return t*t*t end
end

function M.fit(points, opts)
    if #points < 2 then
        error("bezier.fit: need at least 2 points")
    end
    if #points == 2 then
        -- Degenerate -- straight cubic.
        local p0, p3 = points[1], points[2]
        local p1 = lerp(p0, p3, 1/3)
        local p2 = lerp(p0, p3, 2/3)
        return M.cubic(p0, p1, p2, p3)
    end
    local n = #points
    local p0 = points[1]
    local p3 = points[n]
    local tan1 = normalize(sub_p(points[2],   p0))
    local tan2 = normalize(sub_p(points[n-1], p3))  -- inward; we'll flip sign
    local u = chord_lengths(points)

    -- Least-squares system: solve for alpha1, alpha2 such that
    --   p1 = p0 + alpha1 * tan1
    --   p2 = p3 + alpha2 * (-tan2)   (tan2 reversed to point outward toward p3)
    local C11, C12, C22, X1, X2 = 0, 0, 0, 0, 0
    local neg_tan2 = pt(-px(tan2), -py(tan2))
    for i = 1, n do
        local t  = u[i]
        local A1 = scale_p(tan1, bern(1, t))
        local A2 = scale_p(neg_tan2, bern(2, t))
        local target = sub_p(points[i],
            add_p(scale_p(p0, bern(0, t) + bern(1, t)),
                  scale_p(p3, bern(2, t) + bern(3, t))))
        C11 = C11 + dot(A1, A1)
        C12 = C12 + dot(A1, A2)
        C22 = C22 + dot(A2, A2)
        X1  = X1  + dot(A1, target)
        X2  = X2  + dot(A2, target)
    end
    local det = C11 * C22 - C12 * C12
    local alpha1, alpha2
    if math.abs(det) < 1e-12 then
        -- Heuristic: use chord-length / 3.
        local total = dist(p0, p3)
        alpha1 = total / 3
        alpha2 = total / 3
    else
        alpha1 = (X1 * C22 - X2 * C12) / det
        alpha2 = (C11 * X2 - C12 * X1) / det
    end
    -- Guard against negative magnitudes.
    local total = dist(p0, p3)
    if alpha1 < 1e-6 then alpha1 = total / 3 end
    if alpha2 < 1e-6 then alpha2 = total / 3 end

    local p1 = add_p(p0, scale_p(tan1, alpha1))
    local p2 = add_p(p3, scale_p(neg_tan2, alpha2))
    return M.cubic(p0, p1, p2, p3)
end

return M
