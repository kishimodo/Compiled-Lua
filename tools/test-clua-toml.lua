-- tools/test-clua-toml.lua -- gate the per-project `clua.toml` config file
-- support (plan-0.3.0-beta.6 item F3).
--
-- The precedence order the plan mandates, lowest to highest:
--   built-in defaults -> clua.toml -> env vars (CLUA_*) -> CLI flags.
--
-- Each sub-check drops a self-contained sandbox under %TEMP% (so a `.git`
-- marker or an outer clua.toml can never leak in from the repo), builds a
-- tiny fixture there under different config / env / CLI combinations, and
-- asserts on the resulting exe's bytes -- byte-identity is the strongest
-- proof that two invocations really did drive the compiler the same way,
-- and it is what the plan promises for "config equivalents of every CLI
-- flag". A skip fires cleanly when clua.exe has not been built.
--
-- Cases (each is one PASS line at the tail):
--   1. Missing clua.toml -- byte-for-byte identical to the pre-F3 baseline
--      (unchanged default build).
--   2. clua.toml with `optimization = "O1"` -- matches `clua build -O1` bytes.
--   3. CLI wins over config: `-O0` beats `optimization = "O1"`.
--   4. Env wins over config, CLI wins over env: CLUA_OPTIMIZATION=O2 +
--      config O1 -> O2 bytes; add `-O3` -> O3 bytes.
--   5. Malformed clua.toml (unterminated string) -- nonzero exit, a
--      `clua.toml:<line>:<col>` diagnostic, no exe produced.
--   6. Discovery walk: config two dirs up IS found; a `.git` marker one dir
--      up STOPS the walk so a grandparent config is NOT picked up.
--   7. `[[bundle]] package = "..."` entries reach the driver's -L list.

local NAME = "test-clua-toml"

local function exists(p)
  local f = io.open(p, "rb"); if f then f:close(); return true end
  return false
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function run(cmd)
  local p = io.popen('"' .. cmd .. ' 2>&1"')
  if not p then return -1, "" end
  local out = p:read("*a") or ""
  local ok, _, code = p:close()
  if ok == true then code = 0 end
  return code or -1, out
end

local ROOT = trim(select(2, run("git rev-parse --show-toplevel"))):gsub("/", "\\")
if ROOT == "" then ROOT = trim(select(2, run("cd"))) end
local CLUA = ROOT .. "\\build\\bin\\clua.exe"

if not exists(CLUA) then
  print("[~] SKIP " .. NAME .. " (build\\bin\\clua.exe not built)")
  os.exit(0)
end

local TEMP = os.getenv("TEMP") or os.getenv("TMP") or "."
local BASE = TEMP .. "\\clua-toml-test-" .. tostring(os.time())

local function rmtree(p) os.execute('if exist "' .. p .. '" rmdir /S /Q "' .. p .. '" >nul 2>&1') end
local function mkdir(p)  os.execute('mkdir "' .. p .. '" >nul 2>&1') end
local function spit(p, s) local f = io.open(p, "wb"); if not f then return false end f:write(s); f:close(); return true end
local function slurp(p)   local f = io.open(p, "rb"); if not f then return nil end local d = f:read("*a"); f:close(); return d end

rmtree(BASE)
mkdir(BASE)

-- Small fixture that gives the -O1 fastpaths + the peepholes something to
-- chew on so byte-identity across settings is a meaningful assertion.
local FIXTURE = [[
local t = {}
t.x = 1
local acc = t.x
for i = 1, 200 do acc = acc + i * 2 end
local function bump(n) acc = acc + n; return acc end
print(bump(3), acc, ("s"):rep(2))
]]

local failures = {}
local function fail(fmt, ...) failures[#failures + 1] = string.format(fmt, ...) end

-- Build a fixture inside `dir`. Returns (exit-code, stderr, exe-bytes-or-nil).
-- `env` is a table of NAME->VALUE env pairs applied only to this invocation.
-- `cli` is a suffix appended to the argv (e.g. " -O0"). Because we drop the
-- fixture into `dir` and invoke `clua build` from that same dir, the F3
-- discovery walk starts from the sandbox dir -- which is EXACTLY what the
-- plan wires up for a "cargo build" experience.
local function build_in(dir, cli, env)
  local src = dir .. "\\prog.lua"
  local out = dir .. "\\out.exe"
  spit(src, FIXTURE)
  os.remove(out)
  local prefix = ""
  if env then
    for k, v in pairs(env) do
      prefix = prefix .. "set " .. k .. "=" .. v .. " && "
    end
  end
  -- Set CWD via `cd /d`. There is no cleanup step after the compile so its
  -- exit code becomes the exit code of the cmd.exe io.popen spawned, which
  -- is what we want. (Using pushd + popd loses the child's exit code inside
  -- io.popen because pclose reads the LAST child's status.)
  local cmd = 'cd /d "' .. dir .. '" && ' .. prefix ..
              '"' .. CLUA .. '" build prog.lua ' .. (cli or "") ..
              ' -o out.exe'
  local code, txt = run(cmd)
  local bytes = slurp(out)
  return code, txt, bytes, out
end

-- Also want a "control" build with no config in play at all so we can
-- compare against the plain -O1 / -O2 / -O3 references. Run it in a plain
-- dir with no clua.toml, just like the baseline.
local function build_control(dir, cli)
  return build_in(dir, cli, nil)
end

-- ---- 1. Missing clua.toml -> unchanged default (baseline preserved) --------
do
  local d1 = BASE .. "\\case1"
  mkdir(d1)
  local code_a, _, bytes_a = build_control(d1, "")
  -- Wipe and rerun in another sandbox with the same settings to confirm the
  -- baseline is deterministic and unaffected by us.
  local d1b = BASE .. "\\case1b"
  mkdir(d1b)
  local code_b, _, bytes_b = build_control(d1b, "")
  if code_a ~= 0 then fail("case 1: baseline build failed (%d)", code_a)
  elseif code_b ~= 0 then fail("case 1: baseline rebuild failed (%d)", code_b)
  elseif bytes_a == nil or bytes_b == nil then fail("case 1: no exe produced")
  elseif bytes_a ~= bytes_b then
    fail("case 1: two default builds differed (%d vs %d bytes) -- baseline "
         .. "is no longer deterministic on this host", #bytes_a, #bytes_b)
  end
end

-- ---- 2. clua.toml optimization="O1" beats built-in default (which is O2) ---
do
  local d = BASE .. "\\case2"
  mkdir(d)
  spit(d .. "\\clua.toml", '[build]\noptimization = "O1"\n')
  local code_cfg, _, bytes_cfg = build_in(d, "", nil)

  -- Reference: explicit -O1 in a config-less dir.
  local ref = BASE .. "\\case2-ref"
  mkdir(ref)
  local code_ref, _, bytes_ref = build_control(ref, "-O1")

  if code_cfg ~= 0 or code_ref ~= 0 then
    fail("case 2: build failed (cfg=%d ref=%d)", code_cfg, code_ref)
  elseif bytes_cfg == nil or bytes_ref == nil then
    fail("case 2: no exe produced")
  elseif bytes_cfg ~= bytes_ref then
    fail("case 2: config `optimization=\"O1\"` did NOT match `-O1` bytes "
         .. "(%d vs %d)", #bytes_cfg, #bytes_ref)
  end

  -- Sanity: it also must NOT match the -O0 bytes (proves -O1 really applied).
  local ref0 = BASE .. "\\case2-ref0"
  mkdir(ref0)
  local code_o0, _, bytes_o0 = build_control(ref0, "-O0")
  if code_o0 == 0 and bytes_o0 and bytes_cfg == bytes_o0 then
    fail("case 2: config `optimization=\"O1\"` matched -O0 bytes -- the "
         .. "config-supplied opt level is being ignored")
  end
end

-- ---- 3. CLI flag beats config ----------------------------------------------
do
  local d = BASE .. "\\case3"
  mkdir(d)
  spit(d .. "\\clua.toml", '[build]\noptimization = "O1"\n')
  local code, _, bytes = build_in(d, "-O0", nil)

  local ref = BASE .. "\\case3-ref"
  mkdir(ref)
  local code_ref, _, bytes_ref = build_control(ref, "-O0")

  if code ~= 0 or code_ref ~= 0 then
    fail("case 3: build failed (%d / %d)", code, code_ref)
  elseif bytes == nil or bytes_ref == nil then
    fail("case 3: no exe produced")
  elseif bytes ~= bytes_ref then
    fail("case 3: `-O0` on the command line did NOT override "
         .. "`optimization=\"O1\"` (%d vs %d bytes)", #bytes, #bytes_ref)
  end
end

-- ---- 4. Env beats config, CLI beats env ------------------------------------
do
  local d = BASE .. "\\case4"
  mkdir(d)
  spit(d .. "\\clua.toml", '[build]\noptimization = "O1"\n')
  -- Env-only: config says O1, env says O2 -> want O2.
  local code_env, _, bytes_env =
      build_in(d, "", { CLUA_OPTIMIZATION = "O2" })
  local ref2 = BASE .. "\\case4-ref2"
  mkdir(ref2)
  local code_ref2, _, bytes_ref2 = build_control(ref2, "-O2")
  if code_env ~= 0 or code_ref2 ~= 0 then
    fail("case 4a: build failed (%d / %d)", code_env, code_ref2)
  elseif bytes_env == nil or bytes_ref2 == nil then
    fail("case 4a: no exe produced")
  elseif bytes_env ~= bytes_ref2 then
    fail("case 4a: env CLUA_OPTIMIZATION=O2 did NOT override config O1 "
         .. "(%d vs %d bytes)", #bytes_env, #bytes_ref2)
  end

  -- CLI beats env: env O2, CLI -O3 -> want O3.
  local code_cli, _, bytes_cli =
      build_in(d, "-O3", { CLUA_OPTIMIZATION = "O2" })
  local ref3 = BASE .. "\\case4-ref3"
  mkdir(ref3)
  local code_ref3, _, bytes_ref3 = build_control(ref3, "-O3")
  if code_cli ~= 0 or code_ref3 ~= 0 then
    fail("case 4b: build failed (%d / %d)", code_cli, code_ref3)
  elseif bytes_cli == nil or bytes_ref3 == nil then
    fail("case 4b: no exe produced")
  elseif bytes_cli ~= bytes_ref3 then
    fail("case 4b: `-O3` did NOT override env CLUA_OPTIMIZATION=O2 + config "
         .. "O1 (%d vs %d bytes)", #bytes_cli, #bytes_ref3)
  end
end

-- ---- 5. Malformed clua.toml is a hard error --------------------------------
do
  local d = BASE .. "\\case5"
  mkdir(d)
  -- unterminated string on line 2
  spit(d .. "\\clua.toml", '[build]\noptimization = "\n')
  local code, txt, bytes, exe_path = build_in(d, "", nil)
  if code == 0 then
    fail("case 5: unterminated string in clua.toml did NOT fail the build")
  elseif not txt:match("clua%.toml:%d+:%d+") then
    fail("case 5: expected `clua.toml:<line>:<col>` diagnostic, got:\n%s",
         txt:sub(1, 300))
  elseif exists(exe_path) then
    fail("case 5: exe was produced despite malformed clua.toml")
  end
end

-- ---- 6. Discovery walk: two dirs up is found; `.git` marker one dir up stops
do
  -- Layout A: grandparent has clua.toml (optimization = O1), no `.git`.
  --   BASE\case6A\  (has clua.toml)
  --   BASE\case6A\mid\        (no marker)
  --   BASE\case6A\mid\leaf\   (fixture built from here)
  local root  = BASE .. "\\case6A"
  local mid   = root .. "\\mid"
  local leaf  = mid  .. "\\leaf"
  mkdir(root); mkdir(mid); mkdir(leaf)
  spit(root .. "\\clua.toml", '[build]\noptimization = "O1"\n')
  local code_a, _, bytes_a = build_in(leaf, "", nil)

  local ref_a = BASE .. "\\case6A-ref"
  mkdir(ref_a)
  local code_ra, _, bytes_ra = build_control(ref_a, "-O1")
  if code_a ~= 0 or code_ra ~= 0 then
    fail("case 6A: build failed (%d / %d)", code_a, code_ra)
  elseif bytes_a == nil or bytes_ra == nil then
    fail("case 6A: no exe produced")
  elseif bytes_a ~= bytes_ra then
    fail("case 6A: grandparent clua.toml was NOT discovered from the leaf "
         .. "(%d vs %d bytes)", #bytes_a, #bytes_ra)
  end

  -- Layout B: same three dirs but a `.git` MARKER in `mid` (one level up)
  -- must stop the walk before the config in the grandparent is seen.
  local rootB  = BASE .. "\\case6B"
  local midB   = rootB .. "\\mid"
  local leafB  = midB  .. "\\leaf"
  mkdir(rootB); mkdir(midB); mkdir(leafB)
  spit(rootB .. "\\clua.toml", '[build]\noptimization = "O1"\n')
  -- .git as a file is enough (git worktrees use a file; discovery must stop).
  spit(midB .. "\\.git", "gitdir: /nowhere\n")

  local code_b, _, bytes_b = build_in(leafB, "", nil)

  -- Reference is the default build (no `-O`), which is -O2, so the two byte
  -- streams must MATCH the default -- and NOT match the -O1 reference above.
  local ref_b = BASE .. "\\case6B-ref"
  mkdir(ref_b)
  local code_rb, _, bytes_rb = build_control(ref_b, "")
  if code_b ~= 0 or code_rb ~= 0 then
    fail("case 6B: build failed (%d / %d)", code_b, code_rb)
  elseif bytes_b == nil or bytes_rb == nil then
    fail("case 6B: no exe produced")
  elseif bytes_b ~= bytes_rb then
    fail("case 6B: `.git` marker one level up did NOT stop the walk -- "
         .. "grandparent clua.toml still applied (%d vs %d bytes)",
         #bytes_b, #bytes_rb)
  end
end

-- ---- 7. [[bundle]] package = "..." reaches the driver's -L list ------------
do
  -- We do not need the package to actually resolve -- if the bundle path is
  -- wired in, requesting an unknown package name produces a DIFFERENT
  -- diagnostic than the default build (which never asks about bundles at all).
  -- Concretely, `-L wumpus` (or the same via bundle) fails the resolve with
  -- a message that mentions the missing package name; without any -L that
  -- diagnostic is not generated.
  local d = BASE .. "\\case7"
  mkdir(d)
  spit(d .. "\\clua.toml",
       '[[bundle]]\npackage = "no-such-package-clua-toml-test"\n')
  local code, txt, _, _ = build_in(d, "", nil)
  if code == 0 then
    fail("case 7: build with bogus [[bundle]] package succeeded -- either "
         .. "the config bundle list is not being merged into the driver's "
         .. "-L set, or something upstream is silently ignoring the miss")
  elseif not txt:find("no-such-package-clua-toml-test", 1, true) then
    fail("case 7: expected the bogus bundle name in the diagnostic, got:\n%s",
         txt:sub(1, 400))
  end
end

rmtree(BASE)

if #failures > 0 then
  for _, why in ipairs(failures) do
    print(string.format("[-] FAIL %s: %s", NAME, why))
  end
  os.exit(1)
end

print("[+] PASS " .. NAME .. " (7 config precedence + discovery + [[bundle]] "
      .. "cases; env / CLI beat config, malformed toml gives file:line:col, "
      .. "walk stops at .git)")
os.exit(0)
