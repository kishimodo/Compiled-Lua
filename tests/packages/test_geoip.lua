-- tests/packages/test_geoip.lua : MaxMind .mmdb reader (pure Lua, no DLL) for
-- the builtin `geoip` package.
--
-- There is no .mmdb fixture checked in, so we BUILD a minimal but fully valid
-- MaxMind DB in memory (record_size=24, ip_version=4) using the documented
-- control-byte encoding, write it to a temp file, and assert that geoip walks
-- the binary tree, follows the data pointer, and decodes the nested
-- map/string/uint32/double/boolean/array values exactly. Every expected value
-- is hand-encoded here, so it is independent of any external data and
-- byte-identical under the JIT and the interpreter (we never print the temp
-- path or any address).
--
-- Tree shape: one node (node_count=1). The left record (first IP bit = 0)
-- equals node_count => "no record". The right record (first IP bit = 1) points
-- at our single data map at data-section offset 0. So 128.0.0.0 resolves to the
-- record and 0.0.0.0 resolves to nil.

local ok_req, geoip = pcall(require, "geoip")
if not ok_req then print("[~] SKIP test_geoip (" .. tostring(geoip) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_geoip: " .. tostring(m)) end end

-- ===== MMDB byte builder (control-byte encoding) ======================
local function u24be(n) return string.char((n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff) end
-- control byte: type tag in bits 7..5, size in bits 4..0 (sizes < 29 only).
local function ctrl(tag, size) return string.char((tag << 5) | size) end
local function mstr(s)  return ctrl(2, #s) .. s end                       -- utf8 string
local function mu16(n)  return ctrl(5, 2) .. string.char((n >> 8) & 0xff, n & 0xff) end
local function mu32(n)  return ctrl(6, 4) .. string.char((n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff) end
local function mmap(n)  return ctrl(7, n) end                            -- map header (n pairs)
-- Extended types use control tag 0 (=> read an ext byte = real_type - 7).
-- Array is type 11: ctrl byte carries size in low bits, ext byte = 11-7 = 4.
local function marr(n)  return string.char((0 << 5) | n, 11 - 7) end
-- Boolean is type 14: size 0/1 carries the value; ext byte = 14-7 = 7.
local function mbool_enc(b) return string.char((0 << 5) | (b and 1 or 0), 14 - 7) end
-- IEEE754 double (big-endian), type tag 3, size 8.
local function mf64(x) return ctrl(3, 8) .. string.pack(">d", x) end

-- Build the single data record (a map):
--   { iso = "US", asn = 15169, score = 0.5, ok = true, names = { "a", "b" } }
local record =
  mmap(5)
    .. mstr("iso")   .. mstr("US")
    .. mstr("asn")   .. mu32(15169)
    .. mstr("score") .. mf64(0.5)
    .. mstr("ok")    .. mbool_enc(true)
    .. mstr("names") .. (marr(2) .. mstr("a") .. mstr("b"))

local data_section = record

-- Tree: record_size=24 (6 bytes/node), 1 node.
local node_count = 1
local left  = node_count            -- 1 => empty (no record)
local right = node_count + 16 + 0   -- 17 => data pointer to data offset 0
local tree = u24be(left) .. u24be(right)

local sep = string.rep("\0", 16)    -- 16-byte data-section separator

local meta =
  mmap(5)
    .. mstr("node_count")  .. mu16(node_count)
    .. mstr("record_size") .. mu16(24)
    .. mstr("ip_version")  .. mu16(4)
    .. mstr("database_type") .. mstr("Test-City")
    .. mstr("binary_format_major_version") .. mu16(2)

local MARKER = "\xAB\xCD\xEF" .. "MaxMind.com"
local mmdb = tree .. sep .. data_section .. MARKER .. meta

-- ===== write to a temp file ===========================================
local path = os.tmpname()
do
  local f, werr = io.open(path, "wb")
  ok(f ~= nil, "can open temp file for writing: " .. tostring(werr))
  if f then f:write(mmdb); f:close() end
end

-- ===== open + metadata ================================================
local r, oerr = geoip.open(path)
ok(r ~= nil, "geoip.open succeeds on a valid in-memory mmdb: " .. tostring(oerr))
if r then
  local md = r:metadata()
  ok(type(md) == "table", "metadata() returns a table")
  ok(md.node_count == 1, "metadata node_count is 1")
  ok(md.record_size == 24, "metadata record_size is 24")
  ok(md.ip_version == 4, "metadata ip_version is 4")
  ok(md.database_type == "Test-City", "metadata database_type decodes (utf8 string)")
  ok(md.binary_format_major_version == 2, "metadata binary_format_major_version is 2")

  -- ===== lookup that resolves (first IP bit = 1) ======================
  local d = r:lookup("128.0.0.0")
  ok(type(d) == "table", "lookup 128.0.0.0 resolves to a data map")
  if type(d) == "table" then
    ok(d.iso == "US", "string field decodes: iso == 'US'")
    ok(d.asn == 15169, "uint32 field decodes: asn == 15169")
    ok(d.score == 0.5, "double field decodes: score == 0.5")
    ok(d.ok == true, "boolean field decodes: ok == true")
    ok(type(d.names) == "table" and #d.names == 2, "array field decodes to length 2")
    ok(d.names[1] == "a" and d.names[2] == "b", "array elements decode in order")
  end

  -- ===== lookup with no record (first IP bit = 0) =====================
  local none = r:lookup("0.0.0.0")
  ok(none == nil, "lookup 0.0.0.0 (empty left record) returns nil")

  -- Another address whose first bit is 1 (e.g. 200.1.2.3) hits the same record.
  local d2 = r:lookup("200.1.2.3")
  ok(type(d2) == "table" and d2.iso == "US", "any 1xx-2xx first-octet IP resolves the right record")

  -- ===== malformed IP returns nil + error =============================
  local bad, berr = r:lookup("not.an.ip.address")
  ok(bad == nil, "lookup of a malformed IP returns nil")
  ok(berr == "bad ip", "lookup of a malformed IP reports 'bad ip'")

  r:close()
end

-- ===== error paths on open() ==========================================
local missing, merr = geoip.open(path .. ".does-not-exist")
ok(missing == nil and merr ~= nil, "open of a missing file returns nil + error")

-- A file with no metadata marker is rejected.
do
  local p2 = os.tmpname()
  local f = io.open(p2, "wb"); f:write("this is not an mmdb file at all"); f:close()
  local rr, rerr = geoip.open(p2)
  ok(rr == nil, "open of a non-mmdb file returns nil")
  ok(type(rerr) == "string" and rerr:find("marker", 1, true) ~= nil, "non-mmdb error mentions the missing marker")
  os.remove(p2)
end

os.remove(path)

if fails == 0 then print("[+] PASS test_geoip") os.exit(0) else os.exit(1) end
