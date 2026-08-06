-- Multi-line diagnostic formatter end-to-end test. Builds a fixture with a
-- syntax error and asserts the rustc/zig shape emitted by LcDiag_Report:
--   * 2 lines of source context ABOVE the primary line
--   * the primary line itself with a caret row
--   * 2 lines of source context BELOW
--   * the `-->` arrow row
--   * the `|` pipe gutter
-- If the compiler ever routes a `help:` block through this path (e.g. a
-- "did you mean" suggestion for an undefined global), the assertion in the
-- guarded block below will fire on it. Skips cleanly if compiler.exe hasn't
-- been built.

local function abscwd()
  local p = io.popen("cd"); if not p then return "." end
  local d = p:read("*a") or ""; p:close(); return (d:gsub("%s+$", ""))
end
local ROOT     = abscwd()
local COMPILER = ROOT .. "\\build\\bin\\compiler.exe"
local TMP      = (os.getenv("TEMP") or ".") .. "\\clua-diag-multiline"

local function sh(cmd) local ok, _, c = os.execute('"' .. cmd .. '"'); return (ok == true) or (ok == 0) or (c == 0) end
local function spit(p, s) local f = io.open(p, "wb"); if not f then return false end f:write(s); f:close(); return true end
local function exists(p) local f = io.open(p, "rb"); if f then f:close(); return true end return false end
local function fail(m) print("[-] FAIL test-diag-multiline: " .. m); os.exit(1) end

if not exists(COMPILER) then
  print("[~] SKIP test-diag-multiline: " .. COMPILER .. " not found (run `make compiler` first)")
  os.exit(0)
end

local function compile(args)
  local full = '"' .. COMPILER .. '" ' .. args .. ' 2>&1'
  local p = io.popen('"' .. full .. '"')
  if not p then return "", -1 end
  local o = p:read("*a") or ""
  local _, _, code = p:close()
  return o, (code or 0)
end

sh('rmdir /S /Q "' .. TMP .. '" >nul 2>&1'); sh('mkdir "' .. TMP .. '" >nul 2>&1')

local BAD = TMP .. "\\multiline.lua"
local OUT = TMP .. "\\out.exe"

-- 7 lines. Line 5 has the syntax error ("+*" has no rhs then a bad token).
-- The formatter should show lines 3-7 (primary line 5 with 2 above, 2 below).
local src = table.concat({
  "-- multi-line context fixture",  -- 1
  "local a = 1",                    -- 2
  "local b = 2",                    -- 3  (context -2)
  "local c = 3",                    -- 4  (context -1)
  "local d = a +* b",               -- 5  <- primary
  "local e = 5",                    -- 6  (context +1)
  "print(a, b, c, d, e)",           -- 7  (context +2)
}, "\n") .. "\n"
spit(BAD, src)

local o, c = compile('--color=never -o "' .. OUT .. '" "' .. BAD .. '"')
if c == 0 then fail("syntax error should fail the build (got exit 0)\n" .. o) end
if exists(OUT) then fail("a failed compile must not produce an exe") end

-- Header & location plumbing.
if not o:match("error") then fail("missing 'error' header:\n" .. o) end
if not o:find("%-%->") then fail("missing '-->' arrow row:\n" .. o) end
if not o:find("|") then fail("missing '|' pipe gutter:\n" .. o) end
if not o:match("%^") then fail("missing caret '^' row:\n" .. o) end

-- The numbered snippet rows we expect: for each expected (line-number, raw
-- source text) pair, escape the raw text into a Lua pattern and match
-- " <N> | <text>" (padded gutter, space-pipe-space, source).
local function esc(s) return (s:gsub("[%(%)%.%%%+%-%*%?%[%]%^%$]", "%%%0")) end
local function has_gutter_line(n, raw_text)
  local pat = "%s" .. tostring(n) .. "%s+|%s+" .. esc(raw_text)
  return o:find(pat) ~= nil
end

-- Two lines of context BEFORE (lines 3, 4).
if not has_gutter_line(3, "local b = 2") then fail("missing context line 3 (before -2):\n" .. o) end
if not has_gutter_line(4, "local c = 3") then fail("missing context line 4 (before -1):\n" .. o) end
-- The primary line 5.
if not has_gutter_line(5, "local d = a +* b") then fail("missing primary line 5:\n" .. o) end
-- Two lines of context AFTER (lines 6, 7).
if not has_gutter_line(6, "local e = 5") then fail("missing context line 6 (after +1):\n" .. o) end
if not has_gutter_line(7, "print(a, b, c, d, e)") then fail("missing context line 7 (after +2):\n" .. o) end

-- Direct-API probe: assert that the LcDiag_Report code path is actually what
-- emitted the multi-line snippet by counting the pipe rows. A single-line
-- shim emits exactly 3 pipe rows (blank / source / caret); the multi-line
-- report emits >= 7 (blank + 5 numbered lines + caret + closing blank).
local pipes = 0
for _ in o:gmatch("|") do pipes = pipes + 1 end
if pipes < 7 then fail("expected the multi-line report's >=7 '|' rows, got " .. pipes .. ":\n" .. o) end

-- When the compiler chose to attach a `help:` block (e.g. a "did you mean"
-- suggestion), it must be well-formed. If it didn't attach one, that's fine.
if o:match("help") then
  if not o:match("help:%s") then fail("saw a 'help' token but no 'help: ' block:\n" .. o) end
end

sh('rmdir /S /Q "' .. TMP .. '" >nul 2>&1')
print("[+] PASS test-diag-multiline (2-before/2-after context, arrow, pipes, caret)")
os.exit(0)
