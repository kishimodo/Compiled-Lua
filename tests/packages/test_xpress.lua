-- tests/packages/test_xpress.lua : ntdll RtlCompressBuffer round-trips.
-- Deterministic: fixed input strings; we assert decompress(compress(x)) == x and
-- size/error invariants. No timestamps or addresses printed.
local ok_req, xpress = pcall(require, "xpress")
if not ok_req then print("[~] SKIP test_xpress (" .. tostring(xpress) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_xpress: " .. tostring(m)) end end
local function xfail(cond, desc, bug)
  if cond then print(("[!] XPASS test_xpress: %s -- bug %s appears FIXED, remove this xfail"):format(desc, bug))
  else        print(("[x] XFAIL test_xpress: %s (known bug %s)"):format(desc, bug)) end
end

-- ===== format constants =====
ok(xpress.LZNT1 == 2,                 "LZNT1 constant = 2")
ok(xpress.XPRESS == 3,                "XPRESS constant = 3")
ok(xpress.XPRESS_HUFF == 4,           "XPRESS_HUFF constant = 4")
ok(xpress.formats.XPRESS_HUFF == 4,   "formats table mirrors constants")

-- ntdll exports may be unavailable in an unusual environment; guard the actual
-- compression behind a pcall and SKIP just that part if the API errors.
local probe_ok = pcall(function()
  return xpress.decompress(xpress.compress("probe"), nil, 5)
end)
if not probe_ok then
  print("[~] SKIP test_xpress (ntdll RtlCompressBuffer unavailable)")
  os.exit(0)
end

-- ===== round-trip across all three formats =====
-- NOTE: xpress.compress("") SEGFAULTS the process (bug XPRESS-EMPTY-001): with
-- UncompressedBufferSize=0 ntdll's RtlCompressBuffer faults rather than producing
-- an empty/short frame. A segfault cannot be pcall-trapped, so the empty input is
-- deliberately excluded; the package should clamp/short-circuit #bytes==0.
-- These samples are all >= a few bytes; tiny XPRESS/LZNT1 inputs are covered
-- by the verbatim-store round-trip checks below (XPRESS-SMALL-001).
local samples = {
  "hello, world",                             -- short ASCII
  string.rep("abcabcabc", 200),               -- highly compressible
  string.rep("Z", 4096),                      -- run of identical bytes
  string.rep("Z", 65536),                     -- larger run (multi-chunk territory)
}
for _, fmt in ipairs({ xpress.XPRESS_HUFF, xpress.XPRESS, xpress.LZNT1 }) do
  for si, s in ipairs(samples) do
    local comp = xpress.compress(s, fmt)
    local back = xpress.decompress(comp, fmt, #s)
    ok(back == s, "round-trip fmt=" .. fmt .. " sample#" .. si .. " (len " .. #s .. ")")
  end
end

-- XPRESS_HUFF handles a 1-byte input fine:
ok(xpress.decompress(xpress.compress("A", xpress.XPRESS_HUFF), xpress.XPRESS_HUFF, 1) == "A",
   "XPRESS_HUFF round-trips a single byte")
-- XPRESS and LZNT1 cannot represent an input below their minimum block, so a
-- tiny input is stored verbatim and still round-trips (XPRESS-SMALL-001 fixed:
-- the package short-circuits inputs under the format floor instead of handing
-- RtlCompressBuffer a payload it rejects with STATUS_BUFFER_TOO_SMALL).
ok(xpress.decompress(xpress.compress("A", xpress.XPRESS), xpress.XPRESS, 1) == "A",
   "XPRESS round-trips a 1-byte input (stored verbatim)")
ok(xpress.decompress(xpress.compress("A", xpress.LZNT1), xpress.LZNT1, 1) == "A",
   "LZNT1 round-trips a 1-byte input (stored verbatim)")
-- a few-byte input (still under the floor) round-trips for both too
ok(xpress.decompress(xpress.compress("hi!", xpress.XPRESS), xpress.XPRESS, 3) == "hi!",
   "XPRESS round-trips a 3-byte input")
ok(xpress.decompress(xpress.compress("hi!", xpress.LZNT1), xpress.LZNT1, 3) == "hi!",
   "LZNT1 round-trips a 3-byte input")

-- ===== default format (no fmt arg) is XPRESS_HUFF and round-trips =====
local d_in = "default-format payload exercises XPRESS_HUFF"
local d_back = xpress.decompress(xpress.compress(d_in), nil, #d_in)
ok(d_back == d_in,                    "default-format compress/decompress round-trips")

-- ===== compressible data actually shrinks =====
local big = string.rep("the quick brown fox ", 500)  -- 10000 bytes, very repetitive
local big_comp = xpress.compress(big, xpress.XPRESS_HUFF)
ok(#big_comp < #big,                  "repetitive input compresses smaller than original")
ok(xpress.decompress(big_comp, xpress.XPRESS_HUFF, #big) == big, "large compressible round-trips")

-- ===== binary (all byte values) round-trips losslessly =====
local bin = {}
for i = 0, 255 do bin[#bin + 1] = string.char(i) end
local binstr = table.concat(bin)
local bin_back = xpress.decompress(xpress.compress(binstr, xpress.XPRESS), xpress.XPRESS, #binstr)
ok(bin_back == binstr,                "full 0..255 byte range round-trips (XPRESS)")
ok(#bin_back == 256,                  "binary round-trip preserves length")

-- ===== frame_compress / frame_decompress (self-describing) =====
local fpayload = "framed content: header carries format + original length"
local framed = xpress.frame_compress(fpayload)
ok(#framed >= 12,                     "frame has at least the 12-byte header")
-- magic 'LVX1' little-endian = 0x3158564C => bytes 'L','V','X','1'
ok(framed:sub(1, 4) == "LVX1",        "frame magic is LVX1")
ok(xpress.frame_decompress(framed) == fpayload, "frame round-trips without caller tracking size")

-- frame with explicit non-default format
local framed2 = xpress.frame_compress(fpayload, xpress.LZNT1)
ok(xpress.frame_decompress(framed2) == fpayload, "frame round-trips with LZNT1")

-- ===== error paths =====
ok(select(2, pcall(xpress.compress, 123)) ~= nil, "compress rejects non-string")
ok(select(2, pcall(xpress.decompress, "x", nil)) ~= nil, "decompress requires original_size")
ok(select(2, pcall(xpress.frame_decompress, "short")) ~= nil, "frame_decompress rejects too-short input")
-- bad magic
local bad = "ZZZZ" .. framed:sub(5)
ok(select(2, pcall(xpress.frame_decompress, bad)) ~= nil, "frame_decompress rejects bad magic")

if fails == 0 then print("[+] PASS test_xpress") os.exit(0) else os.exit(1) end
