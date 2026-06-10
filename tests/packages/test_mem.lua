-- tests/packages/test_mem.lua : cross-process memory + AOB pattern scanning.
-- Determinism: we operate ONLY on memory we allocate inside THIS process, so
-- every byte and match is hand-known. compile_pattern() is a pure function we
-- verify against hand-computed bytes/masks. Addresses themselves are never
-- printed (they are non-deterministic); we assert relationships about them.
--
-- KNOWN BUG (MEM-FFINEW-001): the typed read/write helpers (read_int32,
-- write_uint32, ...) route through `ffi.new(ctype.."[1]", value)`, and this
-- build's FFI rejects an array ctype with an initializer ("cannot convert
-- integer to 5-kind type"). Those are XFAIL'd below so they stay visible.
local ok_req, mem = pcall(require, "mem")
if not ok_req then
    print("[~] SKIP test_mem (" .. tostring(mem) .. ")")
    os.exit(0)
end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_mem: " .. tostring(m)) end end
local function xfail(cond, desc, bug)
    if cond then print(("[!] XPASS test_mem: %s -- bug %s appears FIXED, remove this xfail"):format(desc, bug))
    else        print(("[x] XFAIL test_mem: %s (known bug %s)"):format(desc, bug)) end
end

-- ===== compile_pattern: pure, fully deterministic ==========================
local cp = mem.compile_pattern("DE AD BE EF")
ok(cp.len == 4,                                  "compile_pattern len == 4")
ok(cp.bytes[1] == 0xDE and cp.bytes[2] == 0xAD
   and cp.bytes[3] == 0xBE and cp.bytes[4] == 0xEF, "compile_pattern decodes hex bytes")
ok(cp.mask[1] and cp.mask[2] and cp.mask[3] and cp.mask[4], "all-concrete mask is all true")

-- contiguous hex (no spaces) is also accepted
local cp2 = mem.compile_pattern("DEADBEEF")
ok(cp2.len == 4 and cp2.bytes[1] == 0xDE and cp2.bytes[4] == 0xEF,
                                                 "contiguous hex compiles identically")

-- wildcards: "?", "??" and "*" each consume one byte slot with mask=false
local cp3 = mem.compile_pattern("48 ? 8B ?? 90 *")
ok(cp3.len == 6,                                 "wildcards: 6 slots")
ok(cp3.mask[1] == true and cp3.bytes[1] == 0x48, "slot1 concrete 0x48")
ok(cp3.mask[2] == false,                         "slot2 '?' is wildcard")
ok(cp3.mask[3] == true and cp3.bytes[3] == 0x8B, "slot3 concrete 0x8B")
ok(cp3.mask[4] == false,                         "slot4 '??' is wildcard")
ok(cp3.mask[5] == true and cp3.bytes[5] == 0x90, "slot5 concrete 0x90")
ok(cp3.mask[6] == false,                         "slot6 '*' is wildcard")

-- pattern caching returns the same compiled table for the same string
ok(mem.compile_pattern("AA BB") == mem.compile_pattern("AA BB"),
                                                 "compile_pattern caches by string")

-- error paths: empty + bad hex must raise
ok(select(1, pcall(mem.compile_pattern, "")) == false,   "empty pattern errors")
ok(select(1, pcall(mem.compile_pattern, "XY")) == false, "bad hex errors")
ok(select(1, pcall(mem.compile_pattern, "4")) == false,  "odd nibble errors")

-- ===== self() handle + alloc/raw read/write round-trips ====================
local proc = mem.self()
ok(type(proc) == "table",                        "self() returns a proc table")

local alloc_ok, base = pcall(function() return proc:alloc(4096) end)
ok(alloc_ok,                                     "self():alloc(4096) succeeds")
if alloc_ok then
    -- raw byte round-trip (covers embedded NUL + high bytes)
    local payload = "Hello\0World\xDE\xAD\xBE\xEF"
    proc:write(base, payload)
    local back = proc:read(base, #payload)
    ok(back == payload,                          "write/read raw bytes round-trip")
    ok(#back == #payload,                        "read returns requested length")

    -- ASCII C-string read stops at NUL
    proc:write(base, "abc\0def")
    ok(proc:read_string(base, 64) == "abc",      "read_string stops at NUL")

    -- read of zero bytes returns empty string (no throw)
    ok(proc:read(base, 0) == "",                 "read(addr,0) == ''")
    ok(proc:write(base, "") == 0,                "write(addr,'') == 0")

    -- query() the region we allocated; must be committed (MEM_COMMIT = 0x1000)
    local q = proc:query(base)
    ok(type(q) == "table",                       "query() returns a table")
    ok(q.state == 0x1000,                        "allocated region is MEM_COMMIT")
    ok(q.region_size >= 4096,                    "region_size >= page")

    -- ===== AOB scan over a region we control ==============================
    local needle = "\x13\x37\xC0\xDE\xCA\xFE"
    proc:write(base + 100, needle)
    local pattern = "13 37 C0 DE CA FE"
    local matches = mem.scan(proc, pattern,
        { start = base, stop = base + 4096, readable_only = false })
    ok(type(matches) == "table",                 "scan() returns a table")
    local found = false
    for _, addr in ipairs(matches) do
        if addr == base + 100 then found = true end
    end
    ok(found,                                    "scan finds planted needle at base+100")

    -- find() returns the first match address
    local first = mem.find(proc, pattern,
        { start = base, stop = base + 4096, readable_only = false })
    ok(first == base + 100,                       "find() returns the planted address")

    -- wildcard scan: middle bytes wildcarded still matches the needle
    local wmatches = mem.scan(proc, "13 37 ?? ?? CA FE",
        { start = base, stop = base + 4096, readable_only = false })
    local wfound = false
    for _, addr in ipairs(wmatches) do
        if addr == base + 100 then wfound = true end
    end
    ok(wfound,                                    "wildcard scan matches planted needle")

    -- a needle that isn't present yields no match
    local none = mem.find(proc, "99 98 97 96 95 94 93 92",
        { start = base, stop = base + 4096, readable_only = false })
    ok(none == nil,                               "absent pattern yields nil")

    -- find_all aliases scan
    ok(mem.find_all == mem.scan,                  "find_all aliases scan")

    -- ===== typed READS work (read_typed uses ffi.new(T.."[1]") w/o init) ===
    -- Plant little-endian bytes by hand, then assert the typed readers decode
    -- them correctly. These hand-known bytes make the expected values fixed.
    proc:write(base, "\x44\x33\x22\x11")  -- LE 0x11223344
    ok(proc:read_uint32(base) == 0x11223344, "read_uint32 decodes planted LE bytes")
    proc:write(base, "\xFF\xFF\xFF\xFF")
    ok(proc:read_uint32(base) == 0xFFFFFFFF, "read_uint32 of all-ones == 0xFFFFFFFF")
    ok(proc:read_int32(base) == -1,          "read_int32 of all-ones == -1")
    proc:write(base, "\xAB")
    ok(proc:read_uint8(base) == 0xAB,        "read_uint8 decodes planted byte")
    proc:write(base, "\xEF\xBE")             -- LE 0xBEEF
    ok(proc:read_uint16(base) == 0xBEEF,     "read_uint16 decodes planted LE bytes")
    -- float 1.5 = 0x3FC00000 LE bytes 00 00 C0 3F
    proc:write(base, "\x00\x00\xC0\x3F")
    ok(proc:read_float(base) == 1.5,         "read_float decodes planted IEEE-754 1.5")
    -- double 2.25 = 0x4002000000000000 LE
    proc:write(base, "\x00\x00\x00\x00\x00\x00\x02\x40")
    ok(proc:read_double(base) == 2.25,       "read_double decodes planted IEEE-754 2.25")

    -- ===== typed WRITES (regression: MEM-FFINEW-001 fixed) ================
    -- write_typed() does `ffi.new(ctype.."[1]", value)` (array ctype WITH an
    -- initializer); this build's FFI now accepts it.
    local tw_ok = pcall(function() proc:write_uint32(base, 0x11223344) end)
    ok(tw_ok, "write_uint32 (ffi.new array-init)")
    local tw8_ok = pcall(function() proc:write_uint8(base, 0xCD) end)
    ok(tw8_ok, "write_uint8 (ffi.new array-init)")

    proc:free(base)
end

-- ===== self_read / self_write module-level shortcuts (raw path, works) =====
local sb_ok, sbase = pcall(function() return mem.self():alloc(64) end)
if sb_ok then
    mem.self_write(sbase, "\x42\x43\x44")
    ok(mem.self_read(sbase, 3) == "\x42\x43\x44", "self_read/self_write round-trip")
    mem.self():free(sbase)
end

-- modules(): shape only (Toolhelp may be denied -> empty list is acceptable)
local mods = proc:modules()
ok(type(mods) == "table",                        "modules() returns a table")
local mods_ok = true
for _, mo in ipairs(mods) do
    if type(mo.name) ~= "string" then mods_ok = false end
    if type(mo.base) ~= "number" then mods_ok = false end
    if type(mo.size) ~= "number" or mo.size <= 0 then mods_ok = false end
end
ok(mods_ok,                                      "module records have name/base/size")

if fails == 0 then print("[+] PASS test_mem") os.exit(0) else os.exit(1) end
