-- tests/packages/test_mmap.lua : memory-mapped files (read / rw / cow) + anonymous.
-- Deterministic: writes a known file, maps it, asserts exact bytes back.
local ok_req, mmap = pcall(require, "mmap")
if not ok_req then print("[~] SKIP test_mmap (" .. tostring(mmap) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_mmap: " .. tostring(m)) end end

-- Build a deterministic temp path (no random/time; fixed name, cleaned at end).
local tmpdir = os.getenv("TEMP") or os.getenv("TMP") or "."
local sep = tmpdir:find("\\") and "\\" or "/"
local fpath = tmpdir .. sep .. "luavm_mmap_test_fixed.bin"
local CONTENT = "Hello, mmap world! 0123456789"   -- 29 bytes

-- Write the fixture file.
local fh = assert(io.open(fpath, "wb"))
fh:write(CONTENT)
fh:close()

-- ===== read-only map =====
local m, err = mmap.open(fpath, "r")
ok(m ~= nil, "open(r) succeeds: " .. tostring(err))
if m then
    ok(m:size() == #CONTENT, "size() equals file length")
    ok(m:read(0, 5) == "Hello", "read(0,5) returns leading bytes")
    ok(m:read(7, 4) == "mmap", "read(off,len) reads an interior slice")
    ok(m:as_string() == CONTENT, "as_string() returns whole file")
    ok(m:bytes() == CONTENT, "bytes() (no args) returns whole view")
    ok(m:bytes(7, 4) == "mmap", "bytes(off,len) slices like read")
    -- out-of-bounds read returns nil + err (no throw).
    local oob, oe = m:read(0, #CONTENT + 1)
    ok(oob == nil and type(oe) == "string", "read past end returns nil + err")
    local noff = m:read(-1, 1)
    ok(noff == nil, "negative offset rejected")
    -- write must be refused on a read-only map.
    local wok, werr = m:write(0, "X")
    ok(wok == nil and type(werr) == "string", "write rejected on read-only map")
    -- slice returns a cdata pointer; first byte equals 'H'.
    local sl = m:slice(0, 5)
    ok(sl ~= nil and string.char(sl[0]) == "H", "slice() points at view start")
    -- ptr() returns a usable pointer.
    ok(m:ptr() ~= nil, "ptr() returns a pointer")
    ok(m:close() == true, "close() returns true")
    -- operations after close are rejected.
    ok(select(1, m:read(0, 1)) == nil, "read after close returns nil")
end

-- ===== read-write map: write then re-open to confirm persistence =====
local rw, rwerr = mmap.open(fpath, "rw")
ok(rw ~= nil, "open(rw) succeeds: " .. tostring(rwerr))
if rw then
    ok(select(1, rw:write(0, "J")) == true, "write(0,'J') succeeds on rw map")
    ok(rw:read(0, 5) == "Jello", "rw map reflects the write immediately")
    ok(select(1, rw:flush()) == true, "flush() succeeds")
    rw:close()
    -- Re-open read-only: the byte persisted to the backing file.
    local v = mmap.open(fpath, "r")
    ok(v and v:read(0, 5) == "Jello", "rw write persisted to backing file")
    if v then v:close() end
end

-- ===== copy-on-write: changes do NOT hit the backing file =====
-- restore original content first
local fh2 = assert(io.open(fpath, "wb")); fh2:write(CONTENT); fh2:close()
local cow, cowerr = mmap.open(fpath, "copy_on_write")
ok(cow ~= nil, "open(copy_on_write) succeeds: " .. tostring(cowerr))
if cow then
    ok(select(1, cow:write(0, "Z")) == true, "cow write succeeds in private copy")
    ok(cow:read(0, 5) == "Zello", "cow private view sees its own change")
    cow:close()
    local v2 = mmap.open(fpath, "r")
    ok(v2 and v2:read(0, 5) == "Hello", "cow change did NOT persist to backing file")
    if v2 then v2:close() end
end

-- ===== error paths =====
ok(select(1, mmap.open(fpath, "bogus")) == nil, "unknown mode returns nil + err")
ok(select(1, mmap.open(tmpdir .. sep .. "luavm_definitely_missing_file_zzz.bin", "r")) == nil,
   "opening a missing file returns nil + err")

-- ===== anonymous mapping (pagefile-backed) =====
local an, anerr = mmap.anonymous(4096)
ok(an ~= nil, "anonymous(4096) succeeds: " .. tostring(anerr))
if an then
    ok(an:size() == 4096, "anonymous size is what we asked for")
    ok(select(1, an:write(10, "abc")) == true, "anonymous map is writable")
    ok(an:read(10, 3) == "abc", "anonymous map round-trips a write")
    an:close()
end
ok(select(1, mmap.anonymous(0)) == nil, "anonymous(0) rejected")

-- cleanup
os.remove(fpath)

if fails == 0 then print("[+] PASS test_mmap") os.exit(0) else os.exit(1) end
