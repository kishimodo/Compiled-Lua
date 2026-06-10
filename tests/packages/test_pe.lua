-- tests/packages/test_pe.lua : pure-Lua PE parser, fed a hand-built PE32+ image.
-- pe has no external deps; this test is fully self-contained and deterministic.
-- Runner compiles under JIT and -i and byte-compares stdout.
local ok_req, pe = pcall(require, "pe")
if not ok_req then print("[~] SKIP test_pe (" .. tostring(pe) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_pe: " .. tostring(m)) end end

-- ===== Little-endian byte packers ========================================
local function u16(v) return string.char(v % 256, math.floor(v / 256) % 256) end
local function u32(v)
    v = math.floor(v)
    return string.char(v % 256, math.floor(v / 256) % 256,
                       math.floor(v / 65536) % 256, math.floor(v / 16777216) % 256)
end

-- ===== Hand-build a minimal valid PE32+ (64-bit) image ===================
-- All field values below are hand-chosen so we can assert them on parse.
local E_LFANEW   = 0x80
local MACHINE    = 0x8664      -- AMD64
local TIMESTAMP  = 0x11223344
local ENTRY      = 0x1000
local IMAGE_BASE = 0x40000000
local SUBSYSTEM  = 3           -- CONSOLE
local SIZE_IMAGE = 0x4000
local SIZE_HDRS  = 0x200
local SEC_VADDR  = 0x1000
local SEC_RADDR  = 0x200
local SEC_RSIZE  = 0x200
local SEC_VSIZE  = 0x200

-- DOS header: "MZ", e_lfanew at 0x3C, padded out to e_lfanew.
local dos = "MZ" .. string.rep("\0", 0x3C - 2) .. u32(E_LFANEW)
dos = dos .. string.rep("\0", E_LFANEW - #dos)

-- COFF FILE_HEADER (20 bytes). optional_size = 112 fixed + 16 data dirs * 8.
local OPT_SIZE = 112 + 16 * 8
local file_hdr = u16(MACHINE) .. u16(1) .. u32(TIMESTAMP) .. u32(0) .. u32(0)
              .. u16(OPT_SIZE) .. u16(0x0022)

-- OPTIONAL_HEADER (PE32+, magic 0x020B). 112-byte fixed part.
local opt = {}
opt[#opt+1] = u16(0x020B)                  -- +0  magic
opt[#opt+1] = string.char(14)              -- +2  major linker
opt[#opt+1] = string.char(0)               -- +3  minor linker
opt[#opt+1] = u32(0x200)                   -- +4  size_of_code
opt[#opt+1] = u32(0x400)                   -- +8  size_of_initialized_data
opt[#opt+1] = u32(0)                       -- +12 size_of_uninitialized_data
opt[#opt+1] = u32(ENTRY)                   -- +16 entry_point
opt[#opt+1] = u32(0x1000)                  -- +20 base_of_code
opt[#opt+1] = u32(IMAGE_BASE) .. u32(0)    -- +24 image_base (u64, PE32+)
opt[#opt+1] = u32(0x1000)                  -- +32 section_alignment
opt[#opt+1] = u32(0x200)                   -- +36 file_alignment
opt[#opt+1] = u16(6) .. u16(0)             -- +40 major/minor os version
opt[#opt+1] = u16(0) .. u16(0)             -- +44 major/minor image version
opt[#opt+1] = u16(6) .. u16(0)             -- +48 major/minor subsystem version
opt[#opt+1] = u32(0)                       -- +52 win32 version value
opt[#opt+1] = u32(SIZE_IMAGE)              -- +56 size_of_image
opt[#opt+1] = u32(SIZE_HDRS)               -- +60 size_of_headers
opt[#opt+1] = u32(0)                       -- +64 checksum
opt[#opt+1] = u16(SUBSYSTEM)               -- +68 subsystem
opt[#opt+1] = u16(0x8160)                  -- +70 dll_characteristics
opt[#opt+1] = u32(0x100000) .. u32(0)      -- +72 stack reserve (8)
opt[#opt+1] = u32(0x1000)   .. u32(0)      -- +80 stack commit  (8)
opt[#opt+1] = u32(0x100000) .. u32(0)      -- +88 heap reserve  (8)
opt[#opt+1] = u32(0x1000)   .. u32(0)      -- +96 heap commit   (8)
opt[#opt+1] = u32(0)                       -- +104 loader flags
opt[#opt+1] = u32(16)                      -- +108 number_of_rva_and_sizes
local opt_fixed = table.concat(opt)
ok(#opt_fixed == 112, "optional header fixed part is 112 bytes")
local optional = opt_fixed .. string.rep("\0", 16 * 8)   -- 16 empty data dirs

-- One section header (40 bytes), name ".text".
local secname = ".text" .. string.rep("\0", 8 - 5)
local sec = secname
         .. u32(SEC_VSIZE) .. u32(SEC_VADDR) .. u32(SEC_RSIZE) .. u32(SEC_RADDR)
         .. u32(0) .. u32(0) .. u16(0) .. u16(0) .. u32(0x60000020)
ok(#sec == 40, "section header is 40 bytes")

local image = dos .. "PE\0\0" .. file_hdr .. optional .. sec
image = image .. string.rep("\0", math.max(0, SIZE_HDRS - #image))

-- ===== Parse and verify ==================================================
local obj = pe.parse(image)
local h = obj:headers()
ok(h.machine == "AMD64", "machine name AMD64")
ok(h.bits == 64,         "64-bit image")
ok(h.magic == 0x020B,    "optional magic 0x020B")
ok(h.file.n_sections == 1,        "one section")
ok(h.file.timestamp == TIMESTAMP, "timestamp field parsed")
ok(h.optional.entry_point == ENTRY,       "entry_point parsed")
ok(h.optional.image_base == IMAGE_BASE,    "image_base parsed (u64)")
ok(h.optional.subsystem == SUBSYSTEM,      "subsystem parsed")
ok(h.optional.size_of_image == SIZE_IMAGE, "size_of_image parsed")
ok(h.optional.size_of_headers == SIZE_HDRS,"size_of_headers parsed")

-- :header alias points at :headers
ok(obj:header().machine == "AMD64", ":header alias works")

-- sections
local s = obj:sections()
ok(#s == 1, "sections() returns one entry")
ok(s[1].name == ".text",     "section name .text")
ok(s[1].vaddr == SEC_VADDR,  "section vaddr")
ok(s[1].vsize == SEC_VSIZE,  "section vsize")
ok(s[1].raddr == SEC_RADDR,  "section raddr")
ok(s[1].rsize == SEC_RSIZE,  "section rsize")
ok(s[1].chars == 0x60000020, "section characteristics")

-- rva_to_offset: RVA 0x1000 maps to raw offset 0x200 (=512).
ok(obj:rva_to_offset(SEC_VADDR) == SEC_RADDR, "rva_to_offset maps section start")
ok(obj:rva_to_offset(SEC_VADDR + 0x10) == SEC_RADDR + 0x10, "rva_to_offset honours intra-section delta")
ok(obj:rva_to_offset(0) == nil, "rva_to_offset(0) is nil")
ok(obj:rva_to_offset(0xFFFFFF) == nil, "rva_to_offset of unmapped RVA is nil")

-- read_rva: returns bytes from the mapped offset.
ok(obj:read_rva(SEC_VADDR, 0) == "", "read_rva n=0 returns empty string")

-- Empty data directories -> empty parse results (deterministic).
ok(#obj:imports() == 0,          "no imports")
ok(#obj:exports().entries == 0,  "no exports")
ok(#obj:resources() == 0,        "no resources")
ok(#obj:relocations() == 0,      "no relocations")
ok(#obj:debug_directory() == 0,  "no debug directory")
ok(#obj:certificates() == 0,     "no certificates")
ok(#obj:tls_callbacks() == 0,    "no TLS callbacks")
ok(#obj:exception_data() == 0,   "no exception data")

-- dump_headers: deterministic text snapshot of key facts.
local dh = obj:dump_headers()
ok(dh:find("machine AMD64", 1, true) ~= nil, "dump_headers names AMD64")
ok(dh:find(".text", 1, true) ~= nil,          "dump_headers lists .text section")

-- ===== Error paths =======================================================
ok(not pcall(function() pe.parse("not an mz file padded out for size............") end),
   "parse() rejects non-MZ buffer")
ok(not pcall(function() pe.parse("MZ") end), "parse() rejects too-small buffer")
ok(not pcall(function() pe.parse(12345) end), "parse() rejects non-string input")

if fails == 0 then print("[+] PASS test_pe") os.exit(0) else os.exit(1) end
