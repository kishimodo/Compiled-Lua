-- test-explain.lua -- `clua explain <code>` error database.
--
-- Asserts:
--   * `clua explain E001` succeeds and includes the E001 title/content
--   * a lowercase code is accepted (canonicalised to uppercase)
--   * an unknown code exits non-zero with a "no explanation for" message
--   * a malformed code (leading digit, etc.) exits with usage-style error
--
-- Skips when clua.exe is not built.

local CLUA = "build\\bin\\clua.exe"

local function exists(p)
  local f = io.open(p, "rb"); if f then f:close(); return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP test-explain (build\\bin\\clua.exe not built)")
  os.exit(0)
end

local ROOT = io.popen("cd"):read("*l")

local function run(args)
  local full = '"' .. ROOT .. "\\" .. CLUA .. '" ' .. args .. ' 2>&1'
  local p = io.popen('"' .. full .. '"')
  if not p then return "", -1 end
  local out = p:read("*a") or ""
  local _, _, code = p:close()
  return out, (code or 0)
end

local fails = 0
local function check(cond, name, detail)
  if cond then
    print("[+] PASS " .. name)
  else
    fails = fails + 1
    print("[-] FAIL " .. name .. (detail and (" -- " .. detail) or ""))
  end
end

-- 1. E001 exists, exits 0, contains "syntax error".
do
  local out, code = run("explain E001")
  check(code == 0, "explain E001 exits 0",
        "code=" .. tostring(code) .. " out=" .. out:sub(1, 200))
  check(out:find("syntax error", 1, true) ~= nil,
        "explain E001 mentions syntax error",
        "out=" .. out:sub(1, 200))
  check(out:find("E001", 1, true) ~= nil,
        "explain E001 includes the code in the page",
        "out=" .. out:sub(1, 200))
end

-- 2. Lowercase code accepted.
do
  local out, code = run("explain e002")
  check(code == 0, "explain e002 accepts lowercase",
        "code=" .. tostring(code) .. " out=" .. out:sub(1, 200))
  check(out:find("nil value", 1, true) ~= nil,
        "explain e002 shows the E002 doc",
        "out=" .. out:sub(1, 200))
end

-- 3. Unknown code -> non-zero exit + "no explanation" message.
do
  local out, code = run("explain E999")
  check(code ~= 0, "explain E999 exits non-zero (unknown code)",
        "code=" .. tostring(code))
  check(out:find("no explanation", 1, true) ~= nil,
        "explain E999 prints 'no explanation'",
        "out=" .. out:sub(1, 200))
end

-- 4. Malformed code (starts with digit) -> non-zero exit.
do
  local _, code = run("explain 001E")
  check(code ~= 0, "explain 001E rejects malformed code",
        "code=" .. tostring(code))
end

-- 5. Missing argument -> non-zero exit.
do
  local out, code = run("explain")
  check(code ~= 0, "explain (no argument) exits non-zero",
        "code=" .. tostring(code))
  check(out:find("missing code", 1, true) ~= nil or
        out:find("explain", 1, true) ~= nil,
        "explain (no argument) prints a hint",
        "out=" .. out:sub(1, 200))
end

if fails > 0 then
  print("[-] FAIL test-explain: " .. tostring(fails) .. " assertion(s) failed")
  os.exit(1)
end
print("[+] PASS test-explain (clua explain <code> reads docs/errors/*.md)")
os.exit(0)
