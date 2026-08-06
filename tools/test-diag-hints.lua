-- test-diag-hints.lua -- gate the contextual hint database wired into the
-- compiler's error path. Five fixtures, each triggering a distinct pattern
-- class (syntax, block, type, scope, limit-adjacent). For each we compile
-- and assert that (a) the build fails, and (b) stderr carries a `help:`
-- block whose body contains a keyword unique to the expected hint.
--
-- Skipped cleanly when build\bin\compiler.exe is absent -- same convention
-- as tools\test-diagnostics.lua, so this suite auto-includes into the normal
-- gate run once the compiler has been built.

local function abscwd()
  local p = io.popen("cd"); if not p then return "." end
  local d = p:read("*a") or ""; p:close(); return (d:gsub("%s+$", ""))
end
local ROOT     = abscwd()
local COMPILER = ROOT .. "\\build\\bin\\compiler.exe"
local TMP      = (os.getenv("TEMP") or ".") .. "\\clua-diag-hints"

local function sh(cmd) local ok, _, c = os.execute('"' .. cmd .. '"'); return (ok == true) or (ok == 0) or (c == 0) end
local function spit(p, s) local f = io.open(p, "wb"); if not f then return false end f:write(s); f:close(); return true end
local function exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end return false end
local function fail(m) print("[-] FAIL test-diag-hints: " .. m); os.exit(1) end

if not exists(COMPILER) then
  print("[~] SKIP test-diag-hints: " .. COMPILER .. " not found (run `make compiler` first)")
  os.exit(0)
end

sh('rmdir /S /Q "' .. TMP .. '" >nul 2>&1'); sh('mkdir "' .. TMP .. '" >nul 2>&1')

-- Cmd wrapping matches tools\test-diagnostics.lua's convention: outer quote
-- pair swallowed by `cmd /c`, inner paths quoted for spaces.
local function compile(src)
  local out_exe = TMP .. "\\out.exe"
  local full = '"' .. COMPILER .. '" --color=never -o "' .. out_exe .. '" "' .. src .. '" 2>&1'
  local p = io.popen('"' .. full .. '"')
  if not p then return "", -1 end
  local o = p:read("*a") or ""
  local _, _, code = p:close()
  return o, (code or 0)
end

-- (src, needle) -> compile the source, assert failure + `help:` line + needle
-- (case-insensitive substring, matched against the raw output). Needle is a
-- word/phrase the corresponding hint entry is guaranteed to carry -- picking
-- ones that appear ONLY in that hint keeps the assertion tight.
local function check(name, code, needle)
  local path = TMP .. "\\" .. name .. ".lua"
  spit(path, code)
  local o, c = compile(path)
  if c == 0 then fail(name .. ": expected compile failure, got exit 0\n" .. o) end
  if not o:match("help:") then fail(name .. ": no `help:` block in stderr\n" .. o) end
  if not o:lower():find(needle:lower(), 1, true) then
    fail(name .. ": hint missing needle \"" .. needle .. "\"\n" .. o)
  end
end

-- 1) SYNTAX -- `=` in expression position (double `=`). Fixture: `x = = 5`
--    The parser's simpleexp() cannot classify `=` and raises
--    `unexpected symbol near '='` -- so the eq-vs-assign hint fires.
--    (Note: `if x = 1 then` gives `'then' expected near '='`, a DIFFERENT
--    hint entry; the fixture here is chosen to lock the specific
--    "unexpected symbol near '='" pattern.)
check("eq_vs_assign",
  "local x = 1\nx = = 5\n",
  "==")

-- 2) BLOCK -- unclosed `if`. The parser eventually raises `'end' expected`
--    with a `(to close ...)` clause; our hint tells the reader to trace
--    back to the block opener.
check("unclosed_if",
  "local x = 1\nif x == 1 then\n  print(x)\n",
  "block opened earlier")

-- 3) SYNTAX/OPERATOR -- `+*` with no right operand. The lexer stops at `*`
--    and reports `unexpected symbol near '*'`; hint enumerates the common
--    causes (stray operator, reserved word, etc).
check("bad_operator",
  "local x = 5\nlocal y = x +* 2\n",
  "operator without a right-hand operand")

-- 4) SCOPE / const reassign. `local x <const> = 1; x = 2` -- lparser.c
--    raises `attempt to assign to const variable`. Compile-time semerror,
--    not a runtime type error, so the hint fires from the parser message.
check("const_reassign",
  "local x <const> = 1\nx = 2\n",
  "<const> attribute")

-- 5) SCOPE / goto across a local. `goto L; local x; ::L::` triggers
--    `jumps into the scope of local 'x'` at compile time. The hint text
--    explains WHY Lua forbids this ("would be uninitialised after the
--    jump"), which is a phrase unique to this entry.
check("goto_into_scope",
  "do\n  goto L\n  local x = 1\n  ::L::\n  print(x)\nend\n",
  "uninitialised after the jump")

sh('rmdir /S /Q "' .. TMP .. '" >nul 2>&1')
print("[+] PASS test-diag-hints (5 fixtures across syntax/block/operator/type/scope)")
os.exit(0)
