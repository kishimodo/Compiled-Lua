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

-- snapshot pre-existing clua_user_*.o (e.g. a developer's --keep-temps
-- leftovers) so the litter check below only flags files THIS suite created
local function temp_objs()
  local f = io.popen(("dir /b \"%s\\clua_user_*.o\" 2>nul"):format(TEMP))
  local set = {}
  for line in f:lines() do set[line] = true end
  f:close()
  return set
end
local baseline_objs = temp_objs()

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

  -- lean-exe canary: a hello-class exe is ~182 KB after the diet (no parser,
  -- no JIT compiler, no FFI, no winpthread, no bytecode interpreter for
  -- debug-free programs, gc-sections, stripped). 230 KB headroom catches any
  -- of those chunks creeping back into the link.
  local f = io.open(exe, "rb")
  local size = f:seek("end"); f:close()
  ok(size < 230000, "compiled exe is lean (no parser/JIT/FFI/pthread/interp)",
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

-- ---- 5b. interpreter strip: a debug-EVADING program gets the bounded
-- divergence error instead of silently lacking hooks (AOT-NODEBUG-001).
-- The error fires inside the call-hook machinery (the hook closure is the
-- first thing dispatched through luaV_execute), so it is UNCAUGHT: the exe
-- fails fast at the sethook site with exit 1 + the clua error banner. ----
do
  local src = TEMP .. "\\clua_t_evade.lua"
  writefile(src, [[
local d = _G["de" .. "bug"]
d.sethook(function() end, "c")
print(pcall(function() return 1 end))
]])
  local code, out = run(("\"%s\" run \"%s\""):format(clua_abs, src))
  ok(code ~= 0 and out:find("bytecode interpreter unavailable", 1, true) ~= nil,
     "no-interp exe answers evading debug.sethook (fail-fast, exit~=0)", out)
  os.remove(src)
end

-- ---- 6. no temp litter: clua_user_*.o cleaned up after this suite's builds ----
do
  local litter = {}
  for name in pairs(temp_objs()) do
    if not baseline_objs[name] then litter[#litter + 1] = name end
  end
  ok(#litter == 0, "no new clua_user_*.o litter in %TEMP%",
     table.concat(litter, ", "))
end

-- ---- 6b. builtin-package requires fail LOUDLY at compile time (the AOT
-- pipeline does not bundle the in-tree builtin packages yet; a silent
-- compile + runtime failure would be a broken-exe trap) ----
do
  local src = TEMP .. "\\clua_t_builtin.lua"
  writefile(src, 'local json = require "json"\nprint(json.encode({1,2}))\n')
  local code, out = run(("\"%s\" check \"%s\""):format(clua_abs, src))
  ok(code ~= 0 and out:find("builtin package", 1, true) ~= nil,
     "builtin-package require is a loud compile error", out)
  os.remove(src)
end

-- ---- 6c. the full toolchain loop: rover install -> clua build -> run.
-- CLUA_HOME points at an isolated temp store (toolchain discovery falls
-- through to exe-relative when CLUA_HOME has no lib\) ----
do
  local home = TEMP .. "\\clua_t_home"
  local proj = TEMP .. "\\clua_t_proj"
  run(("rmdir /s /q \"%s\" 2>nul & rmdir /s /q \"%s\" 2>nul"):format(home, proj))
  run(("mkdir \"%s\" & mkdir \"%s\""):format(home, proj))
  writefile(proj .. "\\app.lua", 'local g = require "greet"\nprint(g.hello("toolchain"))\n')
  local rover_abs2 = ROOT .. "\\build\\bin\\rover.exe"
  local c1, o1 = run(("set \"CLUA_HOME=%s\" && \"%s\" install greet"):format(home, rover_abs2))
  ok(c1 == 0 and o1:find("installed 'greet'", 1, true) ~= nil,
     "rover installs into an isolated CLUA_HOME store", o1:sub(1, 160))
  local c2, o2 = run(("set \"CLUA_HOME=%s\" && cd /d \"%s\" && \"%s\" build app.lua")
                     :format(home, proj, clua_abs))
  ok(c2 == 0, "clua build resolves the rover-installed package", o2)
  local c3, o3 = run(("\"%s\\app.exe\""):format(proj))
  ok(c3 == 0 and o3:find("Hello, toolchain!", 1, true) ~= nil,
     "compiled exe runs the bundled package", o3)
  run(("rmdir /s /q \"%s\" 2>nul & rmdir /s /q \"%s\" 2>nul"):format(home, proj))
end

-- ---- 6d. a rover-INSTALLED package shadows a same-named builtin: the
-- install is explicit user intent, so `require "json"` must resolve to the
-- installed copy (and compile) instead of hitting the builtin gate ----
do
  local home = TEMP .. "\\clua_t_home2"
  local reg  = TEMP .. "\\clua_t_reg2"
  local proj = TEMP .. "\\clua_t_proj2"
  run(("rmdir /s /q \"%s\" 2>nul & rmdir /s /q \"%s\" 2>nul & rmdir /s /q \"%s\" 2>nul")
      :format(home, reg, proj))
  run(("mkdir \"%s\\json\" & mkdir \"%s\""):format(reg, proj))
  writefile(reg .. "\\json\\init.lua",
            'local M = {}\nfunction M.marker() return "installed-json" end\nreturn M\n')
  writefile(reg .. "\\json\\package.lua",
            'return { name = "json", version = "1.0.0", description = "shadow test" }\n')
  writefile(proj .. "\\app.lua", 'local j = require "json"\nprint(j.marker())\n')
  local rover_abs2 = ROOT .. "\\build\\bin\\rover.exe"
  local c1, o1 = run(("set \"CLUA_HOME=%s\" && \"%s\" install json --registry \"%s\"")
                     :format(home, rover_abs2, reg))
  ok(c1 == 0, "rover installs a builtin-named package", o1:sub(1, 160))
  local c2, o2 = run(("set \"CLUA_HOME=%s\" && cd /d \"%s\" && \"%s\" build app.lua")
                     :format(home, proj, clua_abs))
  local c3, o3 = run(("\"%s\\app.exe\""):format(proj))
  ok(c2 == 0 and c3 == 0 and o3:find("installed-json", 1, true) ~= nil,
     "installed package shadows the builtin in clua build",
     ("build=%s run=%s"):format(o2:sub(1, 120), o3:sub(1, 60)))
  run(("rmdir /s /q \"%s\" 2>nul & rmdir /s /q \"%s\" 2>nul & rmdir /s /q \"%s\" 2>nul")
      :format(home, reg, proj))
end

-- ---- 7. rover.exe: banner + differential vs the script under -i ----
if not exists(ROVER) then
  print("[~] SKIP rover checks (build\\bin\\rover.exe not built)")
else
  local rover_abs = ROOT .. "\\" .. ROVER
  local c1, o1 = run(("\"%s\""):format(rover_abs))
  ok(o1:find("rover %-%- the CLua package manager") ~= nil,
     "rover.exe prints the rover banner", o1:sub(1, 120))
  -- the prebuilt exe may lag the script's help text between rebuilds; the
  -- identity (banner) line is the stable differential anchor.
  local _, o2 = run(("\"%s\" -i rover\\src\\rover.lua"):format(luavm_abs))
  local function banner(s) return (s:match("^[^\r\n]*")) end
  ok(banner(o1) == "rover -- the CLua package manager" and banner(o1) == banner(o2),
     "rover.exe and the script agree on the rover banner line")
  -- one real command through the compiled pm, from the repo root (the test
  -- registry is repo-relative): `rover list` must not crash
  local c3, o3 = run(("\"%s\" list"):format(rover_abs))
  ok(c3 == 0, "rover list runs", o3:sub(1, 120))
end

if fails > 0 then os.exit(1) end
print("[+] PASS test-clua-cli (all checks)")
os.exit(0)
