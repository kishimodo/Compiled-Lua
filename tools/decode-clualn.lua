-- decode-clualn.lua -- read a CLua-produced PE and dump the .clualn
-- (native pc -> Lua source line) debug section, per function, for
-- post-mortem tooling.
--
-- Usage:  lua tools\decode-clualn.lua <path-to.exe>
--
-- The .clualn section is only present in binaries built with `clua build -g`
-- (or aotc `--debug`); a normal (release) build has no such section and this
-- script prints "no .clualn section" and exits 0.
--
-- On-disk layout (little-endian; a concatenation of per-function records):
--   uint32 name_len
--   char[] name              -- e.g. "luac_fn_3"
--   uint32 source_path_len
--   char[] source_path       -- absolute .lua path (leading '@' stripped)
--   uint32 nrows
--   { uint32 native_off; uint32 lua_line } [nrows]  -- monotone in native_off
--
-- Grouping semantics: coff_write.c emits one .clualn$M<i> input section per
-- function; pe_emit.c's classify_section splits on '$' and concatenates them
-- all into ONE output section named ".clualn". A decoder walks records back
-- to back until the section is consumed -- no per-function table of contents.
--
-- Read from disk, NOT from a mapped image: .clualn is marked
-- IMAGE_SCN_MEM_DISCARDABLE, so a running loader may drop the pages.

local function die(msg)
  io.stderr:write("decode-clualn: " .. msg .. "\n")
  os.exit(1)
end

local function u16(s, off)
  local a, b = string.byte(s, off + 1, off + 2)
  return a + b * 256
end

local function u32(s, off)
  local a, b, c, d = string.byte(s, off + 1, off + 4)
  return a + b * 256 + c * 65536 + d * 16777216
end

-- Locate .clualn in a PE file. Returns (bytes, meta) or (nil, reason).
local function read_clualn(path)
  local f, err = io.open(path, "rb")
  if not f then return nil, "cannot open '" .. path .. "': " .. tostring(err) end
  local blob = f:read("*a") or ""
  f:close()
  if #blob < 0x40 then return nil, "file too small to be a PE" end
  if blob:sub(1, 2) ~= "MZ" then return nil, "no MZ magic (not a PE)" end
  local pe_off = u32(blob, 0x3C)
  if pe_off <= 0 or pe_off + 24 > #blob then return nil, "bad e_lfanew" end
  if blob:sub(pe_off + 1, pe_off + 4) ~= "PE\0\0" then
    return nil, "no PE signature at e_lfanew"
  end
  local fh_off      = pe_off + 4                       -- IMAGE_FILE_HEADER
  local nsec        = u16(blob, fh_off + 2)
  local opt_hdr_sz  = u16(blob, fh_off + 16)
  local sechdr_off  = fh_off + 20 + opt_hdr_sz
  if sechdr_off + nsec * 40 > #blob then return nil, "section table truncated" end
  for i = 0, nsec - 1 do
    local sh    = sechdr_off + i * 40
    local name8 = blob:sub(sh + 1, sh + 8)
    -- trim trailing NULs
    local name  = name8:match("^(.-)%z") or name8
    if name == ".clualn" then
      -- Use VirtualSize (offset 8), NOT SizeOfRawData (offset 16). The PE
      -- FileAlignment pads the raw payload to a 512-byte multiple; reading
      -- past VirtualSize into that padding would produce a run of zeros
      -- the decoder treats as empty records until it hit truncation. Every
      -- real byte of the section lives in [0, vsize).
      local vsize   = u32(blob, sh + 8)
      local raw_off = u32(blob, sh + 20)
      if raw_off + vsize > #blob then return nil, ".clualn payload out of file" end
      local payload = blob:sub(raw_off + 1, raw_off + vsize)
      return payload, { section_size = vsize, section_off = raw_off, nsec = nsec }
    end
  end
  return nil, "no .clualn section"
end

-- Decode payload into a list of per-function records.
local function decode(payload)
  local out = {}
  local off = 0
  local n   = #payload
  while off < n do
    if off + 4 > n then error("truncated at name_len") end
    local nl = u32(payload, off); off = off + 4
    if off + nl > n then error("truncated in function name (nl=" .. nl .. ")") end
    local name = payload:sub(off + 1, off + nl); off = off + nl

    if off + 4 > n then error("truncated at source_len") end
    local sl = u32(payload, off); off = off + 4
    if off + sl > n then error("truncated in source path (sl=" .. sl .. ")") end
    local src = payload:sub(off + 1, off + sl); off = off + sl

    if off + 4 > n then error("truncated at nrows") end
    local nrows = u32(payload, off); off = off + 4
    if off + nrows * 8 > n then error("truncated in rows (nrows=" .. nrows .. ")") end
    local rows = {}
    for r = 1, nrows do
      local no = u32(payload, off); off = off + 4
      local ll = u32(payload, off); off = off + 4
      rows[r] = { native_off = no, lua_line = ll }
    end
    out[#out + 1] = { name = name, source = src, rows = rows }
  end
  return out
end

-- Public API for the test suite: reads and decodes; returns a records array,
-- or (nil, reason).
local function load_records(path)
  local payload, meta = read_clualn(path)
  if not payload then return nil, meta end
  local ok, records = pcall(decode, payload)
  if not ok then return nil, "decode failed: " .. tostring(records) end
  return records, meta
end

-- CLI mode.
local function main(argv)
  if #argv < 1 then die("usage: lua tools/decode-clualn.lua <PE-path>") end
  local path = argv[1]
  local records, meta = load_records(path)
  if not records then
    if meta == "no .clualn section" then
      print("no .clualn section (binary was not built with -g)")
      return 0
    end
    die(meta)
  end
  print(string.format("clualn payload: %d bytes at file offset 0x%X, %d functions",
                      meta.section_size, meta.section_off, #records))
  for _, rec in ipairs(records) do
    print(string.format("\nfunction %s  source=%s  rows=%d",
                        rec.name, rec.source, #rec.rows))
    for _, row in ipairs(rec.rows) do
      print(string.format("  native+0x%08x  ->  line %d", row.native_off, row.lua_line))
    end
  end
  return 0
end

-- Allow `require`-style consumption from the test.
if arg and arg[0] and arg[0]:match("decode%-clualn%.lua$") then
  os.exit(main(arg))
end

return {
  load_records = load_records,
  read_clualn  = read_clualn,
  decode       = decode,
}
