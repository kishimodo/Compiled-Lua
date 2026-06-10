-- tools/run-tests.lua : LuaVM's universal, auto-discovering test runner.
--
-- Run it via  build\run-tests.bat  (which sets the MinGW/make PATH so gcc/ar are
-- found, builds the products, then calls  build\bin\luavm.exe tools\run-tests.lua).
--
-- It discovers and runs four test layers with ZERO per-test wiring -- drop a file
-- in the matching folder and it runs; delete one and nothing breaks:
--   tests/unit/test_*.c        C unit tests, compiled against build/bin/libluavmtest.a
--   tests/lua/*.lua            behavioral, run under luavm.exe (assert + exit non-zero)
--   tests/packages/test_*.lua  package tests, compiled with compiler.exe then run
--   tests/differential/*.lua   same script under JIT and -i; stdout must match
-- ...plus the self-contained tools/ behavioral suites. Prints one PASS/FAIL/SKIP
-- tally and exits non-zero if anything failed.
--
-- A test PASSES on exit 0 with no "[-] FAIL" line; SKIPS if it prints "[~] SKIP"
-- (e.g. a package whose external DLL is absent); otherwise FAILS.

local BIN      = "build\\bin"
local LUAVM    = BIN .. "\\luavm.exe"
local COMPILER = BIN .. "\\compiler.exe"
local ARCHIVE  = BIN .. "\\libluavmtest.a"
local LUALIB   = BIN .. "\\liblua54.a"
local TESTBIN  = BIN .. "\\tests"
local CC       = "x86_64-w64-mingw32-gcc"
local AR       = "ar"
local CFLAGS   = "-std=c99 -Wall -Wextra -Wno-unused-parameter -O2 -g "
              .. "-I./src -I./lua-5.4/src -I./build/gen -DLUAVM_TARGET_WINDOWS_X64=1 -Itests/unit"
-- Broad but standard import libs; gcc ignores any a given test doesn't reference.
local LDLIBS   = "-lm -lkernel32 -lbcrypt -lws2_32 -lntdll -ladvapi32 -luser32 -lole32 -lstdc++"

local pass, fail, skip, xfail_n, xpass_n = 0, 0, 0, 0, 0
local failed, xpassed = {}, {}

-- ---- shell helpers --------------------------------------------------------

-- Windows cmd /c quote trap: when a command STARTS with a quoted path, cmd
-- strips the first and last quote in the whole string, mangling
-- `"a.exe" "b.lua" 2>&1` into `a.exe" "b.lua 2>&1`. Wrapping the entire command
-- in one more quote pair makes cmd strip THOSE, leaving the inner quotes intact.
local function wrap(cmd) return '"' .. cmd .. '"' end

local function exec(cmd)            -- returns exit code (0 = ok)
  local ok, _, code = os.execute(wrap(cmd))
  if ok == true then return 0 end
  return code or 1
end

local function capture(cmd)        -- returns combined-or-stdout text, exit code
  local p = io.popen(wrap(cmd))
  if not p then return "", -1 end
  local out = p:read("*a") or ""
  local ok, _, code = p:close()
  return out, (ok == true) and 0 or (code or 1)
end

-- ---- watchdog ---------------------------------------------------------------
-- Every test invocation runs under tools/timeout-run.exe (compiled lazily with
-- the same gcc as the unit tests): a kill-on-close Job Object enforces a hard
-- wall-clock deadline on the whole child process tree, so one hung JIT loop
-- cannot wedge the suite. Exit 124 = deadline fired (GNU timeout convention).
-- Override the budget with LUAVM_TEST_TIMEOUT_MS; if the watchdog fails to
-- build we warn and run unguarded rather than refusing to test.
local WATCHDOG    = TESTBIN .. "\\timeout-run.exe"
local TIMEOUT_MS  = tonumber(os.getenv("LUAVM_TEST_TIMEOUT_MS") or "") or 120000
local have_watchdog = false

local function build_watchdog()
  os.execute('if not exist "' .. TESTBIN .. '" mkdir "' .. TESTBIN .. '" >nul 2>&1')
  local log, rc = capture(CC .. ' -std=c99 -Wall -Wextra -O2 -municode -o "'
                          .. WATCHDOG .. '" tools/timeout-run.c 2>&1')
  have_watchdog = (rc == 0)
  if not have_watchdog then
    print("  [!] watchdog build failed -- tests run without a timeout guard")
    for line in log:gmatch("[^\r\n]+") do
      if line:find("error") then print("      " .. line) end
    end
  end
end

-- Prepend the watchdog to a command line whose first token is an executable.
-- (Not applied to cmd builtins like `dir` or `set` -- compose those so only
-- the exe segment is guarded.)
local function guard(cmd)
  if not have_watchdog then return cmd end
  return '"' .. WATCHDOG .. '" ' .. TIMEOUT_MS .. ' ' .. cmd
end

-- List files matching <dir>/<pat> as "<dir>/<name>" (forward slashes). Empty if
-- the directory is missing -- so a not-yet-created layer is simply skipped.
local function glob(dir, pat)
  local out = {}
  local p = io.popen('dir /b "' .. dir:gsub("/", "\\") .. '\\' .. pat .. '" 2>nul')
  if not p then return out end
  for line in p:lines() do
    line = line:gsub("[\r\n]+$", ""):gsub("%s+$", "")
    if #line > 0 then out[#out + 1] = dir .. "/" .. line end
  end
  p:close()
  return out
end

local function basename(path, ext)
  return (path:match("([^/\\]+)" .. ext .. "$"))
end

-- Classify a finished test by its output + exit code, update counters, print.
-- XFAIL/XPASS markers (a test asserting CORRECT behavior of a known bug) are
-- counted wherever they appear, independent of the test's overall result:
--   [x] XFAIL  -- the known bug is still present (expected; does not fail the run)
--   [!] XPASS  -- the bug appears FIXED; remove the xfail marker (flagged, not fatal)
local function record(layer, name, out, code, extra)
  out = out or ""
  local nx = select(2, out:gsub("%[x%] XFAIL", ""))
  local np = select(2, out:gsub("%[!%] XPASS", ""))
  xfail_n = xfail_n + nx
  xpass_n = xpass_n + np
  if np > 0 then xpassed[#xpassed + 1] = layer .. ":" .. name end
  local tag = (nx > 0 or np > 0)
      and string.format("  (%dx xfail%s)", nx, np > 0 and (", " .. np .. "x XPASS!") or "") or ""
  if code == 124 then
    extra = (extra and (extra .. " ") or "") .. string.format("(TIMEOUT after %dms)", TIMEOUT_MS)
  end
  if out:find("%[%-%] FAIL") or (code ~= 0 and not out:find("%[~%] SKIP")) then
    fail = fail + 1
    failed[#failed + 1] = layer .. ":" .. name
    print(string.format("  [-] FAIL  %-9s %s%s", layer, name, extra and (" " .. extra) or ""))
    local detail = out:match("%[%-%] FAIL[^\r\n]*")
    if detail then print("            " .. detail) end
  elseif out:find("%[~%] SKIP") then
    skip = skip + 1
    local why = out:match("%[~%] SKIP[^\r\n]*") or ""
    print(string.format("  [~] SKIP  %-9s %s   %s", layer, name, why))
  else
    pass = pass + 1
    print(string.format("  [+] PASS  %-9s %s%s", layer, name, tag))
  end
end

local function header(t) print("\n===== " .. t .. " =====") end

-- ---- phase 1: build the core archive --------------------------------------

-- Objects to keep OUT of the test archive: the two that define main(), plus the
-- runtime bootstrap pair that pulls the package preload table / native loader /
-- imgui host (symbols not in this archive). Everything else is fair game; an
-- archive member is only linked into a test that references its symbols.
local ARCHIVE_EXCLUDE = {
  ["main.o"] = true, ["luavm_main.o"] = true,
  ["runtime_init.o"] = true, ["native_loader.o"] = true,
  -- aot_entry.c (added by a later task) defines main() for compiled PEs; it
  -- must stay out of the unit-test archive, like the other *_main objects.
  ["aot_entry.o"] = true,
}

local function build_archive()
  local objs = {}
  for _, d in ipairs({ "build/bin/obj/ffi", "build/bin/obj/jit",
                       "build/bin/obj/compiler", "build/bin/obj/runtime",
                       "build/bin/obj/ir", "build/bin/obj/opt",
                       "build/bin/obj/codegen", "build/bin/obj/link",
                       "build/bin/obj/driver" }) do
    for _, o in ipairs(glob(d, "*.o")) do
      local base = basename(o, "%.o") .. ".o"
      if not ARCHIVE_EXCLUDE[base] then
        objs[#objs + 1] = '"' .. o .. '"'
      end
    end
  end
  if #objs == 0 then
    print("  [!] no object files found under build/bin/obj -- build the products first")
    return false
  end
  os.remove(ARCHIVE)
  os.execute('if not exist "' .. TESTBIN .. '" mkdir "' .. TESTBIN .. '" >nul 2>&1')
  local rc = exec(AR .. ' rcs "' .. ARCHIVE .. '" ' .. table.concat(objs, " "))
  print(string.format("  archived %d objects -> %s (ar exit %d)", #objs, ARCHIVE, rc))
  return rc == 0
end

-- ---- phase 2: C unit tests ------------------------------------------------

local function run_unit()
  header("C unit tests (tests/unit/test_*.c)")
  for _, src in ipairs(glob("tests/unit", "test_*.c")) do
    local name = basename(src, "%.c")
    local exe  = TESTBIN .. "\\" .. name .. ".exe"
    local clog, crc = capture(CC .. " " .. CFLAGS .. ' -o "' .. exe .. '" "' .. src
                              .. '" "' .. ARCHIVE .. '" "' .. LUALIB .. '" ' .. LDLIBS .. " 2>&1")
    if crc ~= 0 then
      fail = fail + 1
      failed[#failed + 1] = "unit:" .. name
      print(string.format("  [-] FAIL  %-9s %s (compile error)", "unit", name))
      for line in clog:gmatch("[^\r\n]+") do
        if line:find("error") then print("            " .. line) end
      end
    else
      local out, rc = capture(guard('"' .. exe .. '" 2>&1'))
      record("unit", name, out, rc)
    end
  end
end

-- ---- phase 3: Lua behavioral ----------------------------------------------

local function run_lua()
  header("Lua behavioral (tests/lua/*.lua)")
  for _, src in ipairs(glob("tests/lua", "*.lua")) do
    if not src:match("/_") then         -- skip _helpers.lua etc.
      local out, rc = capture(guard('"' .. LUAVM .. '" "' .. src .. '" 2>&1'))
      record("lua", basename(src, "%.lua"), out, rc)
    end
  end
end

-- ---- phase 4: package tests -----------------------------------------------

-- Source-path LUA_PATH so the script runner can `require` builtin packages
-- straight from src/ -- the compiled exe embeds them, but luavm.exe does not.
local PKG_LUA_PATH = "src\\runtime\\packages\\?\\init.lua;src\\runtime\\packages\\?.lua"

-- Strip per-run noise (JIT compile traces land on stderr already, but be
-- robust if a future change moves them) before diffing two captures.
local function strip_traces(s)
  return (s:gsub("%[%*%] jit:[^\r\n]*[\r\n]*", ""):gsub("%[%*%] runtime:[^\r\n]*[\r\n]*", ""))
end

local function run_packages()
  header("Package tests (tests/packages/test_*.lua)")
  for _, src in ipairs(glob("tests/packages", "test_*.lua")) do
    local name = basename(src, "%.lua")
    local exe  = TESTBIN .. "\\" .. name .. ".exe"
    local clog, crc = capture(guard('"' .. COMPILER .. '" -w -o "' .. exe .. '" "' .. src .. '" 2>&1'))
    if crc ~= 0 then
      fail = fail + 1
      failed[#failed + 1] = "package:" .. name
      print(string.format("  [-] FAIL  %-9s %s (compile error)", "package", name))
    else
      local out, rc = capture(guard('"' .. exe .. '" 2>&1'))
      record("package", name, out, rc)

      -- Interpreter-oracle cross-check: the compiled exe's executor IS the
      -- JIT, so package code would otherwise never meet the bytecode
      -- interpreter anywhere in the suite (a weak assert can't catch a JIT
      -- miscompile -- JIT-VARARG-001 was first exposed through a package).
      -- Run the same test source under luavm.exe (JIT) and luavm.exe -i with
      -- LUA_PATH pointed at the package sources and diff stdout. Packages
      -- whose require only works inside a compiled exe (native loaders)
      -- simply fail the source require under BOTH modes -- skip those.
      if rc == 0 and out:find("%[%+%] PASS") then
        local setenv = 'set "LUA_PATH=' .. PKG_LUA_PATH .. '" && '
        local oj, rj = capture(setenv .. guard('"' .. LUAVM .. '" "' .. src .. '" 2>nul'))
        local oi, ri = capture(setenv .. guard('"' .. LUAVM .. '" -i "' .. src .. '" 2>nul'))
        if rj == 0 and ri == 0 then
          if strip_traces(oj) == strip_traces(oi) then
            pass = pass + 1
            print(string.format("  [+] PASS  %-9s %s (src JIT == -i)", "pkgdiff", name))
          else
            fail = fail + 1
            failed[#failed + 1] = "pkgdiff:" .. name
            print(string.format("  [-] FAIL  %-9s %s (JIT vs -i stdout mismatch on package source)", "pkgdiff", name))
          end
        end
        -- rj~=0 or ri~=0: source require unavailable under the script runner
        -- (embedded-only package) or the test needs the compiled environment;
        -- the compiled-exe result above already covers it -- no extra entry.
      end
    end
  end
end

-- ---- phase 5: differential (JIT vs interpreter) ---------------------------

local function run_differential()
  header("Differential JIT-vs-interpreter (tests/differential/*.lua)")
  for _, src in ipairs(glob("tests/differential", "*.lua")) do
    local name = basename(src, "%.lua")
    local oj, rj = capture(guard('"' .. LUAVM .. '" "' .. src .. '" 2>nul'))
    local oi, ri = capture(guard('"' .. LUAVM .. '" -i "' .. src .. '" 2>nul'))
    if rj == 0 and ri == 0 and oj == oi and #oj > 0 then
      pass = pass + 1
      print(string.format("  [+] PASS  %-9s %s", "diff", name))
    else
      fail = fail + 1
      failed[#failed + 1] = "diff:" .. name
      local reason = (rj ~= 0 or ri ~= 0) and "(nonzero exit)" or "(JIT vs -i stdout mismatch)"
      print(string.format("  [-] FAIL  %-9s %s %s", "diff", name, reason))
    end
  end
end

-- ---- phase 5a: AOT differential (aotc.exe PE vs interpreter) --------------

-- Compile each tests/differential/aot_*.lua with aotc.exe into a real PE, run
-- it, and diff its stdout against luavm.exe -i on the same source (the M0
-- arbiter: a compiled program must match the interpreter byte-for-byte). The
-- phase self-skips if aotc.exe isn't built (run-tests.bat builds luac-objs but
-- not aotc.exe; build it with build\build-luac.bat to exercise this layer).
local AOTC = BIN .. "\\aotc.exe"

local function file_exists(path)
  local f = io.open(path:gsub("/", "\\"), "rb")
  if f then f:close(); return true end
  return false
end

local function run_aot_differential()
  header("AOT differential aotc-PE-vs-interpreter (tests/differential/aot_*.lua)")
  if not file_exists(AOTC) then
    print("  [~] SKIP  aotdiff   aotc.exe not built (run build\\build-luac.bat to enable)")
    return
  end
  -- Each differential is exercised at BOTH -O0 (faithful boxed baseline) and -O1
  -- (the optimizer's typed fastpaths). Both must match the interpreter exactly,
  -- so the optimizer can never silently change behavior (sound-conservative).
  local OPT_LEVELS = { { flag = "",    tag = "O0" },
                       { flag = "-O1", tag = "O1" } }
  for _, src in ipairs(glob("tests/differential", "aot_*.lua")) do
    local base = basename(src, "%.lua")
    local oi, ri = capture(guard('"' .. LUAVM .. '" -i "' .. src .. '" 2>nul'))
    for _, lvl in ipairs(OPT_LEVELS) do
      local name = base .. "[" .. lvl.tag .. "]"
      local exe  = TESTBIN .. "\\" .. base .. "_" .. lvl.tag .. ".exe"
      local clog, crc = capture(guard('"' .. AOTC .. '" ' .. lvl.flag .. ' "' .. src
                                      .. '" -o "' .. exe .. '" 2>&1'))
      if crc ~= 0 then
        fail = fail + 1
        failed[#failed + 1] = "aotdiff:" .. name
        print(string.format("  [-] FAIL  %-9s %s (aotc compile/link error)", "aotdiff", name))
        for line in clog:gmatch("[^\r\n]+") do
          if line:find("error") then print("            " .. line) end
        end
      else
        local oa, ra = capture(guard('"' .. exe .. '" 2>nul'))
        if ra == 0 and ri == 0 and oa == oi and #oa > 0 then
          pass = pass + 1
          print(string.format("  [+] PASS  %-9s %s", "aotdiff", name))
        else
          fail = fail + 1
          failed[#failed + 1] = "aotdiff:" .. name
          local reason = (ra ~= 0 or ri ~= 0) and "(nonzero exit)" or "(AOT-PE vs -i stdout mismatch)"
          print(string.format("  [-] FAIL  %-9s %s %s", "aotdiff", name, reason))
        end
      end
    end
  end
end

-- ---- phase 5b: conformance corpus (JIT vs interpreter, with DIFF-XFAIL) ----

-- Read up to the first ~10 lines of a file looking for a `-- DIFF-XFAIL: reason`
-- directive. Returns the reason string (sans leading/trailing space) or nil.
local function diff_xfail_reason(path)
  local f = io.open(path:gsub("/", "\\"), "r")
  if not f then return nil end
  local reason
  for _ = 1, 12 do
    local line = f:read("*l")
    if not line then break end
    local r = line:match("^%s*%-%-%s*DIFF%-XFAIL:%s*(.-)%s*$")
    if r then reason = r; break end
  end
  f:close()
  return reason
end

-- A broad Lua 5.4 conformance corpus run through the SAME differential check as
-- phase 5 (JIT stdout vs interpreter stdout, byte-for-byte). A divergence is a
-- JIT codegen bug. Files may opt into a known divergence with a first-lines
-- comment `-- DIFF-XFAIL: <reason>`: such a file's divergence is tallied as an
-- expected XFAIL (the live 'distance to conformance' metric) rather than a FAIL,
-- and an UNEXPECTED MATCH on an xfail'd file is reported XPASS so the marker can
-- be removed once the JIT bug is fixed.
local function run_conformance()
  header("Conformance corpus JIT-vs-interpreter (tests/conformance/*.lua)")
  for _, src in ipairs(glob("tests/conformance", "*.lua")) do
    local name   = basename(src, "%.lua")
    local reason = diff_xfail_reason(src)
    local oj, rj = capture(guard('"' .. LUAVM .. '" "' .. src .. '" 2>nul'))
    local oi, ri = capture(guard('"' .. LUAVM .. '" -i "' .. src .. '" 2>nul'))
    -- The interpreter is the oracle: it must run clean and produce output.
    local oracle_ok = (ri == 0 and #oi > 0)
    local matches   = (rj == 0 and oracle_ok and oj == oi)
    if reason then
      -- Expected-divergence file. A continuing divergence is the expected XFAIL;
      -- a match means the JIT bug is gone -> XPASS (clean up the marker).
      if matches then
        xpass_n = xpass_n + 1
        xpassed[#xpassed + 1] = "conform:" .. name
        print(string.format("  [!] XPASS conform   %s   (now matches; drop DIFF-XFAIL: %s)", name, reason))
      else
        xfail_n = xfail_n + 1
        print(string.format("  [x] XFAIL conform   %s   (%s)", name, reason))
      end
    else
      if matches then
        pass = pass + 1
        print(string.format("  [+] PASS  %-9s %s", "conform", name))
      else
        fail = fail + 1
        failed[#failed + 1] = "conform:" .. name
        local why
        if not oracle_ok then
          why = "(interpreter oracle failed -- not a clean deterministic program)"
        elseif rj ~= 0 then
          why = "(JIT nonzero exit)"
        else
          why = "(JIT vs -i stdout mismatch -- add a DIFF-XFAIL if this is a known JIT bug)"
        end
        print(string.format("  [-] FAIL  %-9s %s %s", "conform", name, why))
      end
    end
  end
end

-- ---- phase 6: existing self-contained tools/ suites -----------------------

local function run_suites()
  header("Behavioral suites (tools/test-*.lua)")
  -- Auto-discover every self-contained behavioral suite (diagnostics, force-link,
  -- and the package-manager suites) so new ones are gated automatically.
  for _, src in ipairs(glob("tools", "test-*.lua")) do
    local name = basename(src, "%.lua")
    local out, rc = capture(guard('"' .. LUAVM .. '" "tools\\' .. name .. '.lua" 2>&1'))
    record("suite", name, out, rc)
  end
end

-- ---- phase 7: differential fuzz smoke (fixed seeds) -------------------------

-- A small FIXED-seed slice of the differential fuzzer (tools/fuzz-differential.lua)
-- so the generator+harness itself is gated on every run: 25 deterministic
-- programs, each run under the JIT and -i, stdout diffed. Fixed seeds keep CI
-- deterministic; long exploratory campaigns live in build\run-fuzz.bat.
local function run_fuzz_smoke()
  header("Differential fuzz smoke (tools/fuzz-differential.lua, seeds 1-25)")
  local out, rc = capture(guard('"' .. LUAVM .. '" tools\\fuzz-differential.lua 1 25 2>&1'))
  record("fuzz", "seeds-1-25", out, rc)
  -- surface the fuzzer's own summary line for context
  local summary = out:match("%[fuzz%][^\r\n]*")
  if summary then print("            " .. summary) end
end

-- ---- drive -----------------------------------------------------------------

print("LuaVM test runner -- auto-discovering all of tests/ + tools/ suites")
header("Building core archive (build/bin/libluavmtest.a)")
if not build_archive() then
  print("\n[-] could not build the test archive; aborting.")
  os.exit(1)
end
build_watchdog()
run_unit()
run_lua()
run_packages()
run_differential()
run_aot_differential()
run_conformance()
run_suites()
run_fuzz_smoke()

print(string.format("\n===== [PASS] %d   [FAIL] %d   [SKIP] %d   [XFAIL] %d   [XPASS] %d =====",
                    pass, fail, skip, xfail_n, xpass_n))
if xfail_n > 0 then
  print(string.format("  %d expected-failure(s) for known bugs (see docs/known-bugs-2026-06-07.md)", xfail_n))
end
if xpass_n > 0 then
  print("  XPASS -- a known bug now passes; remove its xfail marker in:")
  for _, n in ipairs(xpassed) do print("    ! " .. n) end
end
if fail > 0 then
  print("failures:")
  for _, n in ipairs(failed) do print("  - " .. n) end
  os.exit(1)
end
print(xpass_n > 0 and "green (with XPASS to clean up)." or "all green.")
os.exit(0)
