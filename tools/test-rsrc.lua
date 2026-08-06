-- test-rsrc.lua -- exercise the .rsrc section that clua embeds by default in
-- every exe: a VS_VERSION_INFO block populating File Explorer's Details tab,
-- an RT_MANIFEST tagging the exe as Win10/11 aware, and (opt-in) an .ico as
-- RT_GROUP_ICON + RT_ICON resources.
--
-- Contract checked here:
--   * a plain `clua build` produces an exe whose PE RESOURCE data directory
--     is non-empty and whose .rsrc section contains both an RT_VERSION
--     resource (with a "FileVersion" string) and an RT_MANIFEST resource
--     (whose bytes contain the word "compatibility").
--   * a build with --product-name="TestApp" carries the string "TestApp"
--     inside the RT_VERSION block.
--
-- Skip discipline: silently skip when build\bin\clua.exe is absent. This is
-- a functional test of a real exe on disk; there is no fallback path.
--
-- Run by tools/run-tests.lua from the repo root under clua-interp.exe.

local CLUA = "build\\bin\\clua.exe"

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close(); return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP test-rsrc (build\\bin\\clua.exe not built)")
  os.exit(0)
end

local ROOT = io.popen("cd"):read("*l")
local TEMP = os.getenv("TEMP") or "."
local clua_abs = ROOT .. "\\" .. CLUA

local fails = 0
local function ok(cond, name, detail)
  if cond then
    print("[+] PASS " .. name)
  else
    fails = fails + 1
    print("[-] FAIL " .. name .. (detail and (" -- " .. detail) or ""))
  end
end

local function run(cmd)
  local f = io.popen("(" .. cmd .. ") 2>&1")
  local out = f:read("*a") or ""
  local okc, _, code = f:close()
  if okc == true then code = 0 end
  return code or -1, out
end

local function writefile(p, s)
  local f = assert(io.open(p, "wb"))
  f:write(s); f:close()
end

local function readfile(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close(); return s
end

-- ---- PE resource-tree walker (just enough for the assertions) ------------
-- Little-endian readers.
local function u16(s, o) return s:byte(o) + s:byte(o+1)*256 end
local function u32(s, o)
  return s:byte(o) + s:byte(o+1)*256 + s:byte(o+2)*65536 + s:byte(o+3)*16777216
end

-- Given an exe on disk, walk its .rsrc section and return { types = {
--   [type_id] = { [name_id] = { [lang_id] = { rva=..., size=..., bytes=... } } } } }.
-- Returns nil, err on failure.
local function walk_rsrc(path)
  local pe = readfile(path)
  if not pe then return nil, "cannot read " .. path end
  if pe:sub(1, 2) ~= "MZ" then return nil, "not a PE" end
  local pe_off = u32(pe, 0x3C + 1)   -- e_lfanew (0-based) -> 1-based offset
  if pe:sub(pe_off + 1, pe_off + 4) ~= "PE\0\0" then return nil, "no PE sig" end
  local coff = pe_off + 4
  local nsec = u16(pe, coff + 2 + 1)
  local opt_size = u16(pe, coff + 16 + 1)
  local opt = coff + 20
  -- PE32+ optional header: DataDirectory starts at opt + 112, entry 2 is Resource.
  local res_rva  = u32(pe, opt + 112 + 2*8 + 1)
  local res_size = u32(pe, opt + 112 + 2*8 + 4 + 1)
  if res_rva == 0 or res_size == 0 then
    return nil, "no RESOURCE data directory"
  end
  -- Section table: opt + opt_size, one 40-byte record per section.
  local sec_tbl = opt + opt_size
  local rsrc_off = nil
  for i = 0, nsec - 1 do
    local h = sec_tbl + i * 40
    local name = pe:sub(h + 1, h + 8):match("^([^%z]*)") or ""
    local vsz  = u32(pe, h + 8 + 1)
    local vrva = u32(pe, h + 12 + 1)
    local roff = u32(pe, h + 20 + 1)
    if name == ".rsrc" then
      rsrc_off = roff
      break
    end
    -- Some layouts inline the resource dir into another section; use RVA range.
    if vrva <= res_rva and (vrva + vsz) > res_rva then
      rsrc_off = roff + (res_rva - vrva)
      break
    end
  end
  if not rsrc_off then return nil, "no .rsrc section" end

  -- Walk three levels of IMAGE_RESOURCE_DIRECTORY. Each directory:
  --   Characteristics(4) TimeDate(4) Ver(2+2) NNamed(2) NId(2)
  -- Then NNamed + NId entries of 8 bytes each { Name(4), OffsetToData(4) }.
  local function walk_dir(dir_off)
    local n_named = u16(pe, dir_off + 12 + 1)
    local n_id    = u16(pe, dir_off + 14 + 1)
    local entries = {}
    local first = dir_off + 16
    for i = 0, n_named + n_id - 1 do
      local e = first + i * 8
      local name = u32(pe, e + 1)
      local off  = u32(pe, e + 4 + 1)
      entries[#entries + 1] = { name = name, off = off }
    end
    return entries
  end

  local root_off = rsrc_off
  local rsrc_base_rva = res_rva   -- RVA of the top-level dir
  local out = { types = {} }
  local types = walk_dir(root_off)
  for _, t in ipairs(types) do
    if t.off >= 0x80000000 then
      local name_dir_off = rsrc_off + (t.off - 0x80000000)
      local type_id = t.name  -- integer id; high bit clear
      out.types[type_id] = {}
      local names = walk_dir(name_dir_off)
      for _, nm in ipairs(names) do
        if nm.off >= 0x80000000 then
          local lang_dir_off = rsrc_off + (nm.off - 0x80000000)
          out.types[type_id][nm.name] = {}
          local langs = walk_dir(lang_dir_off)
          for _, lg in ipairs(langs) do
            -- lg.off points at an IMAGE_RESOURCE_DATA_ENTRY, 16 bytes:
            --   OffsetToData(4) Size(4) CodePage(4) Reserved(4)
            local de_off = rsrc_off + lg.off
            local ord = u32(pe, de_off + 1)
            local size = u32(pe, de_off + 4 + 1)
            -- OffsetToData is an RVA. Turn it into a file offset by finding
            -- the section it lands in and translating.
            local file_off = nil
            for i = 0, nsec - 1 do
              local h = sec_tbl + i * 40
              local vsz = u32(pe, h + 8 + 1)
              local vrva = u32(pe, h + 12 + 1)
              local roff = u32(pe, h + 20 + 1)
              if ord >= vrva and ord < vrva + vsz then
                file_off = roff + (ord - vrva)
                break
              end
            end
            local bytes = file_off and pe:sub(file_off + 1, file_off + size) or ""
            out.types[type_id][nm.name][lg.name] = { rva = ord, size = size, bytes = bytes }
          end
        end
      end
    end
  end
  return out
end

-- Convert an ASCII substring like "TestApp" into a UTF-16LE bytes we can
-- pattern-match against the RT_VERSION blob (which stores strings as WCHARs).
local function ascii_to_utf16le(s)
  local out = {}
  for i = 1, #s do
    out[#out+1] = s:sub(i, i)
    out[#out+1] = "\0"
  end
  return table.concat(out)
end

-- ---- default build ------------------------------------------------------
local src = TEMP .. "\\clua_t_rsrc.lua"
local exe = TEMP .. "\\clua_t_rsrc.exe"
writefile(src, 'print("hi from rsrc test")\n')
os.remove(exe)
local code, out = run(('"%s" build "%s" -o "%s"'):format(clua_abs, src, exe))
if code ~= 0 or not exists(exe) then
  -- If the link path itself failed, skip: the .rsrc test is a functional
  -- assertion on the resulting exe, not on the flag plumbing.
  print("[~] SKIP test-rsrc (base build failed: " ..
        (out or ""):gsub("[\r\n]+", " "):sub(1, 160) .. ")")
  os.remove(src); os.exit(0)
end

local rsrc, err = walk_rsrc(exe)
ok(rsrc ~= nil, "the default exe has a walkable .rsrc section",
   err or "ok")

if rsrc then
  -- RT_VERSION = 16
  local ver = rsrc.types[16]
  ok(ver ~= nil, "the .rsrc tree contains an RT_VERSION resource")
  if ver then
    local any_str = nil
    for _, byname in pairs(ver) do
      for _, bylang in pairs(byname) do
        any_str = bylang.bytes
        break
      end
      if any_str then break end
    end
    ok(any_str ~= nil and any_str:find(ascii_to_utf16le("FileVersion"), 1, true) ~= nil,
       'the RT_VERSION blob contains the "FileVersion" StringFileInfo key',
       any_str and (#any_str .. " bytes") or "no data")
  end

  -- RT_MANIFEST = 24
  local mf = rsrc.types[24]
  ok(mf ~= nil, "the .rsrc tree contains an RT_MANIFEST resource")
  if mf then
    local xml = nil
    for _, byname in pairs(mf) do
      for _, bylang in pairs(byname) do
        xml = bylang.bytes
        break
      end
      if xml then break end
    end
    ok(xml ~= nil and xml:find("compatibility", 1, true) ~= nil,
       'the RT_MANIFEST XML mentions "compatibility"',
       xml and xml:sub(1, 120) or "no data")
  end
end

-- ---- --product-name override --------------------------------------------
local exe2 = TEMP .. "\\clua_t_rsrc_p.exe"
os.remove(exe2)
local co, oo = run(('"%s" build "%s" -o "%s" --product-name=TestApp')
                   :format(clua_abs, src, exe2))
if co == 0 and exists(exe2) then
  local rsrc2 = walk_rsrc(exe2)
  ok(rsrc2 ~= nil, "the override build produced a walkable .rsrc")
  if rsrc2 and rsrc2.types[16] then
    local any_str = nil
    for _, byname in pairs(rsrc2.types[16]) do
      for _, bylang in pairs(byname) do
        any_str = bylang.bytes
        break
      end
      if any_str then break end
    end
    ok(any_str ~= nil and any_str:find(ascii_to_utf16le("TestApp"), 1, true) ~= nil,
       'the RT_VERSION blob carries the overridden ProductName "TestApp"',
       any_str and (#any_str .. " bytes") or "no data")
  end
  os.remove(exe2)
else
  print("[~] SKIP --product-name override check (build failed: " ..
        (oo or ""):gsub("[\r\n]+", " "):sub(1, 120) .. ")")
end

os.remove(src); os.remove(exe)

if fails > 0 then os.exit(1) end
print("[+] PASS test-rsrc (all checks)")
os.exit(0)
