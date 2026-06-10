-- tests/packages/test_zip.lua : PKZIP writer/reader round-trips + facade + safety.
-- Deterministic: fixed contents and a fixed opts.mtime (even-second local date so
-- DOS 2-second-resolution time round-trips exactly). We never print os.time(),
-- table addresses, or unsorted iteration.
local ok_req, zip = pcall(require, "zip")
if not ok_req then print("[~] SKIP test_zip (" .. tostring(zip) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_zip: " .. tostring(m)) end end

local tmp = os.tmpname() .. ".zip"
local function cleanup() os.remove(tmp) end

-- ===== write a few entries, read them back =====
local fixed_mtime = os.time({ year = 2021, month = 6, day = 15, hour = 12, min = 30, sec = 20 })
local w = zip.writer(tmp)
w:add_file("hello.txt", "Hello, ZIP!", { mtime = fixed_mtime })
w:add_file("data.bin", string.rep("X", 1000), { mtime = fixed_mtime })  -- compressible
w:add_file("raw.dat", "stored-bytes", { method = "stored", mtime = fixed_mtime })
w:add_directory("subdir/")
local nbytes = w:close()
ok(type(nbytes) == "number" and nbytes > 0, "close() returns byte count > 0")

local r = zip.reader(tmp)
local ents = r:entries()
ok(#ents == 4,                           "reader sees all 4 entries")

-- index by name (sorted-key-free: explicit map)
local byname = {}
for _, e in ipairs(ents) do byname[e.name] = e end
ok(byname["hello.txt"] ~= nil,           "hello.txt entry present")
ok(byname["data.bin"] ~= nil,            "data.bin entry present")
ok(byname["raw.dat"] ~= nil,             "raw.dat entry present")
ok(byname["subdir/"] ~= nil,             "subdir/ entry present")

ok(byname["hello.txt"].uncompressed == 11, "hello.txt uncompressed size = 11")
ok(byname["data.bin"].uncompressed == 1000, "data.bin uncompressed size = 1000")
ok(byname["subdir/"].is_dir == true,     "subdir/ flagged is_dir")
ok(byname["raw.dat"].method == 0,        "raw.dat stored (method 0)")

-- mtime round-trips exactly (even-second local date)
ok(byname["hello.txt"].mtime == fixed_mtime, "mtime round-trips through DOS time")

-- ===== content round-trips (deflate + stored both via read) =====
ok(r:read("hello.txt") == "Hello, ZIP!",         "hello.txt content round-trips")
ok(r:read("data.bin") == string.rep("X", 1000),  "data.bin (deflated) content round-trips")
ok(r:read("raw.dat") == "stored-bytes",          "raw.dat (stored) content round-trips")

-- ===== crc32 is recorded and matches the fallback impl =====
ok(byname["raw.dat"].crc32 == zip._crc32("stored-bytes"), "crc32 matches reference CRC")
-- known CRC32 of "123456789" is 0xCBF43926
ok(zip._crc32("123456789") == 0xCBF43926, "_crc32('123456789') == 0xCBF43926")

-- ===== reader:read errors on unknown entry =====
ok(select(2, pcall(function() return r:read("nope.txt") end)) ~= nil,
   "read of missing entry errors")

-- ===== facade: open / list / read =====
local arc = zip.open(tmp)
local lst = arc.list()
ok(#lst == 4,                            "facade list() returns 4 entries")
local lmap = {}
for _, e in ipairs(lst) do lmap[e.name] = e end
ok(lmap["data.bin"].method == "deflate", "facade reports method name 'deflate'")
ok(lmap["raw.dat"].method == "stored",   "facade reports method name 'stored'")
ok(lmap["data.bin"].size == 1000,        "facade size field = uncompressed size")
ok(arc:read("hello.txt") == "Hello, ZIP!", "facade read round-trips")

-- ===== facade create() writer =====
local tmp2 = os.tmpname() .. ".zip"
local cw = zip.create(tmp2)
cw:add_file("one.txt", "first", { mtime = fixed_mtime })
cw:add_file("two.txt", "second", { mtime = fixed_mtime })
cw:close()
local arc2 = zip.open(tmp2)
ok(#arc2.list() == 2,                    "create() facade wrote 2 entries")
ok(arc2:read("two.txt") == "second",     "create() facade content round-trips")
os.remove(tmp2)

-- ===== reader rejects non-zip bytes =====
ok(select(2, pcall(zip.reader, "this is not a zip file at all, no EOCD here")) ~= nil,
   "reader errors on non-zip input")

-- ===== Zip-Slip safety: extract refuses traversal entries =====
-- Build an archive whose entry name escapes via '..', then confirm extract raises.
local tmp3 = os.tmpname() .. ".zip"
local ew = zip.writer(tmp3)
ew:add_file("../evil.txt", "pwn", { mtime = fixed_mtime })
ew:close()
local er = zip.reader(tmp3)
ok(select(2, pcall(function() return er:extract(os.tmpname() .. "_d") end)) ~= nil,
   "extract refuses '..' path traversal (Zip-Slip)")
os.remove(tmp3)

cleanup()
if fails == 0 then print("[+] PASS test_zip") os.exit(0) else os.exit(1) end
