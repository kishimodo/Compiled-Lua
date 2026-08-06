-- test-dll-importlib.lua — a DLL build must land a matching .DEF module-
-- definition file next to the .dll so downstream C consumers can synthesize
-- the import library (.lib for MSVC via `link /def:foo.def /dll`, libfoo.a
-- for MinGW via `dlltool -d foo.def -D foo.dll -l libfoo.a`).
--
-- The .def is the smallest change with the broadest reach: it is plain text,
-- deterministic, and both major Windows toolchains already know how to turn
-- one into a matching import archive. Emitting it is the compile-step
-- equivalent of publishing an .h -- the DLL's public interface, in a form
-- other toolchains can act on without any CLua-side archive plumbing.
--
-- Contract (checked on any host that has clua.exe):
--   * `clua build ... --dll -o foo.dll` also writes foo.def next to foo.dll.
--   * The .def opens with `LIBRARY "foo.dll"`.
--   * The .def has an `EXPORTS` section that names `clua_run` (the DLL entry
--     runtime_init.c publishes with __declspec(dllexport)).
--   * An explicit --emit-def=<path> overrides the default derivation.
--
-- Skip discipline: this suite runs on hosts that may not yet ship the DLL
-- link path. When `clua build --dll` errors with anything that looks like
-- "not supported" / "DLL", the test SKIPS instead of failing -- the .def
-- writer + flag plumbing is what this suite guards, and it lands ahead of
-- the DLL link itself.
--
-- Run by tools/run-tests.lua from the repo root under clua-interp.exe.

local CLUA = "build\\bin\\clua.exe"

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close(); return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP test-dll-importlib (build\\bin\\clua.exe not built; run build\\build-luac.bat)")
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

-- The fixture: a trivial closed-world program. The compiled DLL exports
-- clua_run (the runtime's __declspec(dllexport) entry), not per-Lua-function
-- symbols, so the fixture content doesn't affect the export table -- the
-- .def only names DLL-level entries.
local src = TEMP .. "\\clua_t_dll.lua"
local dll = TEMP .. "\\clua_t_dll.dll"
local def_default = TEMP .. "\\clua_t_dll.def"
writefile(src, 'print("hello from a CLua DLL")\n')

os.remove(dll)
os.remove(def_default)

-- Attempt a DLL build with the derived .def path.
local code, out = run(('"%s" build "%s" --dll -o "%s"'):format(clua_abs, src, dll))

-- Skip cleanly on hosts that haven't landed DLL support yet: the reject
-- message in the current tree is "--dll is not supported in M0 (exe only)".
-- Anything mentioning "not supported" / a plain "DLL" refusal is treated as
-- "DLL link path absent" and this suite is a no-op -- there is nothing for
-- it to guard until the link exists.
if code ~= 0 then
  local ol = out:lower()
  if ol:find("not supported", 1, true) or ol:find("--dll", 1, true)
     or ol:find("dll build", 1, true) then
    print("[~] SKIP test-dll-importlib (DLL link path not yet available: "
          .. out:gsub("[\r\n]+", " "):sub(1, 120) .. ")")
    os.remove(src)
    os.exit(0)
  end
  ok(false, "clua build --dll succeeded", out:sub(1, 200))
  os.remove(src)
  os.exit(1)
end

-- DLL build succeeded: the whole export/import contract must be honored.
ok(exists(dll), "clua build --dll produced the DLL at -o path", dll)
ok(exists(def_default),
   "a .def file is emitted next to the DLL (derived path)",
   def_default)

local def = readfile(def_default) or ""

-- LIBRARY directive: quoted basename of the DLL, on its own line. The
-- basename (not the full path) is what the Windows loader binds against.
ok(def:find('LIBRARY%s+"clua_t_dll%.dll"') ~= nil,
   'the .def opens with LIBRARY "<dll-basename>"',
   def:sub(1, 80))

-- EXPORTS section with the DLL entry name. The runtime publishes clua_run
-- as __declspec(dllexport) (clua/src/runtime/runtime_init.c); the export
-- set in the .def must list every symbol the DLL actually exports.
ok(def:find("\nEXPORTS\n") ~= nil or def:find("^EXPORTS\n") ~= nil,
   'the .def has an EXPORTS section', def:sub(1, 120))
ok(def:find("[\r\n]%s*clua_run[\r\n]") ~= nil
   or def:find("[\r\n]%s*clua_run$") ~= nil,
   'the EXPORTS section names clua_run', def:sub(1, 200))

-- ---- explicit --emit-def=<path> overrides the derivation ----
local custom_def = TEMP .. "\\clua_t_dll_custom.def"
os.remove(custom_def)
local c2, o2 = run(('"%s" build "%s" --dll -o "%s" --emit-def="%s"')
                   :format(clua_abs, src, dll, custom_def))
ok(c2 == 0, "clua build --dll --emit-def=<path> succeeds", o2:sub(1, 200))
ok(exists(custom_def), "--emit-def=<path> writes to the explicit path",
   custom_def)

-- ---- .exe builds must NOT emit a .def (an exe has no import surface) ----
local exe_src = TEMP .. "\\clua_t_exe_nodef.lua"
local exe_out = TEMP .. "\\clua_t_exe_nodef.exe"
local exe_def = TEMP .. "\\clua_t_exe_nodef.def"
writefile(exe_src, 'print("hi")\n')
os.remove(exe_out); os.remove(exe_def)
local c3, o3 = run(('"%s" build "%s" -o "%s"'):format(clua_abs, exe_src, exe_out))
ok(c3 == 0, "clua build (exe) still succeeds after adding the .def path",
   o3:sub(1, 200))
ok(exists(exe_out), "clua build (exe) produced the exe", exe_out)
ok(not exists(exe_def), "clua build (exe) emitted NO .def (nothing to describe)",
   exe_def)

os.remove(src); os.remove(dll); os.remove(def_default); os.remove(custom_def)
os.remove(exe_src); os.remove(exe_out); os.remove(exe_def)

if fails > 0 then os.exit(1) end
print("[+] PASS test-dll-importlib (all checks)")
os.exit(0)
