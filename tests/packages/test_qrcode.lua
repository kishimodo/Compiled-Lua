local ok_req, qrcode = pcall(require, "qrcode")
if not ok_req then print("[~] SKIP test_qrcode") os.exit(0) end

local fails = 0
local function ok(c, m)
  if not c then fails = fails + 1; print("[-] FAIL test_qrcode: " .. tostring(m)) end
end

-- ===== Version / size geometry (ISO/IEC 18004) =====
-- Module count for version V is (V-1)*4 + 21: V1=21, V7=45, V40=177.
local m1 = qrcode.generate("HELLO", { ecc = "M", mask = 0 })
ok(m1.size == 21, "short HELLO should be V1 size 21, got " .. tostring(m1.size))
ok(m1.version == 1, "HELLO should fit V1, got version " .. tostring(m1.version))
ok(#m1.modules == m1.size, "modules row count == size")
ok(#m1.modules[1] == m1.size, "modules col count == size")
ok(m1.ecc == "M", "ecc echoed in matrix")
ok(m1.mask == 0, "forced mask echoed in matrix")
ok(m1.mode == "alphanumeric", "HELLO is alphanumeric mode, got " .. tostring(m1.mode))

-- ===== Modules are strict booleans (true = dark / 1, false = light / 0) =====
local allbool = true
for r = 1, m1.size do
  for c = 1, m1.size do
    local v = m1.modules[r][c]
    if v ~= true and v ~= false then allbool = false end
  end
end
ok(allbool, "every module is a strict boolean (bit 0/1)")

-- ===== Finder pattern structure (top-left 7x7) =====
-- A QR finder is a 7x7 block: solid dark outer ring, light ring inside,
-- 3x3 dark center. This is fixed by the spec, independent of payload.
local finder_ok = true
for c = 1, 7 do if m1.modules[1][c] ~= true then finder_ok = false end end -- top edge dark
for c = 1, 7 do if m1.modules[7][c] ~= true then finder_ok = false end end -- bottom edge dark
for r = 1, 7 do if m1.modules[r][1] ~= true then finder_ok = false end end -- left edge dark
for r = 1, 7 do if m1.modules[r][7] ~= true then finder_ok = false end end -- right edge dark
for c = 2, 6 do if m1.modules[2][c] ~= false then finder_ok = false end end -- inner light ring
for r = 3, 5 do for c = 3, 5 do if m1.modules[r][c] ~= true then finder_ok = false end end end -- 3x3 center
ok(finder_ok, "top-left finder pattern is well-formed")

-- Separators (1-module light gap beside the finder) must be light.
ok(m1.modules[8][1] == false, "separator at row8,col1 is light")
ok(m1.modules[1][8] == false, "separator at row1,col8 is light")

-- ===== Timing patterns alternate dark/light =====
-- Horizontal timing band sits on module-row 7 (1-based); vertical on col 7.
ok(m1.modules[7][9] ~= m1.modules[7][10], "horizontal timing alternates")
ok(m1.modules[9][7] ~= m1.modules[10][7], "vertical timing alternates")

-- ===== Capacity helpers vs independently computed spec values =====
-- V1-M holds 16 data codewords = 128 bits.
-- numeric:      floor(128/10)*3 = 12*3 = 36 digits.
ok(qrcode.numeric_capacity(1, "M") == 36,
   "V1-M numeric capacity should be 36, got " .. tostring(qrcode.numeric_capacity(1, "M")))
-- alphanumeric: floor(128/11)*2 = 11*2 = 22 chars.
ok(qrcode.alphanumeric_capacity(1, "M") == 22,
   "V1-M alphanumeric capacity should be 22, got " .. tostring(qrcode.alphanumeric_capacity(1, "M")))
-- byte (documented as data_codewords - 1): V1-L = 19 -> 18.
ok(qrcode.byte_capacity(1, "L") == 18,
   "V1-L byte capacity should be 18, got " .. tostring(qrcode.byte_capacity(1, "L")))

-- ECC level strictly trades capacity: V1 data codewords L=19 > M=16 > Q=13 > H=9.
ok(qrcode.byte_capacity(1, "L") > qrcode.byte_capacity(1, "M"), "L holds more than M")
ok(qrcode.byte_capacity(1, "M") > qrcode.byte_capacity(1, "Q"), "M holds more than Q")
ok(qrcode.byte_capacity(1, "Q") > qrcode.byte_capacity(1, "H"), "Q holds more than H")

-- ===== Auto-version selection grows with data length =====
local short = qrcode.generate("1", { ecc = "M" })
local long  = qrcode.generate(string.rep("A", 100), { ecc = "M" })
ok(short.version <= long.version, "longer data must need >= version")
ok(long.version > 1, "100 'A' chars must exceed V1, got version " .. tostring(long.version))
ok(long.size == (long.version - 1) * 4 + 21, "long matrix size matches its version")

-- ===== Mode auto-detection =====
ok(qrcode.generate("12345", { ecc = "M" }).mode == "numeric", "all digits -> numeric")
ok(qrcode.generate("ABC123", { ecc = "M" }).mode == "alphanumeric", "uppercase + digits -> alphanumeric")
ok(qrcode.generate("hello", { ecc = "M" }).mode == "byte", "lowercase -> byte")

-- ===== Forced version >= 7 exercises the version-info path =====
local m7 = qrcode.generate("DATA", { ecc = "L", version = 7, mask = 0 })
ok(m7.size == 45, "V7 size should be 45, got " .. tostring(m7.size))
ok(m7.version == 7, "forced version 7 echoed")
-- V7 also carries three finders; verify the bottom-left one's outer ring.
local fok7 = true
for c = 1, 7 do if m7.modules[m7.size][c] ~= true then fok7 = false end end
ok(fok7, "V7 bottom-left finder bottom edge is dark")

-- ===== Determinism: same input + same forced mask -> identical matrix =====
local a = qrcode.generate("HELLO WORLD", { ecc = "Q", mask = 3 })
local b = qrcode.generate("HELLO WORLD", { ecc = "Q", mask = 3 })
local same = (a.size == b.size and a.version == b.version and a.mask == b.mask)
if same then
  for r = 1, a.size do
    for c = 1, a.size do
      if a.modules[r][c] ~= b.modules[r][c] then same = false end
    end
  end
end
ok(same, "generation is deterministic for fixed input + mask")

-- ===== SVG renderer basics =====
local svg = qrcode.to_svg(m1, { scale = 4, padding = 2 })
ok(type(svg) == "string", "to_svg returns a string")
ok(svg:match("^<svg") ~= nil, "svg starts with <svg")
ok(svg:match("</svg>$") ~= nil, "svg ends with </svg>")
-- canvas dimension = (size + 2*padding) * scale = (21 + 4) * 4 = 100.
ok(svg:find('width="100"', 1, true) ~= nil, "svg width = 100 for size21 + pad2 * scale4")

if fails == 0 then print("[+] PASS test_qrcode") os.exit(0) else os.exit(1) end
