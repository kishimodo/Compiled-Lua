-- test-diag-suggest.lua -- "did you mean" suggestions for undefined names.
--
-- Compiles fixtures via `clua check` and asserts the C-side diag_suggest.c
-- pass:
--   * a program calling `pritn("hi")` (typo of `print`) produces a
--     "did you mean 'print'?" help note in stderr;
--   * a program calling `xz("hi")` produces NO suggestion for `xz`
--     because the name is under the length-4 confident-suggestion floor;
--   * a correct program with no unknown globals stays quiet (byte-identity
--     backstop -- the pass is diagnostic-only and must not spam the user).
--
-- Skips cleanly when build\bin\clua.exe hasn't been built yet.
--
-- Run from the repo root by tools/run-tests.lua.

local CLUA = "build\\bin\\clua.exe"

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP test-diag-suggest (" .. CLUA .. " not built; run build\\build-luac.bat)")
  os.exit(0)
end

local ROOT = io.popen("cd"):read("*l")
local CLUA_ABS = ROOT .. "\\" .. CLUA
local TMP  = (os.getenv("TEMP") or ".") .. "\\clua-diag-suggest"

os.execute(('rmdir /S /Q "%s" >nul 2>&1'):format(TMP))
os.execute(('mkdir "%s" >nul 2>&1'):format(TMP))

local fails = 0
local function ok(cond, name, detail)
  if cond then
    print("[+] PASS " .. name)
  else
    fails = fails + 1
    print("[-] FAIL " .. name .. (detail and (" -- " .. detail:sub(1, 400)) or ""))
  end
end

local function writefile(p, s)
  local f = assert(io.open(p, "wb"))
  f:write(s); f:close()
end

-- Runs `clua check <lua_path>` with color disabled so ANSI escapes don't
-- confuse the plain-text assertions. Returns (exit_code, combined_output).
local function check(lua_path)
  local full = ('("%s" check --color=never "%s") 2>&1'):format(CLUA_ABS, lua_path)
  local p = io.popen(full)
  local out = p:read("*a") or ""
  local okc, _, code = p:close()
  if okc == true then code = 0 end
  return code or -1, out
end

-- 1) A typo of a stdlib name (length >= 4, within edit distance 2) must
--    surface a "did you mean" suggestion naming the correct spelling.
do
  local src = TMP .. "\\typo_print.lua"
  writefile(src, 'pritn("hi")\n')
  local _, out = check(src)
  ok(out:find("did you mean", 1, true) ~= nil,
     "typo of 'print' triggers a 'did you mean' help note", out)
  ok(out:find("'print'", 1, true) ~= nil,
     "the suggestion names the intended stdlib function", out)
  ok(out:find("undefined variable 'pritn'", 1, true) ~= nil,
     "the primary error names the misspelled identifier", out)
end

-- 2) A short unknown name (length < 4) must NOT trigger a suggestion:
--    the confident-suggestion floor lives in diag_suggest.c and prevents
--    the pass from guessing at every 2-letter typo. `xz` is length 2 --
--    below the floor, so no `help:` note should print.
do
  local src = TMP .. "\\short_unknown.lua"
  writefile(src, 'xz("hi")\n')
  local _, out = check(src)
  -- No help note for xz. Guard specifically on "did you mean" against the
  -- name 'xz' rather than the whole file (a warning for something else in
  -- a future release shouldn't flake this test).
  ok(not out:find("did you mean", 1, true),
     "short name 'xz' produces no 'did you mean' suggestion", out)
end

-- 3) A correct program (no unknown globals) is quiet: the diagnostic pass
--    is advisory, so byte-identity of correct programs is preserved and
--    the terminal isn't spammed. `print` and `pairs` are both stdlib.
do
  local src = TMP .. "\\clean.lua"
  writefile(src, 'print("hello")\nfor k, v in pairs({}) do end\n')
  local code, out = check(src)
  ok(code == 0, "correct program compiles clean", out)
  ok(not out:find("did you mean", 1, true),
     "correct program produces no suggestions", out)
end

os.execute(('rmdir /S /Q "%s" >nul 2>&1'):format(TMP))

if fails > 0 then os.exit(1) end
print("[+] PASS test-diag-suggest")
os.exit(0)
