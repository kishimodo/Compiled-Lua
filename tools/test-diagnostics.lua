-- Compiler diagnostics ("intellisense") end-to-end test. Drives compiler.exe
-- over fixture sources and asserts the gcc/clang-style behavior:
--   * a syntax error fails the build with a located "<file>:<line>:<col>: error:"
--     message, a source snippet, and a caret;
--   * questionable-but-valid code COMPILES (exit 0) but emits located warnings;
--   * --Werror turns those warnings into a build failure;
--   * -w/--no-warn silences them and compiles clean;
--   * the return-value of a `return` is NOT misreported as dead code (W004).
-- Run from the repo root by luavm.exe (interpreter mode is irrelevant here --
-- the test only shells out to compiler.exe).

local function abscwd()
  local p = io.popen("cd"); if not p then return "." end
  local d = p:read("*a") or ""; p:close(); return (d:gsub("%s+$", ""))
end
local ROOT     = abscwd()
local COMPILER = ROOT .. "\\build\\bin\\compiler.exe"
local TMP      = (os.getenv("TEMP") or ".") .. "\\luavm-diagtest"

local function sh(cmd) local ok, _, c = os.execute('"' .. cmd .. '"'); return (ok == true) or (ok == 0) or (c == 0) end
local function spit(p, s) local f = io.open(p, "wb"); if not f then return false end f:write(s); f:close(); return true end
local function exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end return false end
local function fail(m) print("[-] FAIL test-diagnostics: " .. m); os.exit(1) end

-- Run compiler.exe with `args`; return (combined-output, exit-code). The whole
-- command is wrapped in an outer quote pair so `cmd /c` strips THOSE (its
-- first-and-last-quote rule) rather than mangling the inner quoted paths.
local function compile(args)
  local full = '"' .. COMPILER .. '" ' .. args .. ' 2>&1'
  local p = io.popen('"' .. full .. '"')
  if not p then return "", -1 end
  local o = p:read("*a") or ""
  local _, _, code = p:close()
  return o, (code or 0)
end

sh('rmdir /S /Q "' .. TMP .. '" >nul 2>&1'); sh('mkdir "' .. TMP .. '" >nul 2>&1')

local BAD  = TMP .. "\\bad.lua"
local WARN = TMP .. "\\warn.lua"
local OUT  = TMP .. "\\out.exe"

-- '*' has no left/right operand here -> "unexpected symbol near '*'" on line 2.
spit(BAD, "local x = 5\nlocal y = x +* 2\nprint(y)\n")
-- W001 (unused local 'u') + E001 (undefined global 'g'); the `return g` also
-- guards the W004 dead-code regression -- a return value is not dead code.
spit(WARN, "local function f()\n  local u = 1\n  return g\nend\n\nreturn f()\n")

-- 1) Syntax error: build fails, located error + caret.
do
  local o, c = compile('-o "' .. OUT .. '" "' .. BAD .. '"')
  if c == 0 then fail("syntax error should fail the build (got exit 0)\n" .. o) end
  if not o:match("bad%.lua:2:%d+:%s*error:") then fail("missing located 'file:line:col: error:' line:\n" .. o) end
  if not o:match("unexpected symbol") then fail("missing the actual Lua error text:\n" .. o) end
  if not o:match("%^") then fail("missing the caret '^' in the snippet:\n" .. o) end
  if exists(OUT) then fail("a failed compile must not produce an exe") end
end

-- 2) Warnings on by default: compiles (exit 0) but reports located warnings.
do
  local o, c = compile('-o "' .. OUT .. '" "' .. WARN .. '"')
  if c ~= 0 then fail("warning-only code must still compile (got exit " .. tostring(c) .. ")\n" .. o) end
  if not exists(OUT) then fail("warning-only code should still produce an exe") end
  if not o:match("warn%.lua:2:%d+:%s*warning:.-W001") then fail("expected W001 unused-local warning:\n" .. o) end
  if not o:match("warn%.lua:3:%d+:%s*warning:.-E001") then fail("expected E001 undefined-global warning:\n" .. o) end
  if o:match("dead code") then fail("W004 false positive: a return value is not dead code\n" .. o) end
  if not o:match("compiled anyway") then fail("expected the 'compiled anyway' summary:\n" .. o) end
end

-- 3) --Werror: the same warnings now fail the build.
do
  sh('del /Q "' .. OUT .. '" >nul 2>&1')
  local o, c = compile('--Werror -o "' .. OUT .. '" "' .. WARN .. '"')
  if c == 0 then fail("--Werror should fail the build on warnings (got exit 0)\n" .. o) end
  if not o:match("treated as errors") then fail("expected the --Werror summary:\n" .. o) end
  if exists(OUT) then fail("--Werror build failure must not produce an exe") end
end

-- 4) -w: warnings silenced, clean compile.
do
  local o, c = compile('-w -o "' .. OUT .. '" "' .. WARN .. '"')
  if c ~= 0 then fail("-w should compile cleanly (got exit " .. tostring(c) .. ")\n" .. o) end
  if o:match("warning:") then fail("-w must suppress all warnings:\n" .. o) end
  if not exists(OUT) then fail("-w should still produce an exe") end
end

sh('rmdir /S /Q "' .. TMP .. '" >nul 2>&1')
print("[+] PASS test-diagnostics (located syntax error + caret, default warnings, --Werror, -w, no W004-on-return)")
os.exit(0)
