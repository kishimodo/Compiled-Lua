-- noise -- Procedural noise: Perlin, simplex, value, Voronoi, fbm, ridged.
--
-- All generators are deterministic given a seed. The permutation table is
-- expanded from SplitMix64(seed), so different seeds give independent fields.
--
-- Output ranges (approximate):
--   perlin 2D/3D : -1 .. 1
--   simplex 2D/3D: -1 .. 1
--   value 2D/3D  :  0 .. 1
--   voronoi      :  distances are in noise-space units (lattice unit = 1)
--
-- Public surface:
--   noise.perlin(x, y, z?, opts?)
--   noise.simplex(x, y, z?, opts?)
--   noise.value(x, y, z?, opts?)
--   noise.voronoi(x, y, opts?)            -> { f1, f2, cell_id }
--   noise.fbm(fn, x, y, z?, opts?)        opts.octaves/frequency/amplitude/persistence/lacunarity
--   noise.ridged_multifractal(fn, x, y, z?, opts?)

local M = {}

local floor = math.floor
local sqrt  = math.sqrt
local abs   = math.abs

-- ===== SplitMix64-seeded permutation cache ============================

local function splitmix64(state)
    -- 64-bit step in pure Lua 5.4 integer ops.
    state = (state + 0x9e3779b97f4a7c15) & 0xffffffffffffffff
    local z = state
    z = ((z ~ (z >> 30)) * 0xbf58476d1ce4e5b9) & 0xffffffffffffffff
    z = ((z ~ (z >> 27)) * 0x94d049bb133111eb) & 0xffffffffffffffff
    z = z ~ (z >> 31)
    return z, state
end

local PERM_CACHE = {}

local function get_perm(seed)
    seed = seed or 0
    local cached = PERM_CACHE[seed]
    if cached then return cached end
    -- Build [0..255] then shuffle Fisher-Yates with splitmix64.
    local p = {}
    for i = 0, 255 do p[i] = i end
    local state = seed & 0xffffffffffffffff
    if state == 0 then state = 0x9e3779b97f4a7c15 end
    for i = 255, 1, -1 do
        local r, ns = splitmix64(state)
        state = ns
        local j = r % (i + 1)
        p[i], p[j] = p[j], p[i]
    end
    -- Duplicate to 0..511 for index wrapping.
    for i = 0, 255 do p[256 + i] = p[i] end
    PERM_CACHE[seed] = p
    return p
end

-- ===== Smoothing curves ===============================================

local function fade(t)
    -- Quintic fade Perlin used in his 2002 simplex paper.
    return t * t * t * (t * (t * 6 - 15) + 10)
end

local function smoothstep(t)
    return t * t * (3 - 2 * t)
end

local function lerp(a, b, t) return a + (b - a) * t end

-- ===== Perlin gradients ===============================================

local function grad2(h, x, y)
    -- 8 gradient directions on the unit circle (octants).
    h = h & 7
    local u, v
    if h < 4 then u = x else u = y end
    if h < 4 then v = y else v = x end
    if (h & 1) ~= 0 then u = -u end
    if (h & 2) ~= 0 then v = -v end
    return u + v
end

local function grad3(h, x, y, z)
    -- Ken Perlin's 12 edge gradients on the unit cube.
    h = h & 15
    local u = (h < 8) and x or y
    local v
    if h < 4 then v = y
    elseif h == 12 or h == 14 then v = x
    else v = z end
    if (h & 1) ~= 0 then u = -u end
    if (h & 2) ~= 0 then v = -v end
    return u + v
end

-- ===== Perlin =========================================================

local function perlin2(x, y, perm)
    local xi = floor(x) & 255
    local yi = floor(y) & 255
    local xf = x - floor(x)
    local yf = y - floor(y)
    local u = fade(xf)
    local v = fade(yf)
    local aa = perm[perm[xi]     + yi]
    local ab = perm[perm[xi]     + yi + 1]
    local ba = perm[perm[xi + 1] + yi]
    local bb = perm[perm[xi + 1] + yi + 1]
    local n00 = grad2(aa, xf,     yf)
    local n10 = grad2(ba, xf - 1, yf)
    local n01 = grad2(ab, xf,     yf - 1)
    local n11 = grad2(bb, xf - 1, yf - 1)
    local x1 = lerp(n00, n10, u)
    local x2 = lerp(n01, n11, u)
    return lerp(x1, x2, v)
end

local function perlin3(x, y, z, perm)
    local xi = floor(x) & 255
    local yi = floor(y) & 255
    local zi = floor(z) & 255
    local xf = x - floor(x)
    local yf = y - floor(y)
    local zf = z - floor(z)
    local u = fade(xf)
    local v = fade(yf)
    local w = fade(zf)
    local A  = perm[xi]     + yi
    local AA = perm[A]      + zi
    local AB = perm[A + 1]  + zi
    local B  = perm[xi + 1] + yi
    local BA = perm[B]      + zi
    local BB = perm[B + 1]  + zi
    local x1 = lerp(grad3(perm[AA],     xf,     yf,     zf),
                    grad3(perm[BA],     xf - 1, yf,     zf), u)
    local x2 = lerp(grad3(perm[AB],     xf,     yf - 1, zf),
                    grad3(perm[BB],     xf - 1, yf - 1, zf), u)
    local y1 = lerp(x1, x2, v)
    x1 = lerp(grad3(perm[AA + 1],       xf,     yf,     zf - 1),
              grad3(perm[BA + 1],       xf - 1, yf,     zf - 1), u)
    x2 = lerp(grad3(perm[AB + 1],       xf,     yf - 1, zf - 1),
              grad3(perm[BB + 1],       xf - 1, yf - 1, zf - 1), u)
    local y2 = lerp(x1, x2, v)
    return lerp(y1, y2, w)
end

function M.perlin(x, y, z, opts)
    if type(z) == "table" then opts = z; z = nil end
    opts = opts or {}
    local perm = get_perm(opts.seed)
    if z == nil then return perlin2(x, y, perm) end
    return perlin3(x, y, z, perm)
end

-- ===== Simplex ========================================================
-- 2D and 3D simplex per Ken Perlin (2001).

local F2 = 0.5 * (sqrt(3) - 1)
local G2 = (3 - sqrt(3)) / 6
local F3 = 1.0 / 3.0
local G3 = 1.0 / 6.0

local SIMPLEX_GRAD3 = {
    { 1, 1, 0}, {-1, 1, 0}, { 1,-1, 0}, {-1,-1, 0},
    { 1, 0, 1}, {-1, 0, 1}, { 1, 0,-1}, {-1, 0,-1},
    { 0, 1, 1}, { 0,-1, 1}, { 0, 1,-1}, { 0,-1,-1},
}

local function dot2(g, x, y) return g[1] * x + g[2] * y end
local function dot3(g, x, y, z) return g[1] * x + g[2] * y + g[3] * z end

local function simplex2(xin, yin, perm)
    local s  = (xin + yin) * F2
    local i  = floor(xin + s)
    local j  = floor(yin + s)
    local t  = (i + j) * G2
    local x0 = xin - (i - t)
    local y0 = yin - (j - t)
    local i1, j1
    if x0 > y0 then i1, j1 = 1, 0 else i1, j1 = 0, 1 end
    local x1 = x0 - i1 + G2
    local y1 = y0 - j1 + G2
    local x2 = x0 - 1 + 2 * G2
    local y2 = y0 - 1 + 2 * G2
    local ii = i & 255
    local jj = j & 255
    local gi0 = perm[ii      + perm[jj]]            % 12 + 1
    local gi1 = perm[ii + i1 + perm[jj + j1]]       % 12 + 1
    local gi2 = perm[ii + 1  + perm[jj + 1]]        % 12 + 1
    local n0, n1, n2 = 0, 0, 0
    local t0 = 0.5 - x0 * x0 - y0 * y0
    if t0 > 0 then t0 = t0 * t0; n0 = t0 * t0 * dot2(SIMPLEX_GRAD3[gi0], x0, y0) end
    local t1 = 0.5 - x1 * x1 - y1 * y1
    if t1 > 0 then t1 = t1 * t1; n1 = t1 * t1 * dot2(SIMPLEX_GRAD3[gi1], x1, y1) end
    local t2 = 0.5 - x2 * x2 - y2 * y2
    if t2 > 0 then t2 = t2 * t2; n2 = t2 * t2 * dot2(SIMPLEX_GRAD3[gi2], x2, y2) end
    return 70 * (n0 + n1 + n2)
end

local function simplex3(xin, yin, zin, perm)
    local s  = (xin + yin + zin) * F3
    local i  = floor(xin + s)
    local j  = floor(yin + s)
    local k  = floor(zin + s)
    local t  = (i + j + k) * G3
    local x0 = xin - (i - t)
    local y0 = yin - (j - t)
    local z0 = zin - (k - t)
    local i1, j1, k1, i2, j2, k2
    if x0 >= y0 then
        if y0 >= z0 then i1,j1,k1, i2,j2,k2 = 1,0,0, 1,1,0
        elseif x0 >= z0 then i1,j1,k1, i2,j2,k2 = 1,0,0, 1,0,1
        else i1,j1,k1, i2,j2,k2 = 0,0,1, 1,0,1 end
    else
        if y0 < z0 then i1,j1,k1, i2,j2,k2 = 0,0,1, 0,1,1
        elseif x0 < z0 then i1,j1,k1, i2,j2,k2 = 0,1,0, 0,1,1
        else i1,j1,k1, i2,j2,k2 = 0,1,0, 1,1,0 end
    end
    local x1 = x0 - i1 + G3
    local y1 = y0 - j1 + G3
    local z1 = z0 - k1 + G3
    local x2 = x0 - i2 + 2 * G3
    local y2 = y0 - j2 + 2 * G3
    local z2 = z0 - k2 + 2 * G3
    local x3 = x0 - 1  + 3 * G3
    local y3 = y0 - 1  + 3 * G3
    local z3 = z0 - 1  + 3 * G3
    local ii = i & 255
    local jj = j & 255
    local kk = k & 255
    local gi0 = perm[ii      + perm[jj      + perm[kk]]]            % 12 + 1
    local gi1 = perm[ii + i1 + perm[jj + j1 + perm[kk + k1]]]       % 12 + 1
    local gi2 = perm[ii + i2 + perm[jj + j2 + perm[kk + k2]]]       % 12 + 1
    local gi3 = perm[ii + 1  + perm[jj + 1  + perm[kk + 1]]]        % 12 + 1
    local n0, n1, n2, n3 = 0, 0, 0, 0
    local t0 = 0.6 - x0*x0 - y0*y0 - z0*z0
    if t0 > 0 then t0 = t0 * t0; n0 = t0 * t0 * dot3(SIMPLEX_GRAD3[gi0], x0, y0, z0) end
    local t1 = 0.6 - x1*x1 - y1*y1 - z1*z1
    if t1 > 0 then t1 = t1 * t1; n1 = t1 * t1 * dot3(SIMPLEX_GRAD3[gi1], x1, y1, z1) end
    local t2 = 0.6 - x2*x2 - y2*y2 - z2*z2
    if t2 > 0 then t2 = t2 * t2; n2 = t2 * t2 * dot3(SIMPLEX_GRAD3[gi2], x2, y2, z2) end
    local t3 = 0.6 - x3*x3 - y3*y3 - z3*z3
    if t3 > 0 then t3 = t3 * t3; n3 = t3 * t3 * dot3(SIMPLEX_GRAD3[gi3], x3, y3, z3) end
    return 32 * (n0 + n1 + n2 + n3)
end

function M.simplex(x, y, z, opts)
    if type(z) == "table" then opts = z; z = nil end
    opts = opts or {}
    local perm = get_perm(opts.seed)
    if z == nil then return simplex2(x, y, perm) end
    return simplex3(x, y, z, perm)
end

-- ===== Value noise ====================================================

local function hash_to_unit(perm, xi, yi, zi)
    -- Combine perm entries into a deterministic value in [0, 1).
    if zi then
        local h = perm[(perm[(perm[xi & 255] + yi) & 255] + zi) & 255]
        return h / 255
    end
    local h = perm[(perm[xi & 255] + yi) & 255]
    return h / 255
end

local function value2(x, y, perm)
    local xi = floor(x); local xf = x - xi
    local yi = floor(y); local yf = y - yi
    local u = smoothstep(xf)
    local v = smoothstep(yf)
    local n00 = hash_to_unit(perm, xi,     yi)
    local n10 = hash_to_unit(perm, xi + 1, yi)
    local n01 = hash_to_unit(perm, xi,     yi + 1)
    local n11 = hash_to_unit(perm, xi + 1, yi + 1)
    return lerp(lerp(n00, n10, u), lerp(n01, n11, u), v)
end

local function value3(x, y, z, perm)
    local xi = floor(x); local xf = x - xi
    local yi = floor(y); local yf = y - yi
    local zi = floor(z); local zf = z - zi
    local u = smoothstep(xf)
    local v = smoothstep(yf)
    local w = smoothstep(zf)
    local n000 = hash_to_unit(perm, xi,     yi,     zi)
    local n100 = hash_to_unit(perm, xi + 1, yi,     zi)
    local n010 = hash_to_unit(perm, xi,     yi + 1, zi)
    local n110 = hash_to_unit(perm, xi + 1, yi + 1, zi)
    local n001 = hash_to_unit(perm, xi,     yi,     zi + 1)
    local n101 = hash_to_unit(perm, xi + 1, yi,     zi + 1)
    local n011 = hash_to_unit(perm, xi,     yi + 1, zi + 1)
    local n111 = hash_to_unit(perm, xi + 1, yi + 1, zi + 1)
    local y1 = lerp(lerp(n000, n100, u), lerp(n010, n110, u), v)
    local y2 = lerp(lerp(n001, n101, u), lerp(n011, n111, u), v)
    return lerp(y1, y2, w)
end

function M.value(x, y, z, opts)
    if type(z) == "table" then opts = z; z = nil end
    opts = opts or {}
    local perm = get_perm(opts.seed)
    if z == nil then return value2(x, y, perm) end
    return value3(x, y, z, perm)
end

-- ===== Voronoi / Worley =============================================

function M.voronoi(x, y, opts)
    opts = opts or {}
    local perm = get_perm(opts.seed)
    local xi = floor(x)
    local yi = floor(y)
    local f1, f2 = math.huge, math.huge
    local cell_id = 0
    for oy = -1, 1 do
        for ox = -1, 1 do
            local cx = xi + ox
            local cy = yi + oy
            -- Two hash values per cell -> jittered point inside the cell.
            local h1 = perm[(perm[cx & 255] + (cy & 255)) & 255] / 255
            local h2 = perm[(perm[(cx + 17) & 255] + ((cy + 31) & 255)) & 255] / 255
            local px = cx + h1
            local py = cy + h2
            local dx = px - x
            local dy = py - y
            local d  = sqrt(dx * dx + dy * dy)
            if d < f1 then
                f2 = f1
                f1 = d
                cell_id = ((cx & 255) << 8) | (cy & 255)
            elseif d < f2 then
                f2 = d
            end
        end
    end
    return { f1 = f1, f2 = f2, cell_id = cell_id }
end

-- ===== Fractal layering ==============================================

local function call_noise(fn, x, y, z, seed)
    if z == nil then return fn(x, y, { seed = seed }) end
    return fn(x, y, z, { seed = seed })
end

function M.fbm(noise_fn, x, y, z, opts)
    if type(z) == "table" then opts = z; z = nil end
    opts = opts or {}
    local octaves     = opts.octaves     or 4
    local freq        = opts.frequency   or 1
    local amp         = opts.amplitude   or 1
    local persistence = opts.persistence or 0.5
    local lacunarity  = opts.lacunarity  or 2
    local seed        = opts.seed
    local total, max_amp = 0, 0
    for _ = 1, octaves do
        if z == nil then
            total = total + call_noise(noise_fn, x * freq, y * freq, nil, seed) * amp
        else
            total = total + call_noise(noise_fn, x * freq, y * freq, z * freq, seed) * amp
        end
        max_amp = max_amp + amp
        amp = amp * persistence
        freq = freq * lacunarity
    end
    if max_amp == 0 then return 0 end
    return total / max_amp
end

function M.ridged_multifractal(noise_fn, x, y, z, opts)
    if type(z) == "table" then opts = z; z = nil end
    opts = opts or {}
    local octaves     = opts.octaves     or 4
    local freq        = opts.frequency   or 1
    local amp         = opts.amplitude   or 1
    local persistence = opts.persistence or 0.5
    local lacunarity  = opts.lacunarity  or 2
    local offset      = opts.offset      or 1.0
    local seed        = opts.seed
    local total, max_amp = 0, 0
    local weight = 1
    for _ = 1, octaves do
        local n
        if z == nil then
            n = call_noise(noise_fn, x * freq, y * freq, nil, seed)
        else
            n = call_noise(noise_fn, x * freq, y * freq, z * freq, seed)
        end
        n = offset - abs(n)
        n = n * n
        n = n * weight
        weight = n * 2
        if weight < 0 then weight = 0 end
        if weight > 1 then weight = 1 end
        total = total + n * amp
        max_amp = max_amp + amp
        amp = amp * persistence
        freq = freq * lacunarity
    end
    if max_amp == 0 then return 0 end
    return total / max_amp
end

return M
