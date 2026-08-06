-- test-multi-error.lua -- cross-module multi-error reporting.
--
-- Regression fixture for the diag_collector work: the resolve driver
-- must collect errors from EVERY failing module, not stop at the first
-- one. We write a main.lua that requires two side modules, each with a
-- distinct syntax error, and assert both error messages appear in the
-- captured build output.
--
-- Skips cleanly when clua.exe is not built.

local CLUA = "build\\bin\\clua.exe"

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP test-multi-error (build\\bin\\clua.exe not built)")
  os.exit(0)
end

local ROOT = io.popen("cd"):read("*l")
local TEMP = os.getenv("TEMP") or "."
local TMP  = TEMP .. "\\clua-multi-err"

local function sh(cmd)
  local ok, _, c = os.execute('"' .. cmd .. '"')
  return (ok == true) or (ok == 0) or (c == 0)
end

local function spit(path, s)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(s); f:close(); return true
end

sh('rmdir /S /Q "' .. TMP .. '" >nul 2>&1')
sh('mkdir "' .. TMP .. '" >nul 2>&1')

-- Two side modules with DIFFERENT syntax errors so the messages are
-- distinguishable, and the entry that requires both.
local ok
ok = spit(TMP .. "\\bad_a.lua",
          "-- bad_a.lua: `*` with no left operand\n" ..
          "local x = 5\n" ..
          "local y = x +* 2\n" ..
          "return y\n")
assert(ok, "spit bad_a.lua failed")

ok = spit(TMP .. "\\bad_b.lua",
          "-- bad_b.lua: unterminated string literal\n" ..
          "local msg = 'hello\n" ..
          "return msg\n")
assert(ok, "spit bad_b.lua failed")

ok = spit(TMP .. "\\main.lua",
          "local a = require 'bad_a'\n" ..
          "local b = require 'bad_b'\n" ..
          "return a, b\n")
assert(ok, "spit main.lua failed")

-- Build the entry; capture combined stdout+stderr.
local full = '"' .. ROOT .. "\\" .. CLUA .. '" build "' ..
             TMP .. '\\main.lua" --color=never -o "' .. TMP .. '\\out.exe" 2>&1'
local p, err = io.popen('"' .. full .. '"')
if not p then
  print("[-] FAIL test-multi-error: io.popen failed: " .. tostring(err))
  os.exit(1)
end
local out = p:read("*a") or ""
local _, _, code = p:close()

-- The build MUST fail (both modules broken).
if code == 0 then
  print("[-] FAIL test-multi-error: build succeeded but should have failed\n"
        .. out)
  os.exit(1)
end

-- Both filenames MUST appear in the output. That is the whole point of
-- multi-error reporting: the user sees every failing module in one go.
local has_a = out:find("bad_a", 1, true) ~= nil
local has_b = out:find("bad_b", 1, true) ~= nil
if not has_a or not has_b then
  print("[-] FAIL test-multi-error: expected both bad_a AND bad_b in the "
        .. "compiler output; got:\nhas_a=" .. tostring(has_a)
        .. " has_b=" .. tostring(has_b) .. "\n---\n" .. out)
  os.exit(1)
end

-- Sanity: the summary line notes the plural count.
if not out:find("compile error", 1, true) and
   not out:find("errors", 1, true) then
  print("[-] FAIL test-multi-error: expected a summary count line; got:\n"
        .. out)
  os.exit(1)
end

sh('rmdir /S /Q "' .. TMP .. '" >nul 2>&1')
print("[+] PASS test-multi-error (both cross-module errors collected + printed)")
os.exit(0)
