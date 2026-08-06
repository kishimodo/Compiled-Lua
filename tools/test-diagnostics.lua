-- Compiler diagnostics ("intellisense") end-to-end test. Drives compiler.exe
-- over fixture sources and asserts the clang/rustc-style behavior:
--   * a syntax error fails the build with a located "error: <msg>" header,
--     an  "-->  <file>:<line>:<col>" arrow line, a source snippet, and a caret;
--   * questionable-but-valid code COMPILES (exit 0) but emits located warnings;
--   * --Werror turns those warnings into a build failure;
--   * -w/--no-warn silences them and compiles clean;
--   * --color=never never emits ANSI escapes; --color=always always does;
--   * the return-value of a `return` is NOT misreported as dead code (W004).
-- Run from the repo root by clua-interp.exe (interpreter mode is irrelevant here --
-- the test only shells out to compiler.exe).

local function abscwd()
  local p = io.popen("cd"); if not p then return "." end
  local d = p:read("*a") or ""; p:close(); return (d:gsub("%s+$", ""))
end
local ROOT     = abscwd()
local COMPILER = ROOT .. "\\build\\bin\\compiler.exe"
local TMP      = (os.getenv("TEMP") or ".") .. "\\clua-interp-diagtest"

local function sh(cmd) local ok, _, c = os.execute('"' .. cmd .. '"'); return (ok == true) or (ok == 0) or (c == 0) end
local function spit(p, s) local f = io.open(p, "wb"); if not f then return false end f:write(s); f:close(); return true end
local function exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end return false end
local function fail(m) print("[-] FAIL test-diagnostics: " .. m); os.exit(1) end

-- Skip the whole test cleanly if compiler.exe hasn't been built yet -- this
-- fixture only exercises the driver, so there's nothing to check when it
-- doesn't exist (rather than pretending to pass).
if not exists(COMPILER) then
  print("[~] SKIP test-diagnostics: " .. COMPILER .. " not found (run `make compiler` first)")
  os.exit(0)
end

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

-- 1) Syntax error: build fails, located error + snippet + caret in the
--    clang/rustc shape:
--       error: <msg>
--          --> <file>:<line>:<col>
--          |
--        N | <source>
--          |         ^
do
  local o, c = compile('--color=never -o "' .. OUT .. '" "' .. BAD .. '"')
  if c == 0 then fail("syntax error should fail the build (got exit 0)\n" .. o) end
  if not o:match("error:") then fail("missing 'error:' header:\n" .. o) end
  if not o:match("%-%->%s*[^%s]*bad%.lua:2:%d+") then
    fail("missing '--> file.lua:line:col' arrow row:\n" .. o)
  end
  if not o:match("unexpected symbol") then fail("missing the actual Lua error text:\n" .. o) end
  if not o:match("%^") then fail("missing the caret '^' in the snippet:\n" .. o) end
  if exists(OUT) then fail("a failed compile must not produce an exe") end
end

-- 2) Warnings on by default: compiles (exit 0) but reports located warnings.
do
  local o, c = compile('--color=never -o "' .. OUT .. '" "' .. WARN .. '"')
  if c ~= 0 then fail("warning-only code must still compile (got exit " .. tostring(c) .. ")\n" .. o) end
  if not exists(OUT) then fail("warning-only code should still produce an exe") end
  if not o:match("warning:.-W001") then fail("expected W001 unused-local warning:\n" .. o) end
  if not o:match("warning:.-E001") then fail("expected E001 undefined-global warning:\n" .. o) end
  if not o:match("%-%->%s*[^%s]*warn%.lua:2:%d+") then
    fail("W001 should carry a '--> warn.lua:2:col' location:\n" .. o)
  end
  if not o:match("%-%->%s*[^%s]*warn%.lua:3:%d+") then
    fail("E001 should carry a '--> warn.lua:3:col' location:\n" .. o)
  end
  if o:match("dead code") then fail("W004 false positive: a return value is not dead code\n" .. o) end
  if not o:match("compiled anyway") then fail("expected the 'compiled anyway' summary:\n" .. o) end
end

-- 3) --Werror: the same warnings now fail the build.
do
  sh('del /Q "' .. OUT .. '" >nul 2>&1')
  local o, c = compile('--color=never --Werror -o "' .. OUT .. '" "' .. WARN .. '"')
  if c == 0 then fail("--Werror should fail the build on warnings (got exit 0)\n" .. o) end
  if not o:match("treated as errors") then fail("expected the --Werror summary:\n" .. o) end
  if exists(OUT) then fail("--Werror build failure must not produce an exe") end
end

-- 4) -w: warnings silenced, clean compile.
do
  local o, c = compile('--color=never -w -o "' .. OUT .. '" "' .. WARN .. '"')
  if c ~= 0 then fail("-w should compile cleanly (got exit " .. tostring(c) .. ")\n" .. o) end
  if o:match("warning:") then fail("-w must suppress all warnings:\n" .. o) end
  if not exists(OUT) then fail("-w should still produce an exe") end
end

-- 5) --color=never: no ANSI escapes even in captured output.
do
  local o, _ = compile('--color=never -o "' .. OUT .. '" "' .. BAD .. '"')
  if o:find("\27%[") then fail("--color=never must not emit ANSI escapes:\n" .. o) end
end

-- 6) --color=always: at least one ANSI escape even to a pipe.
do
  local o, _ = compile('--color=always -o "' .. OUT .. '" "' .. BAD .. '"')
  if not o:find("\27%[") then fail("--color=always must emit at least one ANSI escape:\n" .. o) end
end

-- 7) auto (default) into a piped io.popen must NOT emit color -- test-runner
--    captures are the exact non-TTY channel we're guarding.
do
  local o, _ = compile('-o "' .. OUT .. '" "' .. BAD .. '"')
  if o:find("\27%[") then
    fail("--color=auto must not emit ANSI escapes when stderr is a pipe:\n" .. o)
  end
end

sh('rmdir /S /Q "' .. TMP .. '" >nul 2>&1')
print("[+] PASS test-diagnostics (rustc-style syntax error + snippet + caret, warnings, --Werror, -w, --color)")
os.exit(0)
