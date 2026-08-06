-- The closed world must be enforced regardless of how many constants a chunk has.
--
-- WHY THIS EXISTS. The scanner in clua/src/driver/closed_world.c originally
-- matched only OP_GETTABUP. But lcode stops emitting GETTABUP once a chunk carries
-- more than 255 constants -- the name's constant index no longer fits in the C
-- field -- and spills a global access to:
--
--     GETUPVAL  1 0    ; _ENV
--     LOADK     2      ; "load"
--     GETTABLE  1 1 2
--
-- So in ANY chunk with more than 255 constants, load / loadstring / dofile /
-- dynamic require were not rejected at all. Measured before the fix: a
-- 300-constant file calling load("return 1") compiled with exit 0 and then
-- silently evaluated to nil at run time, and one with a dynamic require compiled
-- and then failed at run time listing filesystem paths -- in a binary that has no
-- filesystem module loading. Both are worse than the compile error the user should
-- have received.
--
-- The pairs below are the point of the test: each banned construct is compiled
-- BOTH in a small chunk and in one padded past the 255-constant threshold, and
-- both must be rejected. A test that only used small chunks is what let this
-- through.

local NAME = "test-closed-world"
local failures = {}
local function fail(fmt, ...) failures[#failures + 1] = string.format(fmt, ...) end

local function run(cmd)
  local p = io.popen('"' .. cmd .. ' 2>&1"')
  if not p then return -1, "" end
  local out = p:read("*a") or ""
  local ok, _, code = p:close()
  return (ok == true) and 0 or (code or 1), out
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
local ROOT = trim(select(2, run("git rev-parse --show-toplevel"))):gsub("/", "\\")
local CLUA = ROOT .. "\\build\\bin\\clua.exe"
local TMP  = (os.getenv("TEMP") or ".") .. "\\clua-cw-" .. tostring(os.time())

local function exists(p)
  local f = io.open(p, "rb"); if f then f:close(); return true end; return false
end
if not exists(CLUA) then
  print("[~] SKIP " .. NAME .. " (build\\bin\\clua.exe not built)")
  os.exit(0)
end
os.execute('mkdir "' .. TMP .. '" >nul 2>nul')

-- 300 distinct string constants in one table constructor: one local, enough
-- constants to push the chunk past the GETTABUP threshold.
local pad
do
  local parts = {}
  for i = 0, 299 do parts[#parts + 1] = ('"c%d"'):format(i) end
  pad = "local _pad = { " .. table.concat(parts, ", ") .. " }\n"
end

local function compile(src, tag)
  local path = TMP .. "\\" .. tag .. ".lua"
  local f = io.open(path, "wb")
  if not f then fail("cannot write %s", path); return nil end
  f:write(src); f:close()
  local out = TMP .. "\\" .. tag .. ".exe"
  os.remove(out)
  local code, txt = run('"' .. CLUA .. '" build "' .. path .. '" -o "' .. out .. '"')
  return code, txt, out
end

-- Each entry: a label, the offending snippet, and a fragment its message must
-- contain so a rejection for the WRONG reason is not silently accepted.
local banned = {
  { "load",        'local f = load("return 1") print(f)',            "load()" },
  { "loadstring",  'print(loadstring)',                             "loadstring()" },
  { "dofile",      'print(dofile("x.lua"))',                        "dofile()" },
  { "dynrequire",  'local n = "js" .. "on" print(require(n))',      "require" },
  { "stringdump",  'print(string.dump(print))',                     "dump" },
}

for _, case in ipairs(banned) do
  local label, snippet, want = case[1], case[2], case[3]
  for _, size in ipairs({ "small", "big" }) do
    local src = (size == "big" and pad or "") .. snippet .. "\n"
    local tag = label .. "_" .. size
    local code, txt, out = compile(src, tag)
    if code == nil then goto continue end
    if code == 0 then
      fail("%s ACCEPTED a %s chunk containing %s -- the closed world is not "
           .. "enforced at this constant count", NAME, size, label)
    elseif not txt:find(want, 1, true) then
      fail("%s rejected the %s %s chunk but the message does not mention %q: %s",
           NAME, size, label, want, trim(txt):sub(1, 100))
    end
    if exists(out) then
      fail("%s produced an executable for the rejected %s %s chunk", NAME, size, label)
    end
    ::continue::
  end
end

-- The other half of the contract: a large chunk that does nothing banned must
-- still compile. Over-rejecting here would be just as bad, and the register
-- tracking that closes the hole is deliberately biased toward over-detection.
for _, case in ipairs({
  { "big_globals", pad .. 'Acc = 0\nfor i = 1, 10 do Acc = Acc + i end\nprint(Acc)\n' },
  { "big_literal_require", pad .. 'local j = require "json"\nprint(type(j))\n' },
  -- "load" as an ordinary string, not a call: a table key, a message. This is the
  -- shape most likely to be caught by an over-eager constant scan.
  { "big_load_as_string", pad .. 'local t = { load = 1, dofile = 2 }\nprint(t.load, t.dofile)\n' },
}) do
  local label, src = case[1], case[2]
  local code, txt = compile(src, label)
  if code ~= 0 then
    fail("%s REJECTED a legitimate large chunk (%s): %s", NAME, label,
         trim(txt or ""):sub(1, 120))
  end
end

-- And the flagship program itself, which has more than 255 constants and touches
-- globals, must keep compiling.
do
  local out = TMP .. "\\rover.exe"
  local code, txt = run('"' .. CLUA .. '" build "' .. ROOT .. '\\rover\\src\\rover.lua" -o "' .. out .. '"')
  if code ~= 0 then
    fail("%s REJECTED rover/src/rover.lua: %s", NAME, trim(txt or ""):sub(1, 120))
  end
end

os.execute('rmdir /s /q "' .. TMP .. '" >nul 2>nul')

if #failures > 0 then
  for _, why in ipairs(failures) do print("[-] FAIL " .. NAME .. ": " .. why) end
  os.exit(1)
end
print("[+] PASS " .. NAME
      .. " (5 banned constructs rejected at both constant counts, 3 legitimate "
      .. "large chunks and rover still compile)")
os.exit(0)
