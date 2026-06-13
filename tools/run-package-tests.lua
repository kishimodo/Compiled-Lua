-- run-package-tests.lua -- per-package behavioral test harness (R3.1).
--
-- Run by clua-interp.exe (so it is shell-agnostic: the same on bash and cmd). The
-- Makefile `test-packages` target passes every clua/src/runtime/packages/<name>/
-- test.lua path as an argument. For each, this harness compiles it to a
-- standalone exe with compiler.exe (which statically bundles the package the
-- test `require`s) and runs it. A test.lua signals failure by calling
-- os.exit(1); success is exit 0. Any failure fails the whole run (exit 1).
--
-- This is the regression net that would have caught the ffi.gc break across
-- 21 packages, and the aes double-padding bug, before they shipped.

-- Backslashes in the *command* path: os.execute routes through cmd.exe, which
-- treats '/' as a switch separator, so "build/bin/compiler.exe" misparses.
-- (Forward slashes are fine for path *arguments* passed to compiler.exe.)
local COMPILER = "build\\bin\\compiler.exe"
local TMPDIR   = (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "\\clua-pkgtest"

os.execute('if not exist "' .. TMPDIR .. '" mkdir "' .. TMPDIR .. '" >nul 2>&1')

-- Display name = the test file's basename (e.g. tests/packages/test_aes.lua
-- -> "test_aes").
local function pkg_name(path)
  return (path:match("([^/\\]+)%.lua$") or path)
end

-- clua-interp.exe passes script arguments via the global `arg` table.
local tests = {}
for i = 1, #(arg or {}) do tests[i] = arg[i] end
if #tests == 0 then
  print("[*] no package test.lua files found -- nothing to run")
  os.exit(0)
end

-- os.execute routes through `cmd /c <string>`. When <string> begins with a
-- quote, cmd's quote-stripping mangles it ("filename syntax incorrect"). The
-- documented fix is to wrap the WHOLE command in an extra outer pair of quotes
-- so cmd strips exactly that pair, leaving the inner quoting intact. Returns
-- true iff the command exited 0.
local function sh(cmd)
  local ok, _, code = os.execute('"' .. cmd .. '"')
  return (ok == true) or (ok == 0) or (code == 0)
end

local pass, fail = 0, 0
local failed = {}

for _, path in ipairs(tests) do
  local name = pkg_name(path) or path
  local exe  = TMPDIR .. "\\pkgtest_" .. name .. ".exe"

  -- Compile quietly. The compiler path is relative + space-free so it needs
  -- no quotes; the output/source paths may contain spaces so they are quoted.
  local cok = sh(COMPILER .. ' -o "' .. exe .. '" "' .. path .. '" >nul 2>&1')
  if not cok then
    fail = fail + 1; failed[#failed+1] = name .. " (compile failed)"
    print(string.format("[-] FAIL %-16s (compile failed)", name))
  else
    -- Run; the test signals failure via os.exit(1).
    local rok = sh('"' .. exe .. '" >nul 2>&1')
    local ok = rok
    if ok then
      pass = pass + 1
      print(string.format("[+] PASS %-16s", name))
    else
      fail = fail + 1; failed[#failed+1] = name
      print(string.format("[-] FAIL %-16s (test asserted failure)", name))
    end
  end
end

print("")
print(string.format("[*] package tests: %d pass / %d fail", pass, fail))
if fail > 0 then
  print("[-] failed: " .. table.concat(failed, ", "))
  os.exit(1)
end
os.exit(0)
