-- gis -- Geographic / GIS helpers.
--
-- Coordinate convention: points are { lat = degrees, lon = degrees }.
-- Indexing as { [1]=lat, [2]=lon } also works.
--
-- Public surface:
--   gis.distance(p1, p2, opts?)         opts = {algorithm="haversine"|"vincenty", unit="m"|"km"|"mi"}
--   gis.bearing(p1, p2)                 -> degrees clockwise from north
--   gis.final_bearing(p1, p2)           -> degrees
--   gis.destination(p, brg, dist, opts?) opts = {unit="m"|"km"|"mi"}
--   gis.bounding_box(points)            -> { min_lat, min_lon, max_lat, max_lon }
--   gis.geohash(lat, lon, precision?)   -> string
--   gis.from_geohash(hash)              -> {lat, lon, lat_err, lon_err, bbox}
--   gis.geohash_neighbors(hash)         -> { n, ne, e, se, s, sw, w, nw }
--   gis.polygon_area(points)            -> square meters (WGS84 sphere approx)
--   gis.point_in_polygon(point, poly)   -> boolean
--   gis.segment_intersection(a1,a2,b1,b2) -> point or nil
--   gis.project(point, proj)            -> {x, y}
--   gis.unproject(xy, proj)             -> {lat, lon}
--
-- Constants:
--   gis.WGS84_A = 6378137.0      -- semi-major axis
--   gis.WGS84_B = 6356752.314245
--   gis.WGS84_F = 1/298.257223563
--   gis.EARTH_R = 6371008.8      -- mean radius

local M = {}

local pi   = math.pi
local sin  = math.sin
local cos  = math.cos
local tan  = math.tan
local asin = math.asin
local acos = math.acos
local atan = math.atan
local sqrt = math.sqrt
local rad  = function(d) return d * pi / 180 end
local deg  = function(r) return r * 180 / pi end

M.WGS84_A = 6378137.0
M.WGS84_B = 6356752.314245
M.WGS84_F = 1 / 298.257223563
M.EARTH_R = 6371008.8

-- ===== Helpers ========================================================

local function latlon(p)
    -- Accept {lat=..., lon=...} or {lat, lon}.
    local la = p.lat or p[1]
    local lo = p.lon or p[2]
    return la, lo
end

local function unit_factor(u)
    if not u or u == "m"  then return 1 end
    if u == "km" then return 1e-3 end
    if u == "mi" then return 1 / 1609.344 end
    if u == "nmi" then return 1 / 1852 end
    if u == "ft" then return 1 / 0.3048 end
    error("gis: unknown distance unit '" .. tostring(u) .. "'")
end

-- ===== Distance =======================================================

local function haversine(la1, lo1, la2, lo2)
    local phi1, phi2 = rad(la1), rad(la2)
    local dphi = rad(la2 - la1)
    local dlam = rad(lo2 - lo1)
    local a = sin(dphi * 0.5) ^ 2 +
              cos(phi1) * cos(phi2) * sin(dlam * 0.5) ^ 2
    local c = 2 * math.atan(sqrt(a), sqrt(1 - a))
    return M.EARTH_R * c
end

local function vincenty(la1, lo1, la2, lo2)
    -- Vincenty inverse formula on the WGS84 ellipsoid.
    local a = M.WGS84_A
    local b = M.WGS84_B
    local f = M.WGS84_F
    local L = rad(lo2 - lo1)
    local U1 = math.atan((1 - f) * tan(rad(la1)))
    local U2 = math.atan((1 - f) * tan(rad(la2)))
    local sinU1, cosU1 = sin(U1), cos(U1)
    local sinU2, cosU2 = sin(U2), cos(U2)
    local lambda = L
    local lambdaP, iter = 2 * pi, 0
    local cos2sigma_m, sin_sigma, cos_sigma, sigma, sin_alpha, cos_sq_alpha
    while math.abs(lambda - lambdaP) > 1e-12 and iter < 200 do
        local sinL, cosL = sin(lambda), cos(lambda)
        sin_sigma = sqrt((cosU2 * sinL) ^ 2 +
                         (cosU1 * sinU2 - sinU1 * cosU2 * cosL) ^ 2)
        if sin_sigma == 0 then return 0 end
        cos_sigma = sinU1 * sinU2 + cosU1 * cosU2 * cosL
        sigma     = math.atan(sin_sigma, cos_sigma)
        sin_alpha = cosU1 * cosU2 * sinL / sin_sigma
        cos_sq_alpha = 1 - sin_alpha * sin_alpha
        if cos_sq_alpha == 0 then
            cos2sigma_m = 0     -- equatorial
        else
            cos2sigma_m = cos_sigma - 2 * sinU1 * sinU2 / cos_sq_alpha
        end
        local C = f / 16 * cos_sq_alpha * (4 + f * (4 - 3 * cos_sq_alpha))
        lambdaP = lambda
        lambda  = L + (1 - C) * f * sin_alpha *
                  (sigma + C * sin_sigma *
                   (cos2sigma_m + C * cos_sigma *
                    (-1 + 2 * cos2sigma_m ^ 2)))
        iter = iter + 1
    end
    if iter >= 200 then
        -- Fall back to haversine for antipodal pathological inputs.
        return haversine(la1, lo1, la2, lo2)
    end
    local u_sq  = cos_sq_alpha * (a * a - b * b) / (b * b)
    local A_term = 1 + u_sq / 16384 *
                   (4096 + u_sq * (-768 + u_sq * (320 - 175 * u_sq)))
    local B_term = u_sq / 1024 *
                   (256 + u_sq * (-128 + u_sq * (74 - 47 * u_sq)))
    local d_sigma = B_term * sin_sigma *
                    (cos2sigma_m + B_term / 4 *
                     (cos_sigma * (-1 + 2 * cos2sigma_m ^ 2) -
                      B_term / 6 * cos2sigma_m * (-3 + 4 * sin_sigma ^ 2) *
                      (-3 + 4 * cos2sigma_m ^ 2)))
    return b * A_term * (sigma - d_sigma)
end

function M.distance(p1, p2, opts)
    opts = opts or {}
    local la1, lo1 = latlon(p1)
    local la2, lo2 = latlon(p2)
    local d
    if opts.algorithm == "vincenty" then
        d = vincenty(la1, lo1, la2, lo2)
    else
        d = haversine(la1, lo1, la2, lo2)
    end
    return d * unit_factor(opts.unit)
end

-- ===== Bearing ========================================================

function M.bearing(p1, p2)
    local la1, lo1 = latlon(p1)
    local la2, lo2 = latlon(p2)
    local phi1, phi2 = rad(la1), rad(la2)
    local dlam = rad(lo2 - lo1)
    local y = sin(dlam) * cos(phi2)
    local x = cos(phi1) * sin(phi2) -
              sin(phi1) * cos(phi2) * cos(dlam)
    local brg = deg(math.atan(y, x))
    return (brg + 360) % 360
end

function M.final_bearing(p1, p2)
    -- Final bearing = initial bearing from p2 to p1 reversed.
    local b = M.bearing(p2, p1)
    return (b + 180) % 360
end

-- ===== Destination point =============================================

function M.destination(p, brg_deg, distance, opts)
    opts = opts or {}
    local f = unit_factor(opts.unit)
    local d = distance / f / M.EARTH_R       -- angular distance
    local la1, lo1 = latlon(p)
    local phi1, lam1 = rad(la1), rad(lo1)
    local brg = rad(brg_deg)
    local phi2 = asin(sin(phi1) * cos(d) +
                      cos(phi1) * sin(d) * cos(brg))
    local lam2 = lam1 + math.atan(sin(brg) * sin(d) * cos(phi1),
                                  cos(d) - sin(phi1) * sin(phi2))
    return { lat = deg(phi2), lon = ((deg(lam2) + 540) % 360) - 180 }
end

-- ===== Bounding box ===================================================

function M.bounding_box(points)
    if #points == 0 then return nil end
    local la, lo = latlon(points[1])
    local min_lat, max_lat = la, la
    local min_lon, max_lon = lo, lo
    for i = 2, #points do
        la, lo = latlon(points[i])
        if la < min_lat then min_lat = la end
        if la > max_lat then max_lat = la end
        if lo < min_lon then min_lon = lo end
        if lo > max_lon then max_lon = lo end
    end
    return {
        min_lat = min_lat, max_lat = max_lat,
        min_lon = min_lon, max_lon = max_lon,
        sw = { lat = min_lat, lon = min_lon },
        ne = { lat = max_lat, lon = max_lon },
    }
end

-- ===== Geohash ========================================================

local BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz"
local BASE32_DECODE = {}
for i = 1, #BASE32 do BASE32_DECODE[BASE32:sub(i, i)] = i - 1 end

function M.geohash(lat, lon, precision)
    precision = precision or 9
    local lat_lo, lat_hi = -90.0, 90.0
    local lon_lo, lon_hi = -180.0, 180.0
    local out = {}
    local bit = 0
    local ch = 0
    local even = true
    while #out < precision do
        if even then
            local mid = (lon_lo + lon_hi) * 0.5
            if lon >= mid then ch = (ch << 1) | 1; lon_lo = mid
            else ch = ch << 1; lon_hi = mid end
        else
            local mid = (lat_lo + lat_hi) * 0.5
            if lat >= mid then ch = (ch << 1) | 1; lat_lo = mid
            else ch = ch << 1; lat_hi = mid end
        end
        even = not even
        bit = bit + 1
        if bit == 5 then
            out[#out + 1] = BASE32:sub(ch + 1, ch + 1)
            bit, ch = 0, 0
        end
    end
    return table.concat(out)
end

function M.from_geohash(hash)
    local lat_lo, lat_hi = -90.0, 90.0
    local lon_lo, lon_hi = -180.0, 180.0
    local even = true
    for i = 1, #hash do
        local c = hash:sub(i, i)
        local v = BASE32_DECODE[c]
        if v == nil then error("gis: bad geohash char '" .. c .. "'") end
        for bit = 4, 0, -1 do
            local bv = (v >> bit) & 1
            if even then
                local mid = (lon_lo + lon_hi) * 0.5
                if bv == 1 then lon_lo = mid else lon_hi = mid end
            else
                local mid = (lat_lo + lat_hi) * 0.5
                if bv == 1 then lat_lo = mid else lat_hi = mid end
            end
            even = not even
        end
    end
    local lat = (lat_lo + lat_hi) * 0.5
    local lon = (lon_lo + lon_hi) * 0.5
    return {
        lat = lat, lon = lon,
        lat_err = (lat_hi - lat_lo) * 0.5,
        lon_err = (lon_hi - lon_lo) * 0.5,
        bbox = { min_lat = lat_lo, max_lat = lat_hi,
                 min_lon = lon_lo, max_lon = lon_hi },
    }
end

-- Geohash neighbor lookup tables (Niemeyer's algorithm).
local NEIGHBORS = {
    n = { even = "p0r21436x8zb9dcf5h7kjnmqesgutwvy",
          odd  = "bc01fg45238967deuvhjyznpkmstqrwx" },
    s = { even = "14365h7k9dcfesgujnmqp0r2twvyx8zb",
          odd  = "238967debc01fg45kmstqrwxuvhjyznp" },
    e = { even = "bc01fg45238967deuvhjyznpkmstqrwx",
          odd  = "p0r21436x8zb9dcf5h7kjnmqesgutwvy" },
    w = { even = "238967debc01fg45kmstqrwxuvhjyznp",
          odd  = "14365h7k9dcfesgujnmqp0r2twvyx8zb" },
}
local BORDERS = {
    n = { even = "prxz",     odd  = "bcfguvyz" },
    s = { even = "028b",     odd  = "0145hjnp" },
    e = { even = "bcfguvyz", odd  = "prxz" },
    w = { even = "0145hjnp", odd  = "028b" },
}

local function adjacent(hash, dir)
    if hash == "" then return "" end
    local last = hash:sub(-1)
    local parent = hash:sub(1, -2)
    local kind = (#hash % 2 == 0) and "even" or "odd"
    if BORDERS[dir][kind]:find(last, 1, true) and parent ~= "" then
        parent = adjacent(parent, dir)
    end
    local idx = NEIGHBORS[dir][kind]:find(last, 1, true)
    return parent .. BASE32:sub(idx, idx)
end

function M.geohash_neighbors(hash)
    return {
        n  = adjacent(hash, "n"),
        s  = adjacent(hash, "s"),
        e  = adjacent(hash, "e"),
        w  = adjacent(hash, "w"),
        ne = adjacent(adjacent(hash, "n"), "e"),
        nw = adjacent(adjacent(hash, "n"), "w"),
        se = adjacent(adjacent(hash, "s"), "e"),
        sw = adjacent(adjacent(hash, "s"), "w"),
    }
end

-- ===== Polygon area + point-in-polygon ================================

function M.polygon_area(points)
    -- L'Huilier-based spherical polygon area on Earth radius.
    local n = #points
    if n < 3 then return 0 end
    local total = 0
    for i = 1, n do
        local la1, lo1 = latlon(points[i])
        local la2, lo2 = latlon(points[(i % n) + 1])
        total = total + (rad(lo2) - rad(lo1)) *
                        (2 + sin(rad(la1)) + sin(rad(la2)))
    end
    return math.abs(total * M.EARTH_R * M.EARTH_R * 0.5)
end

function M.point_in_polygon(point, polygon)
    local plat, plon = latlon(point)
    local n = #polygon
    local inside = false
    local j = n
    for i = 1, n do
        local lai, loi = latlon(polygon[i])
        local laj, loj = latlon(polygon[j])
        if ((loi > plon) ~= (loj > plon)) then
            local at = (laj - lai) * (plon - loi) / (loj - loi) + lai
            if plat < at then inside = not inside end
        end
        j = i
    end
    return inside
end

-- ===== Segment intersection ==========================================

function M.segment_intersection(a1, a2, b1, b2)
    -- Planar approximation in lat/lon (good for small extents). Returns the
    -- intersection point in lat/lon if the segments cross, else nil.
    local a1la, a1lo = latlon(a1); local a2la, a2lo = latlon(a2)
    local b1la, b1lo = latlon(b1); local b2la, b2lo = latlon(b2)
    local denom = (a1lo - a2lo) * (b1la - b2la) -
                  (a1la - a2la) * (b1lo - b2lo)
    if denom == 0 then return nil end
    local t = ((a1lo - b1lo) * (b1la - b2la) -
               (a1la - b1la) * (b1lo - b2lo)) / denom
    local u = -((a1lo - a2lo) * (a1la - b1la) -
                (a1la - a2la) * (a1lo - b1lo)) / denom
    if t < 0 or t > 1 or u < 0 or u > 1 then return nil end
    return {
        lat = a1la + t * (a2la - a1la),
        lon = a1lo + t * (a2lo - a1lo),
    }
end

-- ===== Projections ====================================================

local R = M.WGS84_A
local MAX_LAT_MERC = 85.05112878

local function project_mercator(p)
    local la, lo = latlon(p)
    if la >  MAX_LAT_MERC then la =  MAX_LAT_MERC end
    if la < -MAX_LAT_MERC then la = -MAX_LAT_MERC end
    local x = R * rad(lo)
    local y = R * math.log(tan(pi / 4 + rad(la) / 2))
    return { x = x, y = y }
end

local function unproject_mercator(xy)
    local x, y = xy.x or xy[1], xy.y or xy[2]
    local lon = deg(x / R)
    local lat = deg(2 * atan(math.exp(y / R)) - pi / 2)
    return { lat = lat, lon = lon }
end

local function project_web_mercator(p)
    local la, lo = latlon(p)
    if la >  MAX_LAT_MERC then la =  MAX_LAT_MERC end
    if la < -MAX_LAT_MERC then la = -MAX_LAT_MERC end
    local x = R * rad(lo)
    local y = R * math.log(tan(pi / 4 + rad(la) / 2))
    return { x = x, y = y }
end

local function unproject_web_mercator(xy)
    return unproject_mercator(xy)
end

local function project_equirectangular(p)
    local la, lo = latlon(p)
    return { x = R * rad(lo), y = R * rad(la) }
end

local function unproject_equirectangular(xy)
    local x, y = xy.x or xy[1], xy.y or xy[2]
    return { lat = deg(y / R), lon = deg(x / R) }
end

local PROJ_FWD = {
    mercator           = project_mercator,
    ["web-mercator"]   = project_web_mercator,
    web_mercator       = project_web_mercator,
    equirectangular    = project_equirectangular,
}
local PROJ_INV = {
    mercator           = unproject_mercator,
    ["web-mercator"]   = unproject_web_mercator,
    web_mercator       = unproject_web_mercator,
    equirectangular    = unproject_equirectangular,
}

function M.project(point, proj)
    local f = PROJ_FWD[proj]
    if not f then error("gis: unknown projection '" .. tostring(proj) .. "'") end
    return f(point)
end

function M.unproject(xy, proj)
    local f = PROJ_INV[proj]
    if not f then error("gis: unknown projection '" .. tostring(proj) .. "'") end
    return f(xy)
end

return M
