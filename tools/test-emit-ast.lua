-- test-emit-ast.lua -- behavioural suite for `--emit=ast`.
--
-- Dumps the front-end's Proto tree as an indented tree of node shapes.
-- Higher-level than --emit=bytecode: no pc-indexed listing, just the AST
-- shape a user asking "what did the parser see?" wants.

local CLUA = "build\\bin\\clua.exe"

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP test-emit-ast (build\\bin\\clua.exe not built; run build\\build-luac.bat)")
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

local FIXTURE = TEMP .. "\\clua_t_ast.lua"
writefile(FIXTURE, [[
local function greet(who)
  local msg = "hi " .. who
  return msg
end

print(greet("world"))
return 0
]])

-- ---- 1. --emit=ast dumps a Function node line -----------------------------
do
  local code, out = run(('"%s" build "%s" --emit=ast'):format(CLUA_ABS, FIXTURE))
  ok(code == 0 and out:find("Function", 1, true) ~= nil,
     "--emit=ast dumps at least one Function node",
     ("code=%s out=%q"):format(tostring(code), out:sub(1, 300)))
end

-- ---- 2. --emit=ast dumps the inner function (`greet`) as a child -----------
do
  local code, out = run(('"%s" build "%s" --emit=ast'):format(CLUA_ABS, FIXTURE))
  -- Nested functions are indented deeper than the entry; a `+- Function`
  -- token appears at depth > 0.
  ok(code == 0 and out:find("+- Function", 1, true) ~= nil,
     "--emit=ast shows the nested greet function under the entry",
     ("code=%s out=%q"):format(tostring(code), out:sub(1, 400)))
end

-- ---- 3. --emit=ast lists a local variable name ----------------------------
do
  local code, out = run(('"%s" build "%s" --emit=ast'):format(CLUA_ABS, FIXTURE))
  -- `greet` and `msg` are local names in the fixture; either should surface.
  local has_local = out:find("local[", 1, true) ~= nil
                    or out:find("greet", 1, true) ~= nil
                    or out:find("msg", 1, true) ~= nil
  ok(code == 0 and has_local,
     "--emit=ast surfaces at least one local variable name",
     ("code=%s out=%q"):format(tostring(code), out:sub(1, 400)))
end

-- ---- 4. --emit=ast prints a K[] entry -------------------------------------
do
  local code, out = run(('"%s" build "%s" --emit=ast'):format(CLUA_ABS, FIXTURE))
  ok(code == 0 and out:find("K[", 1, true) ~= nil,
     "--emit=ast prints at least one constant slot",
     ("code=%s out=%q"):format(tostring(code), out:sub(1, 400)))
end

os.remove(FIXTURE)

if fails > 0 then os.exit(1) end
print("[+] PASS test-emit-ast (all checks)")
os.exit(0)
