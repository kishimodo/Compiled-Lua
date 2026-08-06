-- test-response-files.lua -- behavioural suite for @response-file expansion.
--
-- Any argv element that starts with `@` is treated as a path; the driver
-- reads the file and splices its whitespace-separated tokens into argv
-- in place. Matches the convention gcc / clang / MSVC use to escape the
-- Windows 8191-char command-line limit.
--
-- Skips cleanly when clua.exe hasn't been built.

local CLUA = "build\\bin\\clua.exe"

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP test-response-files (build\\bin\\clua.exe not built; run build\\build-luac.bat)")
  os.exit(0)
end

local ROOT = io.popen("cd"):read("*l")
local TEMP = os.getenv("TEMP") or "."
local CLUA_ABS = ROOT .. "\\" .. CLUA

local fails = 0
local function ok(cond, name, detail)
  if cond then
    print("[+] PASS " .. name)
  else
    fails = fails + 1
    print("[-] FAIL " .. name .. (detail and (" -- " .. tostring(detail):sub(1, 300)) or ""))
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
  f:write(s)
  f:close()
end

local FIXTURE = TEMP .. "\\clua_t_rsp.lua"
writefile(FIXTURE, 'print("rsp hi")\nreturn 0\n')

-- ---- 1. response file supplies "build <input> --emit=bytecode --emit-only" -
do
  local RSP = TEMP .. "\\clua_t_rsp.rsp"
  writefile(RSP, ('build "%s" --emit=bytecode --emit-only'):format(FIXTURE))
  local code, out = run(('"%s" @%s'):format(CLUA_ABS, RSP))
  ok(code == 0 and out:find("OP_", 1, true) ~= nil,
     "@response-file expands build + --emit=bytecode + --emit-only",
     ("code=%s out=%q"):format(tostring(code), out:sub(1, 200)))
  os.remove(RSP)
end

-- ---- 2. response file with CRLF line endings works ------------------------
do
  local RSP = TEMP .. "\\clua_t_rsp_crlf.rsp"
  writefile(RSP, "build\r\n\"" .. FIXTURE .. "\"\r\n--emit=ir\r\n--emit-only\r\n")
  local code, out = run(('"%s" @%s'):format(CLUA_ABS, RSP))
  ok(code == 0 and out:find("LC_OP_", 1, true) ~= nil,
     "@response-file handles Windows CR/LF line endings",
     ("code=%s out=%q"):format(tostring(code), out:sub(1, 200)))
  os.remove(RSP)
end

-- ---- 3. missing response file is a clear error ----------------------------
do
  local code, out = run(('"%s" @Z:\\does-not-exist.rsp build "%s" --emit-only --emit=ir')
                          :format(CLUA_ABS, FIXTURE))
  ok(code ~= 0 and out:find("response file", 1, true) ~= nil,
     "missing @response-file fails with a clear error",
     ("code=%s out=%q"):format(tostring(code), out:sub(1, 200)))
end

-- ---- 4. tokens with quoted spaces survive ---------------------------------
do
  local FIXTURE_SP = TEMP .. "\\clua_t_rsp_space.lua"
  writefile(FIXTURE_SP, 'return 0\n')
  local RSP = TEMP .. "\\clua_t_rsp_q.rsp"
  writefile(RSP, ('build "%s" --emit=ast --emit-only'):format(FIXTURE_SP))
  local code, out = run(('"%s" @%s'):format(CLUA_ABS, RSP))
  ok(code == 0,
     "@response-file with quoted-path token compiles",
     ("code=%s out=%q"):format(tostring(code), out:sub(1, 200)))
  os.remove(RSP)
  os.remove(FIXTURE_SP)
end

os.remove(FIXTURE)

if fails > 0 then os.exit(1) end
print("[+] PASS test-response-files (all checks)")
os.exit(0)
