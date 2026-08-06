-- test-static-output.lua -- gate for clua build --output=obj / --output=lib.
--
-- Covers the two new output kinds that short-circuit the link:
--   * --output=obj publishes the codegen COFF as the final artifact. The
--     first two bytes of a Microsoft x86-64 COFF file header are the machine
--     type, LE-encoded, so IMAGE_FILE_MACHINE_AMD64 (0x8664) shows up as
--     0x64 0x86 at file offset 0.
--   * --output=lib wraps that same COFF in a single-member GNU-form ar
--     archive. GNU archives start with the 8-byte magic "!<arch>\n".
--
-- Also asserts that `clua run` and `--shared-rt` are rejected in combination
-- with these output kinds -- neither runs nor pulls in the shared runtime,
-- so the driver should refuse rather than build a useless artifact.
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
  print("[~] SKIP test-static-output (build\\bin\\clua.exe not built; run build\\build-luac.bat)")
  os.exit(0)
end

local TEMP  = os.getenv("TEMP") or "."
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

local cwd = io.popen("cd"):read("*l")

-- ---- 1. compile a small module with a couple of functions ----
-- Kept intentionally small: the point is the container format, not what the
-- code does. The functions give the armap at least one public symbol to
-- point at.
local src = TEMP .. "\\clua_test_static_src.lua"
writefile(src, [[
local function add(a, b) return a + b end
local function mul(a, b) return a * b end
return add(mul(2, 3), 4)
]])

-- ---- 2. --output=obj ----
local obj = TEMP .. "\\clua_test_static_out.obj"
os.remove(obj)
local code, out = run(('"%s\\%s" build "%s" --output=obj -o "%s"'):format(
  cwd, CLUA, src, obj))
ok(code == 0 and exists(obj),
   "clua build --output=obj produces the requested file",
   (code ~= 0) and ("rc=" .. tostring(code) .. " out=" .. tostring(out)) or nil)

if exists(obj) then
  local bytes = readfile(obj)
  -- Microsoft x86-64 COFF file header: Machine field is the first 2 bytes,
  -- little-endian. IMAGE_FILE_MACHINE_AMD64 == 0x8664 -> bytes {0x64, 0x86}.
  local b1 = bytes:byte(1)
  local b2 = bytes:byte(2)
  ok(b1 == 0x64 and b2 == 0x86,
     "--output=obj file starts with COFF AMD64 magic (0x64 0x86)",
     ("got 0x%02X 0x%02X"):format(b1 or 0, b2 or 0))
end

-- ---- 3. --output=lib ----
local lib = TEMP .. "\\clua_test_static_out.lib"
os.remove(lib)
code, out = run(('"%s\\%s" build "%s" --output=lib -o "%s"'):format(
  cwd, CLUA, src, lib))
ok(code == 0 and exists(lib),
   "clua build --output=lib produces the requested file",
   (code ~= 0) and ("rc=" .. tostring(code) .. " out=" .. tostring(out)) or nil)

if exists(lib) then
  local bytes = readfile(lib)
  ok(bytes:sub(1, 8) == "!<arch>\n",
     "--output=lib file starts with GNU ar magic \"!<arch>\\n\"",
     ("first 8 bytes: %q"):format(bytes:sub(1, 8)))
end

-- ---- 4. --shared-rt with obj/lib is rejected ----
local dummy = TEMP .. "\\clua_test_static_reject.bin"
os.remove(dummy)
code, out = run(('"%s\\%s" build "%s" --output=obj --shared-rt -o "%s"'):format(
  cwd, CLUA, src, dummy))
ok(code ~= 0,
   "--shared-rt with --output=obj is rejected",
   ("rc=" .. tostring(code)))

os.remove(dummy)
code, out = run(('"%s\\%s" build "%s" --output=lib --shared-rt -o "%s"'):format(
  cwd, CLUA, src, dummy))
ok(code ~= 0,
   "--shared-rt with --output=lib is rejected",
   ("rc=" .. tostring(code)))

-- ---- 5. `clua run` with obj/lib is rejected ----
os.remove(dummy)
code, out = run(('"%s\\%s" run "%s" --output=obj'):format(cwd, CLUA, src))
ok(code ~= 0, "`clua run` with --output=obj is rejected",
   ("rc=" .. tostring(code)))

code, out = run(('"%s\\%s" run "%s" --output=lib'):format(cwd, CLUA, src))
ok(code ~= 0, "`clua run` with --output=lib is rejected",
   ("rc=" .. tostring(code)))

-- cleanup
os.remove(obj)
os.remove(lib)
os.remove(dummy)
os.remove(src)

if fails == 0 then
  print("[+] all static-output checks passed")
  os.exit(0)
else
  print(("[-] %d static-output check(s) failed"):format(fails))
  os.exit(1)
end
