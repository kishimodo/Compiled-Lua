-- tools/test-codegen-no-globals.lua : the code generator keeps no mutable
-- file-scope state.
--
-- Auto-discovered by tools/run-tests.lua (phase 6). This gates invariant 4 of
-- docs/roadmaps/concurrency-size-stability.md -- "no new file-scope mutable state
-- in clua/src/codegen/" -- which exists because per-function code generation is
-- meant to become parallel, and a single `static int` in this directory silently
-- makes two workers share a value.
--
-- Why a symbol-table check rather than a behavioural one: the failure mode is
-- invisible to every other kind of test. A global that is faithfully reset at the
-- top of each function produces byte-identical output when functions are compiled
-- one at a time, so the differential suite, the byte-identity gate and the whole
-- test suite all stay green -- right up until two functions are generated
-- concurrently. `nm` is the only thing that can see it before that.
--
-- Known limit, established by mutation: a WRITE-ONLY static is dead code and
-- gcc -O2 eliminates it entirely, so nm never sees it and this test passes. That
-- is the right outcome rather than a hole -- a global nothing reads cannot make
-- two workers disagree -- but it means the test proves "no LOAD-BEARING mutable
-- global", not "no `static` keyword". A global that is written and read IS
-- caught: verified by adding one to res_reg_of and watching this fail while the
-- byte-identity gate stayed green.
--
-- Skips cleanly when the objects are not built or nm is unavailable.

local NAME = "test-codegen-no-globals"

local function sh(cmd)
  local p = io.popen('"' .. cmd .. ' 2>&1"')
  if not p then return "" end
  local out = p:read("*a") or ""
  p:close()
  return out
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local ROOT = trim(sh("git rev-parse --show-toplevel")):gsub("/", "\\")
if ROOT == "" then ROOT = trim(sh("cd")) end

-- The MinGW binutils in CLUA_MINGW_BIN are UNPREFIXED: nm.exe, not
-- x86_64-w64-mingw32-nm.exe. Only the gcc driver carries the triple.
local function find_nm()
  local bin = os.getenv("CLUA_MINGW_BIN")
  local cands = {}
  if bin and bin ~= "" then cands[#cands + 1] = bin .. "\\nm.exe" end
  cands[#cands + 1] = "nm"          -- whatever is on PATH
  for _, c in ipairs(cands) do
    local out = sh('"' .. c .. '" --version')
    if out:find("GNU nm") or out:find("binutils") then return c end
  end
  return nil
end

-- Every object compiled from clua/src/codegen/.
-- DERIVED from the sources, not hardcoded: build/Makefile globs the directory
-- (LUAC_SRCS), so a .c added to clua/src/codegen/ is compiled and linked while a
-- fixed list here would silently never check it -- which is the same
-- "configured correctly but not actually covering the tree" hole that let 342
-- objects go untracked in the header-dependency work.
local OBJS = {}
do
  local out = sh('dir /b "' .. ROOT .. '\\clua\\src\\codegen\\*.c"')
  for name in out:gmatch("[^\r\n]+") do
    local base = name:match("^(.+)%.c$")
    if base then OBJS[#OBJS + 1] = base end
  end
end
if #OBJS == 0 then
  print("[~] SKIP " .. NAME .. " (no sources found in clua/src/codegen)")
  os.exit(0)
end

local nm = find_nm()
if not nm then
  print("[~] SKIP " .. NAME .. " (no nm.exe; set CLUA_MINGW_BIN)")
  os.exit(0)
end

local found, checked = {}, 0
for _, base in ipairs(OBJS) do
  local obj = ROOT .. "\\build\\bin\\obj\\codegen\\" .. base .. ".o"
  local f = io.open(obj, "rb")
  if f then
    f:close()
    checked = checked + 1
    -- nm symbol classes: b/B = .bss, d/D = .data. Lower case is file-scope
    -- (static), upper case is external. Both are mutable process-wide state.
    -- Read-only tables land in .rdata (r/R) and are fine -- k_res_gpr and
    -- k_res_xmm are exactly that, and must NOT be flagged.
    for line in sh('"' .. nm .. '" "' .. obj .. '"'):gmatch("[^\r\n]+") do
      local cls, sym = line:match("^%x+%s+([bBdD])%s+(%S+)$")
      if cls and sym ~= ".bss" and sym ~= ".data" then
        found[#found + 1] = string.format("%s.o: %s (%s)", base, sym, cls)
      end
    end
  end
end

if checked == 0 then
  print("[~] SKIP " .. NAME .. " (build\\bin\\obj\\codegen not built)")
  os.exit(0)
end
-- A source with no built object is not a pass: it means the tree is stale and
-- that source's globals were never examined.
if checked ~= #OBJS then
  fail("%d of %d codegen sources have no built object, so their file-scope state "
       .. "was never examined", #OBJS - checked, #OBJS)
end

if #found > 0 then
  print(string.format("[-] FAIL %s: %d mutable file-scope object(s) in the code "
                      .. "generator; per-function codegen cannot be parallelised "
                      .. "while these exist, and byte-identity will not detect "
                      .. "them:", NAME, #found))
  for _, s in ipairs(found) do print("      " .. s) end
  print("    Put the value in LcCgCtx (per-compilation, read-only) or LcCgFnCtx "
        .. "(per-function) instead -- see clua/src/codegen/codegen.c.")
  os.exit(1)
end

print(string.format("[+] PASS %s (%d codegen object(s), zero mutable file-scope "
                    .. "objects)", NAME, checked))
os.exit(0)
