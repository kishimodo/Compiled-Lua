-- Foreign-package (GitHub) + official-registry-default test for rover
-- (rover/src/rover.lua). Covers:
--   * parse_github_source / github_pkg_name URL parsing + name derivation
--     (via the $ROVER_PKG_TEST export hook),
--   * default_registry() precedence: $ROVER_REGISTRY > rover\registry (dev
--     checkout) > the OFFICIAL remote registry URL (no network touched),
--   * an OFFLINE foreign-install end-to-end via the $ROVER_FOREIGN_TARBALL
--     test hook (a locally tar-built .tgz stands in for the codeload
--     download): install + WARNING text, list marks [FOREIGN] + warns,
--     verify warns + passes, tamper -> verify fails, package.lua `entry`
--     form, missing-init failure, and `add` recording source in toml + lock.
-- Run from the repo root by clua-interp.exe. No network access.

local function abscwd()
  local p = io.popen("cd"); if not p then return "." end
  local d = p:read("*a") or ""; p:close(); return (d:gsub("%s+$", ""))
end
local ROOT  = abscwd()
local CLUA = ROOT .. "\\build\\bin\\clua-interp.exe"
local PKG   = ROOT .. "\\rover\\src\\rover.lua"
local TEMP  = os.getenv("TEMP") or "."
local HOME  = TEMP .. "\\rover-foreign-home"      -- isolated CLUA_HOME store
local WORK  = TEMP .. "\\rover-foreign-work"      -- tarball build area
local PROJ  = TEMP .. "\\rover-foreign-proj"      -- project dir for `add`
local OFFICIAL = "https://raw.githubusercontent.com/kishimodo/CLua-Packages/main/packages"

local function sh(cmd) local ok, _, c = os.execute('"' .. cmd .. '"'); return (ok == true) or (ok == 0) or (c == 0) end
local function run(cmd)                            -- exit code + combined output
  local f = io.popen("(" .. cmd .. ") 2>&1")
  if not f then return -1, "" end
  local out = f:read("*a") or ""
  local okc, _, code = f:close()
  if okc == true then code = 0 end
  return code or -1, out
end
local function slurp(p) local f = io.open(p, "rb"); if not f then return nil end local s = f:read("*a"); f:close(); return s end
local function spit(p, s) local f = io.open(p, "wb"); if not f then return false end f:write(s); f:close(); return true end
local function cleanup()
  for _, d in ipairs({ HOME, WORK, PROJ }) do sh('rmdir /S /Q "' .. d .. '" >nul 2>&1') end
end
local function fail(m) print("[-] FAIL test-pkgmgr-foreign: " .. m); cleanup(); os.exit(1) end

-- The foreign fetch path extracts with tar.exe. rover PINS
-- %SystemRoot%\System32\tar.exe (the bsdtar shipped with Windows 10 1803+)
-- instead of trusting PATH, so this test builds its fixture tarballs with the
-- SAME binary, and case C7 proves a hostile `tar` earlier on PATH cannot reach
-- the install.
--
-- SKIP is permitted for EXACTLY ONE reason: this Windows has no System32 tar at
-- all. Any other tar problem is a FAIL. Widening this predicate would retire
-- every assertion below while the tally stayed green -- and the old form did
-- exactly that in reverse: it probed `tar --version`, which a shadowing GNU tar
-- answers happily, so the test proceeded and then failed inside rover with a
-- misleading "failed to extract the tarball".
local TAR
do
  local root = os.getenv("SystemRoot") or os.getenv("windir") or "C:\\Windows"
  TAR = root .. "\\System32\\tar.exe"
  local f = io.open(TAR, "rb")
  if not f then
    print("[~] SKIP test-pkgmgr-foreign (no " .. TAR .. " on this host)")
    os.exit(0)
  end
  f:close()
  local c, out = run('"' .. TAR .. '" --version')
  if c ~= 0 then
    print("[-] FAIL test-pkgmgr-foreign: " .. TAR .. " exists but --version "
          .. "returned " .. tostring(c) .. ": " .. (out or ""))
    os.exit(1)
  end
end

-- rover commands against the ISOLATED store; cleared ROVER_REGISTRY so the
-- machine environment can't leak in. `extra` prefixes more `set` clauses.
local function rover(args, extra, cwd)
  local pre = 'set "CLUA_HOME=' .. HOME .. '" && set "ROVER_REGISTRY=" && ' .. (extra or "")
  local cd  = cwd and ('cd /d "' .. cwd .. '" && ') or ""
  return run(cd .. pre .. '"' .. CLUA .. '" -i "' .. PKG .. '" ' .. args)
end

----------------------------------------------------------------------
-- A) hook checks from the repo root: URL parsing, name derivation, and
--    default_registry() = rover\registry (the dev checkout wins).
----------------------------------------------------------------------
do
  local driver = TEMP .. "\\rover-foreign-driver.lua"
  spit(driver, [==[
dofile("rover/src/rover.lua")
local M = _G.ROVER_PKG
-- existing exports must survive
for _, k in ipairs({ "name_ok", "version_ok", "parse_semver", "semver_cmp",
                     "semver_satisfies", "registry_ok", "sha256", "tree_hash",
                     "index_versions", "parse_return_table" }) do
  if type(M[k]) ~= "function" then print("FAILCASE:export-" .. k); os.exit(7) end
end
for _, k in ipairs({ "is_github_source", "parse_github_source", "github_pkg_name",
                     "default_registry", "tar_exe" }) do
  if type(M[k]) ~= "function" then print("FAILCASE:newexport-" .. k); os.exit(7) end
end
-- The extraction tar is pinned, not resolved from PATH: it must be the absolute
-- System32 path, never a bare "tar".
do
  local got = M.tar_exe()
  local root = os.getenv("SystemRoot") or os.getenv("windir") or "C:\\Windows"
  local want = root:gsub("/", "\\") .. "\\System32\\tar.exe"
  if got ~= want then print("FAILCASE:tar-exe-pin-" .. tostring(got)); os.exit(7) end
end
local function ok(cond, label) if not cond then print("FAILCASE:" .. label); os.exit(7) end end
local P = M.parse_github_source
local function eq(s, o, r, label)
  local go, gr = P(s)
  ok(go == o and gr == r, label .. " (got " .. tostring(go) .. "/" .. tostring(gr) .. ")")
end
-- accepted forms: https URL (optional .git, trailing /), shorthand github.com/
eq("https://github.com/Acme/Widget",       "Acme", "Widget", "https-plain")
eq("https://github.com/acme/widget.git",   "acme", "widget", "https-dotgit")
eq("https://github.com/acme/widget/",      "acme", "widget", "https-trailing-slash")
eq("https://github.com/acme/widget.git/",  "acme", "widget", "https-dotgit-slash")
eq("http://github.com/acme/widget",        "acme", "widget", "http-plain")
eq("github.com/acme/widget",               "acme", "widget", "shorthand")
eq("github.com/acme/widget.git",           "acme", "widget", "shorthand-dotgit")
-- name derivation = repo lower-cased (+ allowlist)
ok(M.github_pkg_name("https://github.com/Acme/Widget.git") == "widget", "name-derive-lower")
ok(M.github_pkg_name("github.com/Acme/My_Pkg.v2") == "my_pkg.v2", "name-derive-allowed-chars")
-- not GitHub sources at all -> nil, and not routed to the foreign path
for _, s in ipairs({ "https://gitlab.com/a/b", "acme/widget", "widget",
                     "file:///x/y", "https://github.org/a/b" }) do
  ok(P(s) == nil and not M.is_github_source(s), "not-github:" .. s)
end
-- github-shaped but malformed/hostile -> nil + an error message
for _, s in ipairs({ "github.com/acme", "https://github.com/",
                     "github.com/acme/widget/extra", "github.com/ac me/widget",
                     'github.com/acme/wid&get', "github.com/..%2f/x" }) do
  local o, e = P(s)
  ok(o == nil and type(e) == "string", "malformed:" .. s)
  ok(M.is_github_source(s), "still-github-shaped:" .. s)
end
-- dev checkout: cwd is the repo root, ROVER_REGISTRY cleared -> rover\registry
ok(M.default_registry() == "rover\\registry", "default-registry-dev-checkout")
ok(M.OFFICIAL_REGISTRY == "https://raw.githubusercontent.com/kishimodo/CLua-Packages/main/packages",
   "official-url-constant")
print("HOOK_OK")
]==])
  local c, out = run('set "ROVER_PKG_TEST=1" && set "ROVER_REGISTRY=" && "'
                     .. CLUA .. '" -i "' .. driver .. '"')
  os.remove(driver)
  if c ~= 0 or not out:match("HOOK_OK") then
    fail("hook checks failed: " .. out:gsub("%s+", " "))
  end
end

----------------------------------------------------------------------
-- B) default_registry precedence: $ROVER_REGISTRY (when set) wins over the
--    dev checkout; from a NON-checkout cwd with it unset, the OFFICIAL URL.
----------------------------------------------------------------------
do
  local driver = TEMP .. "\\rover-foreign-defreg.lua"
  spit(driver, 'dofile("' .. ROOT:gsub("\\", "/") .. '/rover/src/rover.lua")\n'
            .. 'io.write(_G.ROVER_PKG.default_registry())\n')
  -- B1: env var set (cwd = repo root, where rover\registry exists) -> env wins
  local c1, o1 = run('set "ROVER_PKG_TEST=1" && set "ROVER_REGISTRY=C:\\custom\\reg" && "'
                     .. CLUA .. '" -i "' .. driver .. '"')
  if c1 ~= 0 or o1 ~= "C:\\custom\\reg" then
    os.remove(driver); fail("ROVER_REGISTRY should win over the dev checkout, got: " .. o1)
  end
  -- B2: cwd = %TEMP% (no rover\registry there), env unset -> OFFICIAL URL.
  --     Pure hook introspection -- nothing is fetched from the network.
  local c2, o2 = run('cd /d "' .. TEMP .. '" && set "ROVER_PKG_TEST=1" && set "ROVER_REGISTRY=" && "'
                     .. CLUA .. '" -i "' .. driver .. '"')
  os.remove(driver)
  if c2 ~= 0 or o2 ~= OFFICIAL then
    fail("official-URL fallback: expected " .. OFFICIAL .. ", got: " .. o2)
  end
end

----------------------------------------------------------------------
-- C) offline foreign install end-to-end via $ROVER_FOREIGN_TARBALL.
----------------------------------------------------------------------
cleanup()
sh('mkdir "' .. HOME .. '" >nul 2>&1')
sh('mkdir "' .. WORK .. '" >nul 2>&1')
sh('mkdir "' .. PROJ .. '" >nul 2>&1')

-- build widget.tgz: codeload-style top-level dir <Repo>-<branch>/
do
  local src = WORK .. "\\Widget-main"
  sh('mkdir "' .. src .. '" >nul 2>&1')
  spit(src .. "\\init.lua", '-- widget -- a foreign test package\n'
    .. 'local M = {}\nM.version = "1.2.3"\n'
    .. 'function M.greet() return "widget!" end\nreturn M\n')
  spit(src .. "\\helper.lua", "return 42\n")
  if not sh('cd /d "' .. WORK .. '" && "' .. TAR .. '" -czf widget.tgz Widget-main') then
    fail("could not build widget.tgz with tar")
  end
end
local HOOK = 'set "ROVER_FOREIGN_TARBALL=' .. WORK .. '\\widget.tgz" && '

-- C1: install from the https URL form; warning text printed; store + manifest
do
  local c, out = rover("install https://github.com/Acme/Widget", HOOK, ROOT)
  if c ~= 0 then fail("foreign install exited " .. c .. ": " .. out:gsub("%s+", " ")) end
  if not out:find("installed FOREIGN 'widget' v1.2.3", 1, true) then
    fail("missing FOREIGN install line: " .. out:gsub("%s+", " "))
  end
  for _, want in ipairs({
    "[!] WARNING: 'widget' is a FOREIGN package from github.com/Acme/Widget",
    "NOT a verified package from the official CLua-Packages registry",
    "no registry integrity hash",
    "open a Pull Request at https://github.com/kishimodo/CLua-Packages",
    "reviewed and accepted or denied",
  }) do
    if not out:find(want, 1, true) then fail("install warning lacks: " .. want) end
  end
  local init = slurp(HOME .. "\\packages\\widget\\init.lua")
  if not (init and init:find("widget!", 1, true)) then fail("widget\\init.lua not in the store") end
  if not slurp(HOME .. "\\packages\\widget\\helper.lua") then fail("widget\\helper.lua not copied") end
  local man = slurp(HOME .. "\\packages\\.meta\\widget.lua") or ""
  if not man:find('source = "github.com/Acme/Widget"', 1, true) then
    fail("manifest does not record the foreign source: " .. man:gsub("%s+", " "))
  end
  if not man:find('version = "1.2.3"', 1, true) then fail("manifest version wrong: " .. man) end
end

-- C2: list marks it [FOREIGN] and prints the warning
do
  local c, out = rover("list", nil, ROOT)
  if c ~= 0 then fail("list exited " .. c) end
  if not (out:find("widget", 1, true) and out:find("[FOREIGN]", 1, true)) then
    fail("list does not mark widget as FOREIGN: " .. out:gsub("%s+", " "))
  end
  if not out:find("[!] WARNING: 'widget' is a FOREIGN package from github.com/Acme/Widget", 1, true) then
    fail("list does not print the foreign warning")
  end
end

-- C3: verify passes (install-time hashes), prints the warning; tamper -> fails
do
  local c, out = rover("verify widget", nil, ROOT)
  if c ~= 0 then fail("verify widget should pass, got " .. c .. ": " .. out:gsub("%s+", " ")) end
  if not out:find("[!] WARNING: 'widget' is a FOREIGN package", 1, true) then
    fail("verify does not print the foreign warning")
  end
  spit(HOME .. "\\packages\\widget\\helper.lua", "return 43 -- tampered\n")
  local c2, out2 = rover("verify widget", nil, ROOT)
  if c2 == 0 then fail("verify must FAIL after tampering a foreign package file") end
  if not out2:find("INTEGRITY FAILURE", 1, true) then
    fail("tampered verify lacks INTEGRITY FAILURE: " .. out2:gsub("%s+", " "))
  end
  spit(HOME .. "\\packages\\widget\\helper.lua", "return 42\n")   -- restore
end

-- C4: `add github.com/<o>/<r>` records toml dep + lock entry with source,
--     then lock-mode `install` verifies the foreign pin (and warns).
do
  local c, out = rover("add github.com/Acme/Widget", HOOK, PROJ)
  if c ~= 0 then fail("foreign add exited " .. c .. ": " .. out:gsub("%s+", " ")) end
  if not out:find("added FOREIGN 'widget'", 1, true) then fail("add output: " .. out:gsub("%s+", " ")) end
  local toml = slurp(PROJ .. "\\rover.toml") or ""
  if not toml:find('widget = "*"', 1, true) then fail("rover.toml lacks widget dep: " .. toml:gsub("%s+", " ")) end
  local lock = slurp(PROJ .. "\\rover.lock") or ""
  if not (lock:find('%["widget"%]') and lock:find('source = "github.com/Acme/Widget"', 1, true)) then
    fail("rover.lock lacks the foreign pin/source: " .. lock:gsub("%s+", " "))
  end
  local c2, out2 = rover("install", nil, PROJ)
  if c2 ~= 0 then fail("lock-mode install of a foreign pin should pass: " .. out2:gsub("%s+", " ")) end
  if not out2:find("(foreign, locked)", 1, true) then
    fail("lock-mode install does not report the foreign pin: " .. out2:gsub("%s+", " "))
  end
  if not out2:find("[!] WARNING: 'widget' is a FOREIGN package", 1, true) then
    fail("lock-mode install does not warn about the foreign pin")
  end
end

-- C5: package.lua `entry` form (no init.lua at the root)
do
  local src = WORK .. "\\Entry-main"
  sh('mkdir "' .. src .. '\\src" >nul 2>&1')
  spit(src .. "\\package.lua",
       'return { name = "entry", version = "2.0.0", description = "entry test", entry = "src/main.lua" }\n')
  spit(src .. "\\src\\main.lua", 'local M = {}\nfunction M.go() return "entry!" end\nreturn M\n')
  if not sh('cd /d "' .. WORK .. '" && "' .. TAR .. '" -czf entry.tgz Entry-main') then fail("tar entry.tgz") end
  local c, out = rover("install github.com/Acme/Entry",
                       'set "ROVER_FOREIGN_TARBALL=' .. WORK .. '\\entry.tgz" && ', ROOT)
  if c ~= 0 then fail("entry-form install exited " .. c .. ": " .. out:gsub("%s+", " ")) end
  local init = slurp(HOME .. "\\packages\\entry\\init.lua")
  if not (init and init:find("entry!", 1, true)) then
    fail("entry-form install did not materialize init.lua from package.lua entry")
  end
  local man = slurp(HOME .. "\\packages\\.meta\\entry.lua") or ""
  if not (man:find('version = "2.0.0"', 1, true)
          and man:find('source = "github.com/Acme/Entry"', 1, true)) then
    fail("entry-form manifest wrong: " .. man:gsub("%s+", " "))
  end
end

-- C6: a repo without init.lua (or a usable entry) fails with a clear error
do
  local src = WORK .. "\\noinit-main"
  sh('mkdir "' .. src .. '" >nul 2>&1')
  spit(src .. "\\readme.txt", "not a package\n")
  if not sh('cd /d "' .. WORK .. '" && "' .. TAR .. '" -czf noinit.tgz noinit-main') then fail("tar noinit.tgz") end
  local c, out = rover("install github.com/Acme/noinit",
                       'set "ROVER_FOREIGN_TARBALL=' .. WORK .. '\\noinit.tgz" && ', ROOT)
  if c == 0 then fail("install of a repo without init.lua must fail") end
  if not out:find("does not look like a CLua package", 1, true) then
    fail("missing clear no-init error: " .. out:gsub("%s+", " "))
  end
end

-- C7: PATH IMMUNITY. Put a hostile `tar` ahead of everything on PATH and
-- install. rover must succeed and must never invoke it.
--
-- This case is the one that gives the System32 pin any value. With the pin in
-- place but no hijack case, the suite passes identically whether the pin is
-- present or reverted -- on every machine with a clean PATH, which is most of
-- them. The regression would then only ever be caught by the next person who
-- happens to have Git for Windows earlier on PATH.
do
  local src = WORK .. "\\Hijack-main"
  sh('mkdir "' .. src .. '" >nul 2>&1')
  spit(src .. "\\init.lua", 'local M = {}\nM.version = "0.1.0"\nreturn M\n')
  if not sh('cd /d "' .. WORK .. '" && "' .. TAR .. '" -czf hijack.tgz Hijack-main') then
    fail("tar hijack.tgz")
  end

  local FAKEBIN = WORK .. "\\fakebin"
  local MARK    = WORK .. "\\fake-tar-was-invoked"
  sh('mkdir "' .. FAKEBIN .. '" >nul 2>&1')
  os.remove(MARK)
  -- cmd searches PATH directory by directory and runs the first `tar` with a
  -- PATHEXT extension, so a .bat shadows System32's tar.exe when its directory
  -- comes first. The stand-in leaves positive evidence and then fails, so
  -- "rover succeeded" and "the fake never ran" are two independent assertions.
  if not spit(FAKEBIN .. "\\tar.bat",
              "@echo off\r\n> \"" .. MARK .. "\" echo invoked\r\nexit /b 1\r\n") then
    fail("cannot write the stand-in tar.bat")
  end

  -- Quote the `set` so cmd does not choke on a PATH containing parentheses
  -- (Program Files (x86)), and prepend rather than replace so the toolchain
  -- and powershell stay reachable.
  local hijack = 'set "PATH=' .. FAKEBIN .. ';%PATH%" && '
              .. 'set "ROVER_FOREIGN_TARBALL=' .. WORK .. '\\hijack.tgz" && '
  local c, out = rover("install github.com/Acme/Hijack", hijack, ROOT)
  if c ~= 0 then
    fail("a hostile tar earlier on PATH broke the install (exit " .. tostring(c)
         .. "): " .. out:gsub("%s+", " "))
  end
  if not out:find("installed", 1, true) then
    fail("install with a hijacked PATH did not report success: "
         .. out:gsub("%s+", " "))
  end
  if slurp(MARK) then
    fail("rover executed the tar found on PATH instead of the pinned "
         .. "System32 binary (marker " .. MARK .. " exists)")
  end
end

cleanup()
print("[+] PASS test-pkgmgr-foreign (github URL parsing + name derivation; registry "
   .. "precedence incl. official-URL fallback; offline foreign install/list/verify/add "
   .. "with FOREIGN warnings; entry-form; no-init failure; PATH-hijack immunity)")
os.exit(0)
