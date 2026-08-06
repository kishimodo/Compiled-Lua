-- test-dll-output.lua -- gate for clua build --output=dll.
--
-- Covers what the first DLL arc actually ships end-to-end:
--   * `clua build ... --output=dll -o test.dll` produces a valid PE
--   * IMAGE_FILE_DLL is set in the FileHeader
--   * IMAGE_DIRECTORY_ENTRY_EXPORT is populated (non-zero RVA + size)
--   * every name from the module's `_exports = {...}` table is present in
--     the export name table
--
-- Also covers (arc that landed the trampoline generator):
--   * loading the built DLL via LoadLibraryA + GetProcAddress
--   * calling the exported `add` function with (double,double) and
--     verifying the returned double is the Lua function's return value
--
-- Skips cleanly when build/bin/clua.exe is missing (worktree may not have
-- built the toolchain), or when the FFI runtime library is not available
-- to the host lua interpreter running this test.

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

-- ---- 1. compile a small DLL with named exports across three ABI shapes ----
-- The `_export_types` companion table tells the trampoline generator which
-- dispatcher symbol each export routes to. `add` has no override, so it
-- defaults to the double(double,double) shape (backward-compat with the
-- pre-shape arc); `add_i` picks int64_t(int64_t,int64_t); `greet` picks
-- const char *(const char *). All three flavours get exercised by the FFI
-- round-trips further down.
local src = TEMP .. "\\clua_test_dll_src.lua"
local dll = TEMP .. "\\clua_test_dll_out.dll"
writefile(src, [[
_exports = {
  add   = function(a, b) return a + b end,
  greet = function(name) return "hi " .. name end,
  add_i = function(a, b) return a + b end,
}
_export_types = {
  add_i = "ii_i",
  greet = "s_s",
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

    ok(nfunc == 3 and nname == 3,
       "export directory reports 3 exports for add + add_i + greet",
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
      ok(names_found["add_i"], "'add_i' appears in the export name table")
      ok(names_found["greet"], "'greet' appears in the export name table")
    end
  end
end

-- ---- 3. call the exported functions via LoadLibraryA + GetProcAddress ----
-- The trampoline generator wires each AddressOfFunctions slot to a small
-- .text stub that tail-jumps into one of the Rt_DllExportDispatch* variants,
-- picked by the export's `_export_types` shape token:
--   "dd_d" (default) -> Rt_DllExportDispatch(double, double, int32_t)
--   "ii_i"           -> Rt_DllExportDispatch_ii_i(int64_t, int64_t, int32_t)
--   "s_s"            -> Rt_DllExportDispatch_s_s(const char *, int64_t, int32_t)
--
-- The test loads the DLL through the platform's own loader (LoadLibraryA)
-- so the DLL_PROCESS_ATTACH path -- Rt_DllMain / Rt_ModuleInit -- runs and
-- populates g_ExportsRef. Skipped when the host Lua running this test does
-- not provide the FFI (e.g. a stock lua.exe without CLua's runtime).
if exists(dll) then
  -- ffi is a runtime-provided global; on stock lua.exe it is absent.
  local ffi = rawget(_G, "ffi")
  if type(ffi) ~= "table" or type(ffi.cdef) ~= "function" then
    print("[~] SKIP call-through-ffi (ffi global not available in host lua)")
  else
    -- Tolerate duplicate typedef/proto entries: if the host has already
    -- ffi.cdef'd any of these (e.g. windows package was required earlier),
    -- ignore the redefinition error and rely on the earlier declaration.
    pcall(ffi.cdef, [[
      typedef void* HMODULE;
      typedef void* FARPROC;
      HMODULE LoadLibraryA(const char *lpLibFileName);
      int FreeLibrary(HMODULE hLibModule);
      FARPROC GetProcAddress(HMODULE hModule, const char *lpProcName);
    ]])
    pcall(ffi.cdef, "typedef double (*add_fn_t)(double, double);")
    pcall(ffi.cdef, "typedef int64_t (*add_i_fn_t)(int64_t, int64_t);")
    pcall(ffi.cdef, "typedef const char *(*greet_fn_t)(const char *);")
    local mod = ffi.C.LoadLibraryA(dll)
    ok(mod ~= nil and mod ~= ffi.cast("HMODULE", 0),
       "LoadLibraryA succeeds on the built DLL")
    if mod ~= nil then
      -- dd_d round-trip (the default, pre-shape behavior)
      local proc = ffi.C.GetProcAddress(mod, "add")
      ok(proc ~= nil and proc ~= ffi.cast("FARPROC", 0),
         "GetProcAddress('add') returns a non-NULL address")
      if proc ~= nil then
        local add = ffi.cast("add_fn_t", proc)
        local result = add(2.0, 3.0)
        ok(result == 5.0, "add(2.0, 3.0) returned 5.0 through the trampoline",
           ("got " .. tostring(result)))
      end

      -- ii_i round-trip
      local proc_i = ffi.C.GetProcAddress(mod, "add_i")
      ok(proc_i ~= nil and proc_i ~= ffi.cast("FARPROC", 0),
         "GetProcAddress('add_i') returns a non-NULL address")
      if proc_i ~= nil then
        local add_i = ffi.cast("add_i_fn_t", proc_i)
        -- Use values large enough that a stray double conversion would
        -- lose precision, so a mis-shaped dispatcher is caught. 2^40 + 5
        -- fits int64 exactly but rounds differently under IEEE double.
        -- Lua 5.4 integers are int64 so a plain number passed to a cdata
        -- signature is int64; skip the cdata boxing that the ffi
        -- package's arithmetic metamethod does not support.
        local a = 1099511627776 -- 2^40
        local b = 5
        local expect = a + b
        local r = add_i(a, b)
        ok(tonumber(r) == expect,
           "add_i(2^40, 5) round-trips as int64_t through the ii_i dispatcher",
           ("got " .. tostring(tonumber(r) or r) .. " want " .. tostring(expect)))
      end

      -- s_s round-trip. lua_tostring gives a Lua-owned string; the
      -- dispatcher _strdup's it before popping, so the returned pointer
      -- outlives the Lua GC cycle and is safe to read here. (The DLL leaks
      -- one strdup per call today; documented behaviour for this arc.)
      local proc_s = ffi.C.GetProcAddress(mod, "greet")
      ok(proc_s ~= nil and proc_s ~= ffi.cast("FARPROC", 0),
         "GetProcAddress('greet') returns a non-NULL address")
      if proc_s ~= nil then
        local greet = ffi.cast("greet_fn_t", proc_s)
        local r = greet("world")
        local got = r ~= nil and ffi.string(r) or "(nil)"
        ok(got == "hi world",
           "greet('world') returned 'hi world' through the s_s dispatcher",
           ("got " .. tostring(got)))
      end
      ffi.C.FreeLibrary(mod)
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
