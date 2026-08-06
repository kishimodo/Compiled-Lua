-- test-warn-unused.lua -- clua.exe -Wunused / -Werror behavior.
--
-- Covers the diagnostic-category framework end-to-end:
--   1. `-Wunused` on a fixture with `local x = 42; print(1)` emits a
--      `warning[Wunused]` line naming `'x'` on stderr, exit 0.
--   2. `-Wunused -Werror` on the same fixture makes the build fail
--      (non-zero exit) and prints the "-Werror" summary.
--   3. `-Wunused` on `local _unused = 42; print(1)` is quiet (the `_`
--      prefix is Lua's intentional-unused convention).
--   4. NO -W flags on a fixture with an unused local: quiet by default.
--   5. `-Wunused` on `local x = 42; local function inner() return x end;
--      return inner`: quiet because `x` is captured as an upvalue of the
--      inner closure -- capture counts as a read.
--
-- Skips cleanly when clua.exe hasn't been built. Cleans up its temp dir on
-- pass and on fail (so re-running doesn't accumulate garbage).

local CLUA = "build\\bin\\clua.exe"

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP test-warn-unused (build\\bin\\clua.exe not built; "
        .. "run build\\build-luac.bat)")
  os.exit(0)
end

local ROOT     = io.popen("cd"):read("*l")
local TEMP     = os.getenv("TEMP") or "."
local TMP      = TEMP .. "\\clua-warn-unused"
local CLUA_ABS = ROOT .. "\\" .. CLUA

local function sh(cmd) os.execute('"' .. cmd .. '"') end
local function spit(p, s)
  local f = assert(io.open(p, "wb")); f:write(s); f:close()
end

sh('rmdir /S /Q "' .. TMP .. '" >nul 2>&1')
sh('mkdir "' .. TMP .. '" >nul 2>&1')

local fails = 0
local function ok(cond, name, detail)
  if cond then
    print("[+] PASS " .. name)
  else
    fails = fails + 1
    print("[-] FAIL " .. name
          .. (detail and (" -- " .. detail:sub(1, 400)) or ""))
  end
end

-- Wrap in (...) so cmd.exe's outer-quote stripping rule doesn't chew off
-- our first-and-last quotes when the command begins with a quoted path.
local function run(cmd)
  local f = io.popen("(" .. cmd .. ") 2>&1")
  local out = f:read("*a") or ""
  local okc, _, code = f:close()
  if okc == true then code = 0 end
  return code or -1, out
end

-- ------------------------------------------------------------------
-- 1. -Wunused emits the warning on a written-but-unread local, exits 0
-- ------------------------------------------------------------------
do
  local src = TMP .. "\\unused1.lua"
  local exe = TMP .. "\\unused1.exe"
  spit(src, "local x = 42\nprint(1)\n")
  local code, out = run(('"%s" build "%s" -o "%s" -Wunused')
                        :format(CLUA_ABS, src, exe))
  ok(code == 0, "1. -Wunused compiles cleanly (warning is not an error)",
     "exit=" .. tostring(code) .. " out=" .. out)
  ok(out:find("warning%[Wunused%]"),
     "1. -Wunused prints warning[Wunused] header",
     out)
  ok(out:find("'x'"),
     "1. -Wunused names the local ('x') in the message",
     out)
end

-- ------------------------------------------------------------------
-- 2. -Wunused -Werror turns the same warning into a hard error
-- ------------------------------------------------------------------
do
  local src = TMP .. "\\unused2.lua"
  local exe = TMP .. "\\unused2.exe"
  spit(src, "local x = 42\nprint(1)\n")
  sh('del /Q "' .. exe .. '" >nul 2>&1')
  local code, out = run(('"%s" build "%s" -o "%s" -Wunused -Werror')
                        :format(CLUA_ABS, src, exe))
  ok(code ~= 0, "2. -Werror promotes -Wunused hits to a non-zero exit",
     "exit=" .. tostring(code) .. " out=" .. out)
  ok(out:find("warning%[Wunused%]"),
     "2. -Werror still prints the warning before failing",
     out)
end

-- ------------------------------------------------------------------
-- 3. _-prefixed locals are the intentional-unused convention: no warn
-- ------------------------------------------------------------------
do
  local src = TMP .. "\\unused3.lua"
  local exe = TMP .. "\\unused3.exe"
  spit(src, "local _unused = 42\nprint(1)\n")
  local code, out = run(('"%s" build "%s" -o "%s" -Wunused')
                        :format(CLUA_ABS, src, exe))
  ok(code == 0, "3. underscore-prefixed local compiles cleanly",
     "exit=" .. tostring(code) .. " out=" .. out)
  ok(not out:find("warning%[Wunused%]"),
     "3. underscore-prefixed local emits no Wunused warning",
     out)
end

-- ------------------------------------------------------------------
-- 4. No -W flags at all: the category is OFF, so no warning fires
-- ------------------------------------------------------------------
do
  local src = TMP .. "\\unused4.lua"
  local exe = TMP .. "\\unused4.exe"
  spit(src, "local x = 42\nprint(1)\n")
  local code, out = run(('"%s" build "%s" -o "%s"')
                        :format(CLUA_ABS, src, exe))
  ok(code == 0, "4. default (no -W) compiles cleanly",
     "exit=" .. tostring(code) .. " out=" .. out)
  ok(not out:find("warning%[Wunused%]"),
     "4. default (no -W) suppresses the unused-local warning",
     out)
end

-- ------------------------------------------------------------------
-- 5. Captured-as-upvalue counts as a read (this is the classic false-
--    positive to avoid). `x` is only referenced inside `inner` -- but
--    the OP_CLOSURE emits an upvaldesc naming x's register, and the
--    scanner treats that as a read.
-- ------------------------------------------------------------------
do
  local src = TMP .. "\\unused5.lua"
  local exe = TMP .. "\\unused5.exe"
  spit(src,
       "local x = 42\n"
       .. "local function inner() return x end\n"
       .. "return inner\n")
  local code, out = run(('"%s" build "%s" -o "%s" -Wunused')
                        :format(CLUA_ABS, src, exe))
  ok(code == 0, "5. upvalue-captured local compiles cleanly",
     "exit=" .. tostring(code) .. " out=" .. out)
  -- The `local function inner` also introduces `inner`, which IS used
  -- (returned), and `x` which is captured. Neither should warn.
  ok(not out:find("warning%[Wunused%].*'x'"),
     "5. upvalue capture does NOT trigger a false positive on 'x'",
     out)
end

sh('rmdir /S /Q "' .. TMP .. '" >nul 2>&1')

if fails > 0 then
  print(string.format("[-] FAIL test-warn-unused (%d failure%s)",
                      fails, fails == 1 and "" or "s"))
  os.exit(1)
end
print("[+] PASS test-warn-unused (-W diagnostic categories + -Wunused)")
os.exit(0)
