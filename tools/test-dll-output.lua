-- test-dll-output.lua -- gate for clua build --output=dll.
--
-- Covers what the first DLL arc actually ships end-to-end:
--   * `clua build ... --output=dll -o test.dll` produces a valid PE
--   * IMAGE_FILE_DLL is set in the FileHeader
--   * IMAGE_DIRECTORY_ENTRY_EXPORT is populated (non-zero RVA + size)
--   * every name from the module's `_exports = {...}` table is present in
--     the export name table
--
-- Does NOT cover (deliberately, this arc):
--   * calling an exported function via GetProcAddress and getting the Lua
--     result back -- the exports currently point at Rt_DllExportDefault
--     (returns 0) until the per-export trampoline generator lands.
--
-- Skips cleanly when build/bin/clua.exe is missing (worktree may not have
-- built the toolchain).

local CLUA = "build\\bin\\clua.exe"

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP test-dll-output (build\\bin\\clua.exe not built; run build\\build-luac.bat)")
  os.exit(0)
end

local TEMP = os.getenv("TEMP") or "."
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
  f:write(s)
  f:close()
end

local function readfile(p)
  local f = assert(io.open(p, "rb"))
  local s = f:read("*a")
  f:close()
  return s
end

-- ---- 1. compile a small DLL with two named exports ----
local src = TEMP .. "\\clua_test_dll_src.lua"
local dll = TEMP .. "\\clua_test_dll_out.dll"
writefile(src, [[
_exports = {
  add = function(a, b) return a + b end,
  greet = function(name) return "hello, " .. name end,
}
]])

local code, out = run(('"%s\\%s" build "%s" --output=dll -o "%s"'):format(
  io.popen("cd"):read("*l"), CLUA, src, dll))
ok(code == 0 and exists(dll),
   "clua build --output=dll produces the requested file",
   code ~= 0 and ("rc=" .. tostring(code) .. " out=" .. (out or "")) or nil)

-- ---- 2. parse the PE header + verify IMAGE_FILE_DLL ----
-- Manual little-endian PE parse: DOS header at 0, e_lfanew at offset 0x3C,
-- PE signature at that offset, IMAGE_FILE_HEADER right after (20 bytes),
-- IMAGE_OPTIONAL_HEADER64 next (0xF0 bytes).
local function u16(s, off) return s:byte(off + 1) + s:byte(off + 2) * 256 end
local function u32(s, off)
  return s:byte(off + 1)
       + s:byte(off + 2) * 0x100
       + s:byte(off + 3) * 0x10000
       + s:byte(off + 4) * 0x1000000
end

if exists(dll) then
  local bytes = readfile(dll)
  ok(bytes:sub(1, 2) == "MZ", "output has a DOS 'MZ' signature")
  local pe_off = u32(bytes, 0x3C)
  ok(bytes:sub(pe_off + 1, pe_off + 4) == "PE\0\0",
     "output has a PE signature at e_lfanew")
  local fh_off = pe_off + 4
  local characteristics = u16(bytes, fh_off + 18)
  local IMAGE_FILE_DLL = 0x2000
  local has_dll_bit = (math.floor(characteristics / IMAGE_FILE_DLL) % 2) == 1
  ok(has_dll_bit,
     "FileHeader Characteristics has IMAGE_FILE_DLL set",
     ("characteristics = 0x%04X"):format(characteristics))

  -- optional header directory: DIR_EXPORT is entry 0, at oh+112, 8 bytes each.
  local oh_off = fh_off + 20
  local export_rva  = u32(bytes, oh_off + 112 + 0 * 8 + 0)
  local export_size = u32(bytes, oh_off + 112 + 0 * 8 + 4)
  ok(export_rva > 0 and export_size > 0,
     "IMAGE_DIRECTORY_ENTRY_EXPORT rva/size are both non-zero",
     ("rva=0x%X size=0x%X"):format(export_rva, export_size))

  -- resolve the export directory in the file. Walk section headers to
  -- find the section containing export_rva, then translate RVA to file
  -- offset (rva - section_rva + section_file_off).
  local nsec = u16(bytes, fh_off + 2)
  local opt_size = u16(bytes, fh_off + 16)
  local sh_off = fh_off + 20 + opt_size
  local file_off = nil
  for i = 0, nsec - 1 do
    local base = sh_off + i * 40
    local sec_rva = u32(bytes, base + 12)
    local sec_size = u32(bytes, base + 16)
    local sec_foff = u32(bytes, base + 20)
    if export_rva >= sec_rva and export_rva < sec_rva + sec_size then
      file_off = export_rva - sec_rva + sec_foff
      break
    end
  end
  ok(file_off ~= nil, "export directory falls inside a section")

  if file_off ~= nil then
    -- IMAGE_EXPORT_DIRECTORY: at +20 NumberOfFunctions, +24 NumberOfNames,
    -- +28 AddressOfFunctions (RVA), +32 AddressOfNames (RVA).
    local nfunc = u32(bytes, file_off + 20)
    local nname = u32(bytes, file_off + 24)
    local names_rva = u32(bytes, file_off + 32)

    ok(nfunc == 2 and nname == 2,
       "export directory reports 2 exports for add + greet",
       ("nfunc=%d nname=%d"):format(nfunc, nname))

    -- resolve the names_rva to a file offset and pull each name string.
    local names_foff = nil
    for i = 0, nsec - 1 do
      local base = sh_off + i * 40
      local sec_rva = u32(bytes, base + 12)
      local sec_size = u32(bytes, base + 16)
      local sec_foff = u32(bytes, base + 20)
      if names_rva >= sec_rva and names_rva < sec_rva + sec_size then
        names_foff = names_rva - sec_rva + sec_foff
        break
      end
    end

    if names_foff ~= nil then
      local names_found = {}
      for i = 0, math.min(nname, 32) - 1 do
        local name_rva = u32(bytes, names_foff + i * 4)
        for j = 0, nsec - 1 do
          local base = sh_off + j * 40
          local sec_rva = u32(bytes, base + 12)
          local sec_size = u32(bytes, base + 16)
          local sec_foff = u32(bytes, base + 20)
          if name_rva >= sec_rva and name_rva < sec_rva + sec_size then
            local off = name_rva - sec_rva + sec_foff
            local e = off
            while e < #bytes and bytes:byte(e + 1) ~= 0 do e = e + 1 end
            names_found[bytes:sub(off + 1, e)] = true
            break
          end
        end
      end
      ok(names_found["add"],   "'add' appears in the export name table")
      ok(names_found["greet"], "'greet' appears in the export name table")
    end
  end
end

os.remove(dll)
os.remove(src)

if fails == 0 then
  print("[+] all DLL-output checks passed")
  os.exit(0)
else
  print(("[-] %d DLL-output check(s) failed"):format(fails))
  os.exit(1)
end
