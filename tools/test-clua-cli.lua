-- test-clua-cli.lua — behavioral suite for clua.exe (the user-facing
-- toolchain front-end) + rover.exe (the CLua-compiled package manager).
--
-- Covers the streamlining contract:
--   * clua version/check/build/run subcommands
--   * RELOCATABILITY: clua build works from a non-repo CWD (exe-relative
--     toolchain discovery), output exe runs, stdout matches `luavm -i`
--   * program args reach the compiled program's `arg` global (v1 parity)
--   * the closed-world stubs answer an evading _G["lo".."ad"] with the
--     documented runtime error (AOT-CLOSEDWORLD-002) instead of parsing
--   * no temp-file litter in %TEMP% after a build
--   * lean-exe canary: a hello exe must stay well under the old 547 KB
--     (catches the parser/JIT-compiler members sneaking back into the link)
--   * rover.exe prints the rover banner and matches the script under -i
--
-- Run by tools/run-tests.lua from the repo root under luavm.exe.

local CLUA  = "build\\bin\\clua.exe"
local ROVER = "build\\bin\\rover.exe"
local LUAVM = "build\\bin\\luavm.exe"

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

if not exists(CLUA) then
  print("[~] SKIP test-clua-cli (build\\bin\\clua.exe not built; run build\\build-luac.bat)")
  os.exit(0)
end

-- repo root (CWD is the repo root when run by the runner)
local ROOT = io.popen("cd"):read("*l")
local TEMP = os.getenv("TEMP") or "."

local fails = 0
local function ok(cond, name, detail)
  if cond then
    print("[+] PASS " .. name)
  else
    fails = fails + 1
    print("[-] FAIL " .. name .. (detail and (" -- " .. detail) or ""))
  end
end

-- run a command, return exit code + combined output. The command is wrapped
-- in parentheses: cmd.exe strips the outer quotes of a line that BEGINS with
-- a quote and contains further quotes ("filename syntax is incorrect"), and
-- grouping disables that heuristic.
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

local clua_abs  = ROOT .. "\\" .. CLUA
local luavm_abs = ROOT .. "\\" .. LUAVM

-- ---- 1. version ----
do
  local code, out = run(("\"%s\" version"):format(clua_abs))
  ok(code == 0 and out:find("clua", 1, true) ~= nil, "clua version", out)
end

-- ---- 2. check: good + closed-world violator ----
do
  local good = TEMP .. "\\clua_t_good.lua"
  local bad  = TEMP .. "\\clua_t_bad.lua"
  writefile(good, 'print("ok")\n')
  writefile(bad,  'local f = load("return 1")\nprint(f())\n')
  local c1, o1 = run(("\"%s\" check \"%s\""):format(clua_abs, good))
  ok(c1 == 0 and o1:find("OK", 1, true) ~= nil, "clua check accepts a closed-world program", o1)
  local c2, o2 = run(("\"%s\" check \"%s\""):format(clua_abs, bad))
  ok(c2 ~= 0 and o2:find("closed world", 1, true) ~= nil, "clua check rejects load()", o2)
  os.remove(good); os.remove(bad)
end

-- ---- 3. build from a NON-repo CWD + run + differential vs -i ----
do
  local src = TEMP .. "\\clua_t_app.lua"
  local exe = TEMP .. "\\clua_t_app.exe"
  writefile(src, [[
local t = {}
for i = 1, 10 do t[#t+1] = i * i end
print(table.concat(t, ","))
print(("fmt %d %s %.3f"):format(42, "x", 1.5))
local mt = setmetatable({}, { __index = function(_, k) return k .. "!" end })
print(mt.hello)
]])
  -- cd into %TEMP% first: this is the relocatability regression test
  local code, out = run(("cd /d \"%s\" && \"%s\" build clua_t_app.lua -o clua_t_app.exe")
                        :format(TEMP, clua_abs))
  ok(code == 0, "clua build from a non-repo CWD", out)
  local c2, native = run(("\"%s\""):format(exe))
  local c3, oracle = run(("\"%s\" -i \"%s\""):format(luavm_abs, src))
  ok(c2 == 0 and c3 == 0 and native == oracle,
     "compiled exe output matches luavm -i",
     ("native=%q oracle=%q"):format(native:sub(1, 80), oracle:sub(1, 80)))

  -- lean-exe canary: hello-class exe must stay far below the pre-streamline
  -- 547 KB (parser + JIT compiler + symbols would add ~280 KB back)
  local f = io.open(exe, "rb")
  local size = f:seek("end"); f:close()
  ok(size < 400000, "compiled exe is lean (no parser/JIT/symbols)",
     ("size=%d"):format(size))
  os.remove(src); os.remove(exe)
end

-- ---- 4. clua run: args reach the program's arg global, exit code forwards ----
do
  local src = TEMP .. "\\clua_t_run.lua"
  writefile(src, 'print("got", arg[1], arg[2])\nos.exit(7)\n')
  local code, out = run(("\"%s\" run \"%s\" -- alpha \"b c\""):format(clua_abs, src))
  ok(out:find("got\talpha\tb c", 1, true) ~= nil, "clua run forwards program args", out)
  ok(code == 7, "clua run forwards the exit code", tostring(code))
  os.remove(src)
end

-- ---- 5. closed-world stub: evading load() errors at runtime (AOT-CLOSEDWORLD-002) ----
do
  local src = TEMP .. "\\clua_t_stub.lua"
  writefile(src, 'local f = _G["lo".."ad"]\nprint(pcall(f, "return 1"))\n')
  local code, out = run(("\"%s\" run \"%s\""):format(clua_abs, src))
  ok(code == 0 and out:find(
       "source chunk loading is disabled in a compiled CLua program", 1, true) ~= nil,
     "closed-world stub answers evading load()", out)
  os.remove(src)
end

-- ---- 6. no temp litter: clua_user_*.o cleaned up after builds ----
do
  local f = io.popen(("dir /b \"%s\\clua_user_*.o\" 2>nul"):format(TEMP))
  local litter = f:read("*a") or ""
  f:close()
  ok(litter == "", "no clua_user_*.o litter in %TEMP%", litter)
end

-- ---- 7. rover.exe: banner + differential vs the script under -i ----
if not exists(ROVER) then
  print("[~] SKIP rover checks (build\\bin\\rover.exe not built)")
else
  local rover_abs = ROOT .. "\\" .. ROVER
  local c1, o1 = run(("\"%s\""):format(rover_abs))
  ok(o1:find("rover %-%- the CLua package manager") ~= nil,
     "rover.exe prints the rover banner", o1:sub(1, 120))
  local _, o2 = run(("\"%s\" -i package-manager\\src\\luavm-pkg.lua"):format(luavm_abs))
  ok(o1 == o2, "rover.exe no-arg output matches the script under -i")
  -- one real command through the compiled pm, from the repo root (the test
  -- registry is repo-relative): `rover list` must not crash
  local c3, o3 = run(("\"%s\" list"):format(rover_abs))
  ok(c3 == 0, "rover list runs", o3:sub(1, 120))
end

if fails > 0 then os.exit(1) end
print("[+] PASS test-clua-cli (all checks)")
os.exit(0)
