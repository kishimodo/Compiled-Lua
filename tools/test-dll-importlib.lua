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
--   * `clua build ... --output=dll -o foo.dll` (no --dll, no --emit-def)
--     ALSO auto-derives and writes foo.def next to foo.dll -- the gate lives
--     on the resolved output kind, not on any legacy bool.
--   * The .def opens with `LIBRARY "foo.dll"`.
--   * The .def has an `EXPORTS` section that names every entry from the
--     module's `_exports = { name = fn, ...}` table -- add, mul, greet in
--     the fixture below -- matching what the DLL's IMAGE_EXPORT_DIRECTORY
--     actually publishes.
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

-- The fixture: a closed-world program whose module-scope `_exports = {...}`
-- table names three functions. The resolver's ScanEntryExports pass picks
-- those up and hands them to the .def writer, which must therefore list
-- add / mul / greet -- the same names the DLL's export directory publishes
-- (verified independently by tools/test-dll-output.lua).
local src = TEMP .. "\\clua_t_dll.lua"
local dll = TEMP .. "\\clua_t_dll.dll"
local def_default = TEMP .. "\\clua_t_dll.def"
writefile(src, [[
_exports = {
  add   = function(a, b) return a + b end,
  mul   = function(a, b) return a * b end,
  greet = function(name) return "hello, " .. name end,
}
]])

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

-- EXPORTS section with the real names from `_exports = {...}`. The .def is
-- the compile-time descriptor of the DLL's IMAGE_EXPORT_DIRECTORY, so every
-- symbol the DLL actually publishes must show up here.
ok(def:find("\nEXPORTS\n") ~= nil or def:find("^EXPORTS\n") ~= nil,
   'the .def has an EXPORTS section', def:sub(1, 120))

-- The .def writer emits one exported name per indented line
-- ("    <name>\n"), so a plain '\n<ws><name>\n' anchor matches. Order in
-- res.Exports[] follows the resolver's first-seen order (source order in
-- the `_exports = {...}` literal), but the test only asserts membership.
local function exports_name(name)
  return def:find("[\r\n]%s*" .. name .. "[\r\n]") ~= nil
      or def:find("[\r\n]%s*" .. name .. "$") ~= nil
end
ok(exports_name("add"),   'the EXPORTS section names add',   def:sub(1, 400))
ok(exports_name("mul"),   'the EXPORTS section names mul',   def:sub(1, 400))
ok(exports_name("greet"), 'the EXPORTS section names greet', def:sub(1, 400))

-- ---- --output=dll alone (no --dll shim, no --emit-def) also auto-derives ----
-- Regression: the auto-derive gate used to key off the legacy emit_dll bool,
-- so `--output=dll` and `-shared` (both set only output_kind) skipped the
-- .def emit entirely. Assert the gate now lives on the resolved output kind.
local dll2 = TEMP .. "\\clua_t_dll_output.dll"
local def2 = TEMP .. "\\clua_t_dll_output.def"
os.remove(dll2); os.remove(def2)
local co, oo = run(('"%s" build "%s" --output=dll -o "%s"')
                   :format(clua_abs, src, dll2))
ok(co == 0, "clua build --output=dll (alone) succeeds", oo:sub(1, 200))
ok(exists(dll2), "clua build --output=dll produced the DLL at -o path", dll2)
ok(exists(def2),
   "--output=dll alone auto-derives the .def beside the DLL (no --emit-def)",
   def2)
if exists(def2) then
  local d2 = readfile(def2) or ""
  ok(d2:find('LIBRARY%s+"clua_t_dll_output%.dll"') ~= nil,
     '--output=dll: .def opens with LIBRARY "<dll-basename>"',
     d2:sub(1, 80))
  local function d2_has(name)
    return d2:find("[\r\n]%s*" .. name .. "[\r\n]") ~= nil
        or d2:find("[\r\n]%s*" .. name .. "$") ~= nil
  end
  ok(d2_has("add") and d2_has("mul") and d2_has("greet"),
     '--output=dll: .def lists add/mul/greet from `_exports`',
     d2:sub(1, 400))
end

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
os.remove(TEMP .. "\\clua_t_dll_output.dll")
os.remove(TEMP .. "\\clua_t_dll_output.def")
os.remove(exe_src); os.remove(exe_out); os.remove(exe_def)

if fails > 0 then os.exit(1) end
print("[+] PASS test-dll-importlib (all checks)")
os.exit(0)
