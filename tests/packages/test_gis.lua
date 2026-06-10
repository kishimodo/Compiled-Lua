-- Regression test for the builtin `gis` package.
-- Asserts geo math against known-correct reference values (not the code's own output).
local ok_req, gis = pcall(require, "gis")
if not ok_req then print("[~] SKIP test_gis") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_gis: " .. tostring(m)) end end
local function approx(a, b, tol) return math.abs(a - b) <= tol end

local LONDON = { lat = 51.5074, lon = -0.1278 }
local PARIS  = { lat = 48.8566, lon = 2.3522 }

-- Haversine distance London->Paris. Reference ~343.5 km. distance() returns
-- METERS by default; ask for km via opts.unit.
local d_km = gis.distance(LONDON, PARIS, { unit = "km" })
ok(approx(d_km, 343.5, 5), "London->Paris haversine km ~343.5, got " .. tostring(d_km))

-- Default unit is meters: the km value times 1000 must match.
local d_m = gis.distance(LONDON, PARIS)
ok(approx(d_m, d_km * 1000, 1), "default unit is meters: " .. tostring(d_m) .. " vs " .. tostring(d_km * 1000))

-- Indexed point form {lat, lon} must give the same result as keyed form.
local d_idx = gis.distance({ 51.5074, -0.1278 }, { 48.8566, 2.3522 }, { unit = "km" })
ok(approx(d_idx, d_km, 1e-6), "indexed point form matches keyed form")

-- destination() then haversine back must round-trip to the given distance.
-- distance arg is in METERS by default.
local DIST_M = 100000          -- 100 km
local BRG    = 45              -- degrees clockwise from north
local dest = gis.destination(LONDON, BRG, DIST_M)
ok(type(dest) == "table" and dest.lat ~= nil and dest.lon ~= nil, "destination returns {lat,lon}")
local back_m = gis.distance(LONDON, dest)   -- meters
ok(approx(back_m, DIST_M, 100), "destination round-trip distance ~" .. DIST_M .. ", got " .. tostring(back_m))

-- bearing from London toward a point due north should be ~0 degrees.
local north_pt = gis.destination(LONDON, 0, 50000)
local brg_north = gis.bearing(LONDON, north_pt)
ok(approx(brg_north, 0, 0.5) or approx(brg_north, 360, 0.5), "bearing due north ~0, got " .. tostring(brg_north))

-- polygon_area of a 1-degree equatorial square ~= 1.23e10 m^2.
-- 1 deg of arc at the equator ~ EARTH_R * pi/180 = 111194.9 m; square ~ 1.236e10 m^2.
local square = {
    { lat = 0, lon = 0 },
    { lat = 0, lon = 1 },
    { lat = 1, lon = 1 },
    { lat = 1, lon = 0 },
}
local area = gis.polygon_area(square)
ok(approx(area, 1.236e10, 5e8), "1-deg equatorial square area ~1.23e10 m^2, got " .. tostring(area))

-- Degenerate polygon (< 3 points) -> 0.
ok(gis.polygon_area({ { lat = 0, lon = 0 }, { lat = 1, lon = 1 } }) == 0, "polygon_area of 2 points is 0")

-- Geohash encode/decode round-trip. London geohash (precision 9) is a known value.
local gh = gis.geohash(LONDON.lat, LONDON.lon, 9)
ok(gh == "gcpvj0duq", "London geohash precision 9 == gcpvj0duq, got " .. tostring(gh))
local dec = gis.from_geohash(gh)
ok(approx(dec.lat, LONDON.lat, dec.lat_err) and approx(dec.lon, LONDON.lon, dec.lon_err),
   "from_geohash recovers London within its error box")
-- Decoded center must be within the cell error of the original.
ok(approx(dec.lat, LONDON.lat, 0.001) and approx(dec.lon, LONDON.lon, 0.001),
   "geohash precision-9 round-trip is tight")

-- point_in_polygon: a clearly-inside point vs a clearly-outside point.
ok(gis.point_in_polygon({ lat = 0.5, lon = 0.5 }, square) == true, "center is inside the unit square")
ok(gis.point_in_polygon({ lat = 5, lon = 5 }, square) == false, "far point is outside the unit square")

-- bounding_box of the square.
local bb = gis.bounding_box(square)
ok(bb.min_lat == 0 and bb.max_lat == 1 and bb.min_lon == 0 and bb.max_lon == 1, "bounding_box of unit square")

if fails == 0 then print("[+] PASS test_gis") os.exit(0) else os.exit(1) end
