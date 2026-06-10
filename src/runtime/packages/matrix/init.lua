-- matrix -- general MxN dense matrices.
--
-- Storage: row-major in a flat array (m.data[(i-1)*cols + j]).
-- A flat array beats nested tables in LuaJIT because the JIT can hoist the
-- single array load and skip a pointer deref per element.
--
-- Public surface:
--   matrix.new(rows, cols, data?)        -- data is row-major flat or nested
--   matrix.identity(n), matrix.zeros(r,c), matrix.ones(r,c)
--   matrix.from_rows({{...},{...}})      -- nested-table constructor
--   m:get(i,j), m:set(i,j,v)
--   m:rows(), m:cols()
--   m:transpose(), m:add(o), m:sub(o), m:mul(o)
--   m:scale(s), m:row(i), m:col(j), m:submatrix(r1,c1,r2,c2)
--   m:det(), m:inv(), m:lu(), m:qr()
--   m:eigenvalues()                       -- 2x2 / 3x3 closed form
--   Graphics: matrix.rotation_x/y/z, scale, translation, perspective, lookat
--   Operators: + - * unm == tostring

local vec = require "vector"

local M  = {}
local mt = {}

local sqrt, abs = math.sqrt, math.abs
local sin, cos, tan = math.sin, math.cos, math.tan

local function is_m(x) return type(x) == "table" and getmetatable(x) == mt end

local function alloc(rows, cols)
    local m = setmetatable({ r = rows, c = cols, data = {} }, mt)
    local n = rows * cols
    for i = 1, n do m.data[i] = 0 end
    return m
end

function M.new(rows, cols, data)
    local m = alloc(rows, cols)
    if data == nil then return m end
    if type(data[1]) == "table" then
        -- nested row form
        for i = 1, rows do
            local row = data[i]
            for j = 1, cols do
                m.data[(i - 1) * cols + j] = row[j] or 0
            end
        end
    else
        for k = 1, rows * cols do m.data[k] = data[k] or 0 end
    end
    return m
end

function M.from_rows(rows)
    if not rows or #rows == 0 then error("matrix.from_rows: empty") end
    local r = #rows
    local c = #rows[1]
    return M.new(r, c, rows)
end

function M.identity(n)
    local m = alloc(n, n)
    for i = 1, n do m.data[(i - 1) * n + i] = 1 end
    return m
end

function M.zeros(r, c) return alloc(r, c) end

function M.ones(r, c)
    local m = alloc(r, c)
    for i = 1, r * c do m.data[i] = 1 end
    return m
end

function M.random(r, c, lo, hi)
    -- uniform entries in [lo, hi); defaults to [0, 1)
    lo = lo or 0; hi = hi or 1
    local m = alloc(r, c)
    local span = hi - lo
    for i = 1, r * c do m.data[i] = lo + math.random() * span end
    return m
end

function M.diag(d)
    -- d: array of length n -> n x n diagonal matrix
    local n = #d
    local m = alloc(n, n)
    for i = 1, n do m.data[(i - 1) * n + i] = d[i] end
    return m
end

function M.rows(m) return m.r end
function M.cols(m) return m.c end

function M.get(m, i, j) return m.data[(i - 1) * m.c + j] end
function M.set(m, i, j, v) m.data[(i - 1) * m.c + j] = v end

function M.clone(m)
    local out = alloc(m.r, m.c)
    for i = 1, m.r * m.c do out.data[i] = m.data[i] end
    return out
end

-- ===== Slicing =========================================================

function M.row(m, i)
    local v = vec.new(m.c)
    local off = (i - 1) * m.c
    for j = 1, m.c do v[j] = m.data[off + j] end
    return v
end

function M.col(m, j)
    local v = vec.new(m.r)
    for i = 1, m.r do v[i] = m.data[(i - 1) * m.c + j] end
    return v
end

function M.submatrix(m, r1, c1, r2, c2)
    local rr = r2 - r1 + 1
    local cc = c2 - c1 + 1
    local out = alloc(rr, cc)
    for i = 1, rr do
        for j = 1, cc do
            out.data[(i - 1) * cc + j] = m.data[(r1 + i - 2) * m.c + c1 + j - 1]
        end
    end
    return out
end

-- ===== Element-wise ====================================================

function M.add(a, b)
    if a.r ~= b.r or a.c ~= b.c then error("matrix.add: shape mismatch") end
    local out = alloc(a.r, a.c)
    for k = 1, a.r * a.c do out.data[k] = a.data[k] + b.data[k] end
    return out
end

function M.sub(a, b)
    if a.r ~= b.r or a.c ~= b.c then error("matrix.sub: shape mismatch") end
    local out = alloc(a.r, a.c)
    for k = 1, a.r * a.c do out.data[k] = a.data[k] - b.data[k] end
    return out
end

function M.scale(a, s)
    local out = alloc(a.r, a.c)
    for k = 1, a.r * a.c do out.data[k] = a.data[k] * s end
    return out
end

function M.neg(a)
    local out = alloc(a.r, a.c)
    for k = 1, a.r * a.c do out.data[k] = -a.data[k] end
    return out
end

function M.transpose(a)
    local out = alloc(a.c, a.r)
    for i = 1, a.r do
        for j = 1, a.c do
            out.data[(j - 1) * a.r + i] = a.data[(i - 1) * a.c + j]
        end
    end
    return out
end

-- ===== Multiplication ==================================================

local function mat_mat(a, b)
    if a.c ~= b.r then error("matrix.mul: inner dim mismatch") end
    local out = alloc(a.r, b.c)
    -- standard triple loop; the JIT will unroll the inner accumulator
    for i = 1, a.r do
        for j = 1, b.c do
            local s = 0
            local ar_off = (i - 1) * a.c
            for k = 1, a.c do
                s = s + a.data[ar_off + k] * b.data[(k - 1) * b.c + j]
            end
            out.data[(i - 1) * b.c + j] = s
        end
    end
    return out
end

local function mat_vec(a, v)
    if a.c ~= v.n then error("matrix.mul: matrix cols != vector dim") end
    local out = vec.new(a.r)
    for i = 1, a.r do
        local s = 0
        local off = (i - 1) * a.c
        for k = 1, a.c do s = s + a.data[off + k] * v[k] end
        out[i] = s
    end
    return out
end

function M.mul(a, b)
    if type(b) == "number" then return M.scale(a, b) end
    if type(a) == "number" then return M.scale(b, a) end
    -- vector second operand
    if type(b) == "table" and b.n and not is_m(b) then return mat_vec(a, b) end
    return mat_mat(a, b)
end

-- ===== Determinant =====================================================
--
-- Closed-form expansions for 2x2 / 3x3 / 4x4 are noticeably faster than LU
-- and avoid any pivoting decisions; for larger matrices we fall through to LU.

local function det2(m)
    return m.data[1] * m.data[4] - m.data[2] * m.data[3]
end

local function det3(m)
    local a, b, c = m.data[1], m.data[2], m.data[3]
    local d, e, f = m.data[4], m.data[5], m.data[6]
    local g, h, i = m.data[7], m.data[8], m.data[9]
    return a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
end

local function det4(m)
    local d = m.data
    local a00,a01,a02,a03 = d[ 1],d[ 2],d[ 3],d[ 4]
    local a10,a11,a12,a13 = d[ 5],d[ 6],d[ 7],d[ 8]
    local a20,a21,a22,a23 = d[ 9],d[10],d[11],d[12]
    local a30,a31,a32,a33 = d[13],d[14],d[15],d[16]
    local s0 = a00 * a11 - a10 * a01
    local s1 = a00 * a12 - a10 * a02
    local s2 = a00 * a13 - a10 * a03
    local s3 = a01 * a12 - a11 * a02
    local s4 = a01 * a13 - a11 * a03
    local s5 = a02 * a13 - a12 * a03
    local c5 = a22 * a33 - a32 * a23
    local c4 = a21 * a33 - a31 * a23
    local c3 = a21 * a32 - a31 * a22
    local c2 = a20 * a33 - a30 * a23
    local c1 = a20 * a32 - a30 * a22
    local c0 = a20 * a31 - a30 * a21
    return s0 * c5 - s1 * c4 + s2 * c3 + s3 * c2 - s4 * c1 + s5 * c0
end

-- ===== LU with partial pivoting ========================================
--
-- Doolittle form with row exchanges. Returns L, U, P (as a permutation array),
-- and the parity of the permutation -- needed by det() to fix the sign.

function M.lu(m)
    if m.r ~= m.c then error("matrix.lu: square only") end
    local n = m.r
    -- work in a single buffer that ends up holding LU combined; L is unit-diag
    local a = {}
    for k = 1, n * n do a[k] = m.data[k] end
    local p = {}
    for i = 1, n do p[i] = i end
    local sign = 1

    for k = 1, n do
        -- partial pivot: pick row with largest |a[i,k]|
        local max_v, max_i = abs(a[(k - 1) * n + k]), k
        for i = k + 1, n do
            local v = abs(a[(i - 1) * n + k])
            if v > max_v then max_v = v; max_i = i end
        end
        if max_v == 0 then error("matrix.lu: singular matrix") end
        if max_i ~= k then
            -- swap rows k and max_i in a
            for j = 1, n do
                local i1 = (k - 1) * n + j
                local i2 = (max_i - 1) * n + j
                a[i1], a[i2] = a[i2], a[i1]
            end
            p[k], p[max_i] = p[max_i], p[k]
            sign = -sign
        end
        -- eliminate
        local piv = a[(k - 1) * n + k]
        for i = k + 1, n do
            local f = a[(i - 1) * n + k] / piv
            a[(i - 1) * n + k] = f
            for j = k + 1, n do
                a[(i - 1) * n + j] = a[(i - 1) * n + j] - f * a[(k - 1) * n + j]
            end
        end
    end

    -- extract L and U from a
    local L = M.identity(n)
    local U = alloc(n, n)
    for i = 1, n do
        for j = 1, n do
            if i > j then
                L.data[(i - 1) * n + j] = a[(i - 1) * n + j]
            else
                U.data[(i - 1) * n + j] = a[(i - 1) * n + j]
            end
        end
    end
    return L, U, p, sign
end

function M.det(m)
    if m.r ~= m.c then error("matrix.det: square only") end
    local n = m.r
    if n == 1 then return m.data[1] end
    if n == 2 then return det2(m) end
    if n == 3 then return det3(m) end
    if n == 4 then return det4(m) end
    -- general: LU
    local ok, L, U, _, sign = pcall(M.lu, m)
    if not ok then return 0 end  -- singular
    local _ = L
    local d = sign
    for i = 1, n do d = d * U.data[(i - 1) * n + i] end
    return d
end

-- ===== Inverse =========================================================
--
-- Closed-form for 2x2/3x3/4x4; LU back-substitution otherwise.

local function inv2(m)
    local d = det2(m)
    if d == 0 then error("matrix.inv: singular") end
    local inv_d = 1 / d
    local out = alloc(2, 2)
    out.data[1] =  m.data[4] * inv_d
    out.data[2] = -m.data[2] * inv_d
    out.data[3] = -m.data[3] * inv_d
    out.data[4] =  m.data[1] * inv_d
    return out
end

local function inv3(m)
    local a, b, c = m.data[1], m.data[2], m.data[3]
    local d, e, f = m.data[4], m.data[5], m.data[6]
    local g, h, i = m.data[7], m.data[8], m.data[9]
    local A =  (e * i - f * h)
    local B = -(d * i - f * g)
    local C =  (d * h - e * g)
    local det = a * A + b * B + c * C
    if det == 0 then error("matrix.inv: singular") end
    local inv_d = 1 / det
    local out = alloc(3, 3)
    out.data[1] = A * inv_d
    out.data[2] = -(b * i - c * h) * inv_d
    out.data[3] =  (b * f - c * e) * inv_d
    out.data[4] = B * inv_d
    out.data[5] =  (a * i - c * g) * inv_d
    out.data[6] = -(a * f - c * d) * inv_d
    out.data[7] = C * inv_d
    out.data[8] = -(a * h - b * g) * inv_d
    out.data[9] =  (a * e - b * d) * inv_d
    return out
end

local function lu_solve(L, U, p, rhs)
    -- forward / back substitution on the permuted RHS
    local n = L.r
    local y = {}
    for i = 1, n do
        local s = rhs[p[i]]
        for j = 1, i - 1 do s = s - L.data[(i - 1) * n + j] * y[j] end
        y[i] = s
    end
    local x = {}
    for i = n, 1, -1 do
        local s = y[i]
        for j = i + 1, n do s = s - U.data[(i - 1) * n + j] * x[j] end
        x[i] = s / U.data[(i - 1) * n + i]
    end
    return x
end

function M.inv(m)
    if m.r ~= m.c then error("matrix.inv: square only") end
    local n = m.r
    if n == 2 then return inv2(m) end
    if n == 3 then return inv3(m) end
    -- general: solve for each column of identity
    local L, U, p = M.lu(m)
    local out = alloc(n, n)
    local rhs = {}
    for col = 1, n do
        for i = 1, n do rhs[i] = (i == col) and 1 or 0 end
        local x = lu_solve(L, U, p, rhs)
        for i = 1, n do out.data[(i - 1) * n + col] = x[i] end
    end
    return out
end

M.inverse = M.inv

function M.trace(m)
    if m.r ~= m.c then error("matrix.trace: square only") end
    local s = 0
    for i = 1, m.r do s = s + m.data[(i - 1) * m.c + i] end
    return s
end

function M.solve(a, b)
    -- Solve A x = b. b can be a Lua array (length r) or a vector. Returns
    -- the solution as a plain Lua array so callers can wrap in vec.new()
    -- if they want a vector object.
    if a.r ~= a.c then error("matrix.solve: square A only") end
    local n = a.r
    local rhs = {}
    if type(b) == "table" and b.n then
        for i = 1, n do rhs[i] = b[i] end
    else
        for i = 1, n do rhs[i] = b[i] end
    end
    if #rhs ~= n then error("matrix.solve: rhs length mismatch") end
    local L, U, p = M.lu(a)
    return lu_solve(L, U, p, rhs)
end

function M.rank(m, tol)
    -- Numerical rank via row reduction with partial pivoting; counts pivots
    -- whose magnitude exceeds tol. Tolerance defaults to a scale-aware
    -- machine-epsilon multiple.
    local rows, cols = m.r, m.c
    local a = {}
    for k = 1, rows * cols do a[k] = m.data[k] end
    -- compute a default tolerance from the largest absolute entry
    if tol == nil then
        local maxv = 0
        for k = 1, rows * cols do
            local v = abs(a[k])
            if v > maxv then maxv = v end
        end
        tol = math.max(rows, cols) * maxv * 2.22e-16
        if tol == 0 then tol = 1e-12 end
    end
    local r = 0
    local col = 1
    for row = 1, rows do
        if col > cols then break end
        -- find pivot
        local pivot_row = row
        local pivot_val = abs(a[(row - 1) * cols + col])
        for i = row + 1, rows do
            local v = abs(a[(i - 1) * cols + col])
            if v > pivot_val then pivot_val = v; pivot_row = i end
        end
        if pivot_val <= tol then
            col = col + 1
            -- retry this row at the next column
            -- (we abuse the for-iter by adjusting `row` manually -- impossible
            -- in Lua's numeric for. Instead, recurse the inner loop here.)
            while col <= cols do
                pivot_row = row
                pivot_val = abs(a[(row - 1) * cols + col])
                for i = row + 1, rows do
                    local v = abs(a[(i - 1) * cols + col])
                    if v > pivot_val then pivot_val = v; pivot_row = i end
                end
                if pivot_val > tol then break end
                col = col + 1
            end
            if col > cols then return r end
        end
        if pivot_row ~= row then
            for j = 1, cols do
                local i1 = (row - 1) * cols + j
                local i2 = (pivot_row - 1) * cols + j
                a[i1], a[i2] = a[i2], a[i1]
            end
        end
        -- eliminate below
        local piv = a[(row - 1) * cols + col]
        for i = row + 1, rows do
            local f = a[(i - 1) * cols + col] / piv
            for j = col, cols do
                a[(i - 1) * cols + j] = a[(i - 1) * cols + j] - f * a[(row - 1) * cols + j]
            end
        end
        r = r + 1
        col = col + 1
    end
    return r
end

-- ===== QR (Gram-Schmidt, modified) =====================================
--
-- Modified Gram-Schmidt is numerically stable enough for small matrices
-- where the matrix package is most likely to be used. For tall/thin matrices
-- the same algorithm produces a "thin" Q (m x n) and an n x n R.

function M.qr(m)
    local rows, cols = m.r, m.c
    if rows < cols then error("matrix.qr: requires rows >= cols") end
    local Q = alloc(rows, cols)
    local R = alloc(cols, cols)
    -- copy columns of m into Q
    for i = 1, rows do
        for j = 1, cols do
            Q.data[(i - 1) * cols + j] = m.data[(i - 1) * cols + j]
        end
    end
    for k = 1, cols do
        -- norm of column k of Q
        local s = 0
        for i = 1, rows do
            local v = Q.data[(i - 1) * cols + k]
            s = s + v * v
        end
        local nrm = sqrt(s)
        if nrm == 0 then error("matrix.qr: rank-deficient") end
        R.data[(k - 1) * cols + k] = nrm
        for i = 1, rows do
            Q.data[(i - 1) * cols + k] = Q.data[(i - 1) * cols + k] / nrm
        end
        for j = k + 1, cols do
            local dot = 0
            for i = 1, rows do
                dot = dot + Q.data[(i - 1) * cols + k] * Q.data[(i - 1) * cols + j]
            end
            R.data[(k - 1) * cols + j] = dot
            for i = 1, rows do
                Q.data[(i - 1) * cols + j] = Q.data[(i - 1) * cols + j] - dot * Q.data[(i - 1) * cols + k]
            end
        end
    end
    return Q, R
end

-- ===== Eigenvalues (small cases only) ==================================
--
-- Closed-form via the characteristic polynomial.
-- 2x2: roots of lambda^2 - tr*lambda + det = 0
-- 3x3: depressed cubic via Cardano; returns three real roots if discriminant
--      is non-negative, otherwise returns a single real + a complex-conjugate
--      pair represented as { type = "complex", re, im }.

function M.eigenvalues(m)
    if m.r ~= m.c then error("matrix.eigenvalues: square only") end
    local n = m.r
    if n == 1 then return { m.data[1] } end
    if n == 2 then
        local tr = m.data[1] + m.data[4]
        local d = det2(m)
        local disc = tr * tr - 4 * d
        if disc >= 0 then
            local s = sqrt(disc)
            return { (tr + s) * 0.5, (tr - s) * 0.5 }
        end
        local s = sqrt(-disc)
        return {
            { type = "complex", re = tr * 0.5, im =  s * 0.5 },
            { type = "complex", re = tr * 0.5, im = -s * 0.5 },
        }
    end
    if n == 3 then
        -- characteristic polynomial: lambda^3 - c2*lambda^2 + c1*lambda - c0
        local d = m.data
        local a11, a12, a13 = d[1], d[2], d[3]
        local a21, a22, a23 = d[4], d[5], d[6]
        local a31, a32, a33 = d[7], d[8], d[9]
        local c2 = a11 + a22 + a33
        local c1 = a11 * a22 - a12 * a21 + a11 * a33 - a13 * a31 + a22 * a33 - a23 * a32
        local c0 = det3(m)
        -- depress with lambda = mu + c2/3 -> mu^3 + p*mu + q = 0
        local p = c1 - c2 * c2 / 3
        -- q is the constant term of the monic depressed cubic mu^3 + p*mu + q = 0
        -- obtained by substituting lambda = mu + c2/3 into
        -- lambda^3 - c2*lambda^2 + c1*lambda - c0. The Cardano/trig formulas
        -- below already assume THIS sign; a spurious `q = -q` used to flip it,
        -- making every 3x3 eigenvalue wrong (diag(2,3,5) -> {4.67,3.67,1.67}).
        local q = -c0 + c2 * c1 / 3 - 2 * c2 * c2 * c2 / 27
        local disc = (q * q) / 4 + (p * p * p) / 27
        local offset = c2 / 3
        if disc > 0 then
            local sq = sqrt(disc)
            local u = -q / 2 + sq
            local v = -q / 2 - sq
            local function cbrt(x) return x >= 0 and x ^ (1 / 3) or -((-x) ^ (1 / 3)) end
            local mu = cbrt(u) + cbrt(v)
            -- two complex roots
            local re = -mu / 2 + offset
            local im_q = -3 * (cbrt(u) - cbrt(v)) ^ 2 / 4
            local im = sqrt(math.abs(im_q))
            return {
                mu + offset,
                { type = "complex", re = re, im =  im },
                { type = "complex", re = re, im = -im },
            }
        else
            -- three real roots via trig form
            local r = sqrt(-p * p * p / 27)
            local cos_arg = -q / (2 * r)
            if cos_arg >  1 then cos_arg =  1
            elseif cos_arg < -1 then cos_arg = -1 end
            local theta = math.acos(cos_arg) / 3
            local mag = 2 * (-p / 3) ^ 0.5
            return {
                mag * cos(theta)                + offset,
                mag * cos(theta - 2 * math.pi / 3) + offset,
                mag * cos(theta - 4 * math.pi / 3) + offset,
            }
        end
    end
    error("matrix.eigenvalues: closed-form only for n <= 3")
end

-- ===== Graphics builders ===============================================
--
-- Standard right-handed convention; matrices are 4x4 in row-major form
-- (apply as M * v where v is column vector). All angles in radians.

function M.translation(x, y, z)
    local m = M.identity(4)
    m.data[ 4] = x
    m.data[ 8] = y
    m.data[12] = z
    return m
end

function M.scale_matrix(sx, sy, sz)
    local m = M.identity(4)
    m.data[ 1] = sx
    m.data[ 6] = sy
    m.data[11] = sz
    return m
end

function M.rotation_x(theta)
    local c, s = cos(theta), sin(theta)
    local m = M.identity(4)
    m.data[ 6] =  c; m.data[ 7] = -s
    m.data[10] =  s; m.data[11] =  c
    return m
end

function M.rotation_y(theta)
    local c, s = cos(theta), sin(theta)
    local m = M.identity(4)
    m.data[ 1] =  c; m.data[ 3] =  s
    m.data[ 9] = -s; m.data[11] =  c
    return m
end

function M.rotation_z(theta)
    local c, s = cos(theta), sin(theta)
    local m = M.identity(4)
    m.data[ 1] =  c; m.data[ 2] = -s
    m.data[ 5] =  s; m.data[ 6] =  c
    return m
end

function M.perspective(fov_y, aspect, near, far)
    -- standard perspective projection (right-handed, depth in [-1, 1])
    local f = 1 / tan(fov_y * 0.5)
    local m = alloc(4, 4)
    m.data[ 1] = f / aspect
    m.data[ 6] = f
    m.data[11] = (far + near) / (near - far)
    m.data[12] = (2 * far * near) / (near - far)
    m.data[15] = -1
    return m
end

function M.lookat(eye, target, up)
    -- right-handed look-at; eye/target/up are 3-vectors
    local f = vec.normalize(vec.sub(target, eye))
    local s = vec.normalize(vec.cross(f, up))
    local u = vec.cross(s, f)
    local m = M.identity(4)
    m.data[ 1] =  s[1]; m.data[ 2] =  s[2]; m.data[ 3] =  s[3]
    m.data[ 5] =  u[1]; m.data[ 6] =  u[2]; m.data[ 7] =  u[3]
    m.data[ 9] = -f[1]; m.data[10] = -f[2]; m.data[11] = -f[3]
    m.data[ 4] = -vec.dot(s, eye)
    m.data[ 8] = -vec.dot(u, eye)
    m.data[12] =  vec.dot(f, eye)
    return m
end

-- ===== Pretty-print ====================================================

function M.tostring(m)
    local lines = {}
    for i = 1, m.r do
        local cells = {}
        for j = 1, m.c do cells[j] = string.format("%g", m.data[(i - 1) * m.c + j]) end
        lines[i] = "  " .. table.concat(cells, "  ")
    end
    return "[\n" .. table.concat(lines, "\n") .. "\n]"
end

function M.eq(a, b)
    if a.r ~= b.r or a.c ~= b.c then return false end
    for k = 1, a.r * a.c do if a.data[k] ~= b.data[k] then return false end end
    return true
end

-- ===== Metatable =======================================================

mt.__index    = function(_, k) return M[k] end
mt.__add      = M.add
mt.__sub      = M.sub
mt.__mul      = M.mul
mt.__unm      = M.neg
mt.__eq       = M.eq
mt.__tostring = M.tostring

return M
