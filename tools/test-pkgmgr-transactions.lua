-- Rover transaction-safety test (P0 slice of the 2026-07-25 concurrency audit).
--
-- Rover is a multi-process program pointed at ONE global store, so its store
-- mutations have to be transactional. This suite covers the four guarantees:
--
--   A) atomic metadata publication -- a FAILED publish keeps the previous file
--      byte-for-byte and leaves no temporary file behind (exercised with a
--      read-only destination, which is exactly how AV/ACL/OneDrive failures
--      surface on Windows);
--   B) CONCURRENT installs of the same name@version from several processes --
--      all must succeed, agree on the content hash, and leave one complete
--      immutable version directory plus a complete flat view (no partial tree,
--      no leftover staging, no leaked lock);
--   C) the flat compatibility view is RECURSIVELY complete and cannot retain a
--      file that a newer version removed (the old non-recursive `xcopy` over
--      stale content did both wrong);
--   D) package locks have BOUNDED waits with owner diagnostics, and a lock
--      abandoned by a dead rover is broken rather than waited on forever.
--
-- Everything runs against an ISOLATED CLUA_HOME under %TEMP%; the developer's
-- real store is never touched. Run from the repo root by clua-interp.exe.

local function abscwd()
  local p = io.popen("cd"); if not p then return "." end
  local d = p:read("*a") or ""; p:close(); return (d:gsub("%s+$", ""))
end
local ROOT = abscwd()
local CLUA = ROOT .. "\\build\\bin\\clua-interp.exe"
local PKG  = ROOT .. "\\rover\\src\\rover.lua"
local REG  = ROOT .. "\\rover\\registry-test"          -- has mfpkg (init+helper)
local TEMP = os.getenv("TEMP") or "."
local HOME = TEMP .. "\\rover-tx-home"                 -- isolated CLUA_HOME
local WORK = TEMP .. "\\rover-tx-work"                 -- scratch: bats, logs, registry
local PROJ = TEMP .. "\\rover-tx-proj"                 -- project dir for `add`
local STORE = HOME .. "\\packages"

local function sh(cmd) local ok, _, c = os.execute('"' .. cmd .. '"'); return (ok == true) or (ok == 0) or (c == 0) end
local function run(cmd)                                -- exit code + combined output
  local f = io.popen("(" .. cmd .. ") 2>&1")
  if not f then return -1, "" end
  local out = f:read("*a") or ""
  local okc, _, code = f:close()
  if okc == true then code = 0 end
  return code or -1, out
end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function spit(p, s)
  local dir = p:match("^(.*)\\[^\\]+$")
  if dir then sh('if not exist "' .. dir .. '" mkdir "' .. dir .. '" >nul 2>&1') end
  local f = io.open(p, "wb"); if not f then return false end
  f:write(s); f:close(); return true
end
local function isdir(p) return sh('if exist "' .. p .. '\\*" (exit 0) else (exit 1) >nul 2>&1') end
local function subdirs(p)
  local out, h = {}, io.popen('dir /b /ad "' .. p .. '" 2>nul')
  if not h then return out end
  for line in h:lines() do if line ~= "" then out[#out + 1] = line end end
  h:close(); return out
end
local function nap() sh('ping -n 2 127.0.0.1 >nul 2>&1') end
local function cleanup()
  sh('attrib -R /S "' .. WORK .. '\\*" >nul 2>&1')
  for _, d in ipairs({ HOME, WORK, PROJ }) do sh('rmdir /S /Q "' .. d .. '" >nul 2>&1') end
end
local function fail(m) print("[-] FAIL test-pkgmgr-transactions: " .. m); cleanup(); os.exit(1) end
local function flat1(s) return (tostring(s):gsub("%s+", " ")) end

-- rover against the ISOLATED store, with ROVER_REGISTRY cleared so the
-- developer's environment cannot leak in. `extra` prefixes more `set` clauses.
local function rover(args, extra, cwd)
  local pre = 'set "CLUA_HOME=' .. HOME .. '" && set "ROVER_REGISTRY=" && ' .. (extra or "")
  local cd  = cwd and ('cd /d "' .. cwd .. '" && ') or ""
  return run(cd .. pre .. '"' .. CLUA .. '" -i "' .. PKG .. '" ' .. args)
end

cleanup()
sh('mkdir "' .. HOME .. '" >nul 2>&1')
sh('mkdir "' .. WORK .. '" >nul 2>&1')
sh('mkdir "' .. PROJ .. '" >nul 2>&1')

----------------------------------------------------------------------
-- A) write_atomic: publish, then a FAILED publish must preserve the old file.
--
-- The failure is induced the way Windows really produces it: a read-only
-- destination, which MoveFileEx refuses to replace. The contract under test is
-- "the destination keeps its previous bytes AND no temp file is left behind".
----------------------------------------------------------------------
do
  local box = WORK .. "\\atomic"
  sh('mkdir "' .. box .. '" >nul 2>&1')
  local driver = WORK .. "\\atomic-driver.lua"
  spit(driver, [==[
dofile("rover/src/rover.lua")
local M = _G.ROVER_PKG
local function ok(cond, label) if not cond then print("FAILCASE:" .. label); os.exit(7) end end
for _, k in ipairs({ "write_atomic", "shell_safe_path", "acquire_pkg_lock",
                     "release_pkg_lock", "open_staging", "close_staging",
                     "publish_flat_view", "is_version_segment" }) do
  ok(type(M[k]) == "function", "export-" .. k)
end
local box = os.getenv("ROVER_TX_BOX")
local dst = box .. "\\manifest.lua"
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function tmps()
  local n, h = 0, io.popen('dir /b "' .. box .. '\\.rover-tmp-*" 2>nul')
  if h then for line in h:lines() do if line ~= "" then n = n + 1 end end h:close() end
  return n
end

-- 1. a normal publish writes the exact bytes and leaves no temp behind
local w, werr = M.write_atomic(dst, "return { generation = 1 }\n")
ok(w, "first-publish:" .. tostring(werr))
ok(slurp(dst) == "return { generation = 1 }\n", "first-content")
ok(tmps() == 0, "first-leftover-temp")

-- 2. replacing an existing file is fine (this is the common path)
ok(M.write_atomic(dst, "return { generation = 2 }\n"), "second-publish")
ok(slurp(dst) == "return { generation = 2 }\n", "second-content")

-- 3. FAILED publish: a read-only destination cannot be replaced. The previous
--    file must survive intact and the temporary file must be cleaned up.
os.execute('attrib +R "' .. dst .. '" >nul 2>&1')
local bad, err = M.write_atomic(dst, "return { generation = 3 }\n")
os.execute('attrib -R "' .. dst .. '" >nul 2>&1')
ok(bad == false, "readonly-publish-should-fail")
ok(type(err) == "string" and err:find("intact", 1, true), "readonly-error-mentions-intact:" .. tostring(err))
ok(slurp(dst) == "return { generation = 2 }\n", "previous-file-must-survive")
ok(tmps() == 0, "failed-publish-left-a-temp-file")

-- 4. a path carrying cmd metacharacters is refused outright, not quoted
ok(M.write_atomic(box .. '\\ev"&calc&".lua', "x") == false, "metachar-path-refused")
ok(M.shell_safe_path("C:\\Users\\a b\\clua") == true, "spaces-are-fine")
ok(M.shell_safe_path("C:\\x&calc") == false, "ampersand-rejected")

-- 5. the version-segment predicate the flat publisher and tree_hash share
ok(M.is_version_segment("1.0.0") and M.is_version_segment("v2.10"), "version-segment-yes")
ok(not M.is_version_segment("sub") and not M.is_version_segment("lib"), "version-segment-no")
print("ATOMIC_OK")
]==])
  local c, out = run('set "ROVER_PKG_TEST=1" && set "ROVER_TX_BOX=' .. box .. '" && "'
                     .. CLUA .. '" -i "' .. driver .. '"')
  if c ~= 0 or not out:match("ATOMIC_OK") then
    fail("atomic publication checks failed: " .. flat1(out))
  end
end

----------------------------------------------------------------------
-- B) CONCURRENT installs of the same package from separate processes.
--
-- Before this slice each process wrote straight into <store>\<name>\<version>
-- after deleting it, so a second rover could observe (or `require`) a tree that
-- was mid-copy. Now the copy happens in private staging and only a rename
-- publishes it, under a per-package lock.
----------------------------------------------------------------------
local WORKERS = 4
do
  local launcher = WORK .. "\\launch.bat"
  local lines = { "@echo off" }
  for i = 1, WORKERS do
    local bat  = WORK .. "\\w" .. i .. ".bat"
    local log  = WORK .. "\\w" .. i .. ".log"
    local done = WORK .. "\\w" .. i .. ".done"
    spit(bat, table.concat({
      "@echo off",
      'set "CLUA_HOME=' .. HOME .. '"',
      'set "ROVER_REGISTRY="',
      'cd /d "' .. PROJ .. '"',
      '"' .. CLUA .. '" -i "' .. PKG .. '" install mfpkg "' .. REG .. '" > "' .. log .. '" 2>&1',
      -- redirect FIRST: `echo %ERRORLEVEL%> file` would parse a leading digit
      -- as a stream handle.
      '> "' .. done .. '" echo %ERRORLEVEL%',
    }, "\r\n") .. "\r\n")
    -- the child cmd echoes a prompt to the shared console when it exits, so
    -- silence the whole child; the worker records its result in <log>/<done>.
    lines[#lines + 1] = 'start "" /B cmd /c ""' .. bat .. '" >nul 2>&1"'
  end
  spit(launcher, table.concat(lines, "\r\n") .. "\r\n")
  if not os.execute('"' .. launcher .. '"') then fail("could not launch the concurrent installers") end

  -- bounded wait for every worker (the suite must never hang on a wedged child)
  local finished = false
  for _ = 1, 90 do
    finished = true
    for i = 1, WORKERS do
      if not slurp(WORK .. "\\w" .. i .. ".done") then finished = false end
    end
    if finished then break end
    nap()
  end
  if not finished then fail("concurrent installers did not all finish within the deadline") end

  local tree
  for i = 1, WORKERS do
    local rc  = (slurp(WORK .. "\\w" .. i .. ".done") or ""):match("%d+")
    local log = slurp(WORK .. "\\w" .. i .. ".log") or ""
    if rc ~= "0" then
      fail("concurrent installer " .. i .. " exited " .. tostring(rc) .. ": " .. flat1(log))
    end
    if not log:find("installed 'mfpkg'", 1, true) then
      fail("concurrent installer " .. i .. " did not report an install: " .. flat1(log))
    end
    local t = log:match("tree sha256%s*=%s*(%x+)")
    if not t then fail("installer " .. i .. " printed no tree hash: " .. flat1(log)) end
    if tree and t ~= tree then
      fail("concurrent installers disagree on the content hash: " .. tree .. " vs " .. t)
    end
    tree = t
  end

  -- the published version directory is complete, and so is the flat view
  for _, rel in ipairs({ "1.0.0\\init.lua", "1.0.0\\helper.lua", "init.lua", "helper.lua" }) do
    if not slurp(STORE .. "\\mfpkg\\" .. rel) then
      fail("concurrent installs left an incomplete store: missing mfpkg\\" .. rel)
    end
  end
  -- exactly ONE version directory: nobody published a duplicate or a partial one
  local vers = {}
  for _, d in ipairs(subdirs(STORE .. "\\mfpkg")) do vers[#vers + 1] = d end
  if #vers ~= 1 or vers[1] ~= "1.0.0" then
    fail("expected exactly one version dir (1.0.0), got: " .. table.concat(vers, ", "))
  end
  -- the manifest agrees with the store, so `verify` must pass
  local c, out = rover("verify mfpkg", nil, ROOT)
  if c ~= 0 or not out:find("OK", 1, true) then
    fail("verify failed after concurrent installs: " .. flat1(out))
  end
  -- and nothing was leaked: no staging left over, no orphaned lock
  local leftover = subdirs(STORE .. "\\.staging")
  if #leftover > 0 then
    fail("staging leaked after concurrent installs: " .. table.concat(leftover, ", "))
  end
  if isdir(STORE .. "\\.locks\\mfpkg.lock") then
    fail("the mfpkg package lock was not released")
  end
end

----------------------------------------------------------------------
-- C) the flat compatibility view: recursively complete, and never stale.
--
-- fvpkg 1.0.0 ships a NESTED file (sub\nested.lua) plus extra.lua; 2.0.0 drops
-- both. The old publisher used a non-recursive `xcopy /Y "<vdir>\*"` onto
-- whatever was already there, so it (a) never copied sub\nested.lua and
-- (b) never removed extra.lua when switching to 2.0.0. Either defect makes
-- tree_hash(flat) disagree with the manifest, so `verify` is the sharpest
-- assertion available -- checked alongside the individual files.
----------------------------------------------------------------------
do
  local REG2 = WORK .. "\\reg"
  local function ver(v, files)
    for rel, body in pairs(files) do
      if not spit(REG2 .. "\\fvpkg\\" .. v .. "\\" .. rel, body) then
        fail("could not build the fvpkg test registry")
      end
    end
  end
  ver("1.0.0", {
    ["init.lua"]        = 'local M = {}\nM.version = "1.0.0"\nreturn M\n',
    ["package.lua"]     = 'return {\n  name = "fvpkg",\n  version = "1.0.0",\n  description = "flat view",\n}\n',
    ["extra.lua"]       = "return 'extra-1'\n",
    ["sub\\nested.lua"] = "return 'nested-1'\n",
  })
  ver("2.0.0", {
    ["init.lua"]    = 'local M = {}\nM.version = "2.0.0"\nreturn M\n',
    ["package.lua"] = 'return {\n  name = "fvpkg",\n  version = "2.0.0",\n  description = "flat view",\n}\n',
  })

  local FLAT = STORE .. "\\fvpkg"
  local function install(v)
    local c, out = rover('add fvpkg "' .. REG2 .. '" "' .. v .. '"', nil, PROJ)
    if c ~= 0 then fail("add fvpkg " .. v .. " exited " .. c .. ": " .. flat1(out)) end
  end
  local function verify_flat(v)
    local c, out = rover("verify fvpkg", nil, ROOT)
    if c ~= 0 or not out:find("OK", 1, true) then
      fail("verify fvpkg failed at v" .. v .. " -- the flat view does not match the " ..
           "published version: " .. flat1(out))
    end
  end

  -- 1.0.0: the NESTED file must be published (the non-recursive copy missed it)
  install("1.0.0")
  if not (slurp(FLAT .. "\\init.lua") or ""):find('"1.0.0"', 1, true) then
    fail("flat init.lua is not v1.0.0 after installing 1.0.0")
  end
  if not slurp(FLAT .. "\\extra.lua") then fail("flat view is missing extra.lua at v1.0.0") end
  if not slurp(FLAT .. "\\sub\\nested.lua") then
    fail("flat view is missing the NESTED sub\\nested.lua at v1.0.0 (not recursively complete)")
  end
  verify_flat("1.0.0")

  -- 2.0.0: the files 2.0.0 dropped must be GONE from the flat view
  install("2.0.0")
  if not (slurp(FLAT .. "\\init.lua") or ""):find('"2.0.0"', 1, true) then
    fail("flat init.lua is not v2.0.0 after installing 2.0.0")
  end
  if slurp(FLAT .. "\\extra.lua") then
    fail("flat view kept extra.lua, which v2.0.0 removed")
  end
  if slurp(FLAT .. "\\sub\\nested.lua") then
    fail("flat view kept sub\\nested.lua, which v2.0.0 removed")
  end
  verify_flat("2.0.0")

  -- the immutable version directories are untouched by flat-view churn
  for _, rel in ipairs({ "1.0.0\\extra.lua", "1.0.0\\sub\\nested.lua", "2.0.0\\init.lua" }) do
    if not slurp(FLAT .. "\\" .. rel) then fail("version dir damaged: missing fvpkg\\" .. rel) end
  end

  -- going back restores the complete 1.0.0 view
  install("1.0.0")
  if not slurp(FLAT .. "\\sub\\nested.lua") then
    fail("downgrading to 1.0.0 did not restore the nested file")
  end
  verify_flat("1.0.0 (again)")
end

----------------------------------------------------------------------
-- D) package locks: bounded wait with owner diagnostics, and stale recovery.
----------------------------------------------------------------------
do
  local LK = STORE .. "\\.locks\\mfpkg.lock"
  local function hold(at)
    sh('mkdir "' .. LK .. '" >nul 2>&1')
    spit(LK .. "\\owner.lua", string.format(
      'return { proc = %q, host = %q, at = %d, op = %q }\n',
      "test-holder-9999", "TESTHOST", at, "pretend install"))
  end
  local function drop() sh('rmdir /S /Q "' .. LK .. '" >nul 2>&1') end

  -- D1: a lock held by a LIVE owner is waited on, but only until the deadline,
  --     and the failure names the lock path and its owner.
  drop(); hold(os.time())
  local c, out = rover('install mfpkg "' .. REG .. '"',
                       'set "ROVER_LOCK_TIMEOUT=1" && set "ROVER_LOCK_STALE=99999" && ', ROOT)
  if c == 0 then drop(); fail("install should not succeed while the package lock is held") end
  for _, want in ipairs({ "timed out after 1s", "'mfpkg' package lock",
                          "test-holder-9999", "TESTHOST", "pretend install" }) do
    if not out:find(want, 1, true) then
      drop(); fail("lock-timeout diagnostic lacks " .. want .. ": " .. flat1(out))
    end
  end
  if not out:find(LK, 1, true) then
    drop(); fail("lock-timeout diagnostic does not name the lock path: " .. flat1(out))
  end

  -- D2: a lock abandoned by a dead rover (owner record older than the staleness
  --     window) is broken instead of blocking forever.
  drop(); hold(os.time() - 100000)
  c, out = rover('install mfpkg "' .. REG .. '"',
                 'set "ROVER_LOCK_TIMEOUT=30" && set "ROVER_LOCK_STALE=600" && ', ROOT)
  if c ~= 0 then drop(); fail("a stale package lock should be broken, but install failed: " .. flat1(out)) end
  if isdir(LK) then drop(); fail("the lock was not released after the stale-break install") end
end

cleanup()
print("[+] PASS test-pkgmgr-transactions (atomic publish preserves the old file; "
      .. WORKERS .. " concurrent same-version installs agree and publish one complete "
      .. "tree; flat view is recursively complete and drops removed files; package "
      .. "locks are bounded, diagnostic, and stale-recoverable)")
os.exit(0)
