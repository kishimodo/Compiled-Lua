-- tools/test-inline-table-fastpath.lua : OP_GETI array fast path lands at -O2 only.
--
-- Auto-discovered by tools/run-tests.lua (phase 6).
--
-- The claim under test: at -O2, codegen emits a runtime-checked prefix in
-- front of the Rt_GetIF call for OP_GETI with a literal integer index. At
-- -O0/-O1 it does not, keeping those tiers byte-identical to the pre-arc
-- output. The interpreter and the -O2 exe agree on stdout for the same
-- source.
--
-- Detection is by the fast prefix's shape, not its exact bytes: the sequence
-- opens with "cmp byte [rdi + B*16 + 8], 0x45 ; jne rel8" where 0x45 is
-- ctb(LUA_VTABLE). We match `80 7F <disp8> 45 75` -- CMP r/m8 imm8 with
-- ModR/M for [rdi+disp8], immediate 0x45, followed by JNE rel8. That is
-- specific enough that a bare Rt_GetIF call site cannot forge it (the call
-- shim starts with MOV RCX,RBX = 48 8B CB).
--
-- If build/bin/clua.exe is missing (a workspace that hasn't been built),
-- the test SKIPs rather than fails; the byte-identity gate is what proves
-- the -O0/-O1 no-op property in CI-like runs.

local NAME = "test-inline-table-fastpath"
local CLUA = "build\\bin\\clua.exe"
local TMP  = (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "\\clua-inline-geti"

local function file_exists(p)
  local f = io.open(p, "rb"); if not f then return false end
  f:close(); return true
end

if not file_exists(CLUA) then
  print(("[~] SKIP %s: %s not built (workspace was not compiled)"):format(NAME, CLUA))
  os.exit(0)
end

os.execute('if not exist "' .. TMP .. '" mkdir "' .. TMP .. '" >nul 2>&1')

-- OP_GETI is only emitted when the index is a literal integer constant
-- (`t[3]`); a variable index (`t[i]`) compiles to OP_GETTABLE, which this
-- arc does NOT touch. Fixture reads five literal-indexed slots inside a
-- loop so the sites stay in the .text and any wall-clock experiment would
-- notice; this test only checks emitted bytes and observable stdout.
local SRC = [[
local t = { 10, 20, 30, 40, 50 }
local sum = 0
for _ = 1, 3 do
  sum = sum + t[1] + t[2] + t[3] + t[4] + t[5]
end
print(sum)
]]

local function write_src(path)
  local f = assert(io.open(path, "wb"))
  f:write(SRC); f:close()
end

local function build(level)
  local src = TMP .. "\\geti_" .. level .. ".lua"
  local exe = TMP .. "\\geti_" .. level .. ".exe"
  write_src(src)
  os.remove(exe)
  local cmd = string.format('"%s" build "%s" -O%d -o "%s" >nul 2>&1',
                            CLUA, src, level, exe)
  -- cmd /c strips a leading `"` unless the whole command is wrapped in an
  -- outer quote pair. Every other tools/test-*.lua does the same wrap.
  os.execute('"' .. cmd .. '"')
  if not file_exists(exe) then
    return nil, nil, "clua produced no exe at -O" .. level
  end
  local h = io.open(exe, "rb")
  local data = h:read("*a"); h:close()
  return data, exe
end

-- The fast prefix's opening 8 bytes for a small B (disp8 form):
--   80  7F  <disp8>  45  75  <rel8>  48  8B
-- 80          = CMP r/m8, imm8 opcode
-- 7F          = ModR/M mod=01 reg=/7 rm=RDI (cmp byte [rdi+disp8], imm8)
-- disp8       = B*16 + 8 (tag byte of R[B])
-- 45          = imm8 = ctb(LUA_VTABLE)
-- 75          = JNE rel8 opcode
-- rel8        = displacement to slow label
-- 48 8B       = REX.W MOV r64, r/m64 -- opening of `mov rax, [rdi+B*16]`
--
-- The 48 8B tail rules out the coincidence that a runtime C function
-- (bundled into every exe via runtime-aot.a) happens to compare a byte
-- through RDI against 0x45 for its own reasons; the exact opcode of the
-- NEXT instruction here is fully determined by our codegen and a random
-- match would need eight ordered bytes to line up.
--
-- Measured: even eight ordered bytes are not unique. The runtime library
-- (bundled into every exe via runtime-aot.a) coincidentally contains one
-- copy of the pattern in some Rt_* helper's own code. So the test cannot
-- assert zero-vs-nonzero; it must assert that -O2 has STRICTLY MORE hits
-- than -O0, and that the excess matches the number of GETI sites in the
-- fixture. That is the invariant we care about anyway (each fixture GETI
-- gained a fast prefix at -O2 and none at -O0).
local function count_fast_prefix(data)
  local n = #data
  local hits = 0
  for i = 1, n - 7 do
    if data:byte(i)   == 0x80
       and data:byte(i+1) == 0x7F
       and data:byte(i+3) == 0x45
       and data:byte(i+4) == 0x75
       and data:byte(i+6) == 0x48
       and data:byte(i+7) == 0x8B then
      hits = hits + 1
    end
  end
  return hits
end

local function run_and_capture(exe)
  local out = TMP .. "\\geti_run.txt"
  os.remove(out)
  os.execute('"' .. string.format('"%s" > "%s" 2>&1', exe, out) .. '"')
  local h = io.open(out, "rb")
  if not h then return "" end
  local s = h:read("*a"); h:close()
  return s
end

local failures = {}
local function fail(fmt, ...) failures[#failures + 1] = string.format(fmt, ...) end

-- The fixture reads five literal-indexed slots; the inline path fires on
-- each, so -O2 must have exactly five more hits than -O0.
local FIXTURE_GETI_COUNT = 5

local d0, e0, err0 = build(0)
local d2, e2, err2 = build(2)
if not d0 then fail("build -O0 failed: %s", err0) end
if not d2 then fail("build -O2 failed: %s", err2) end
if d0 and d2 then
  local n0 = count_fast_prefix(d0)
  local n2 = count_fast_prefix(d2)
  local excess = n2 - n0
  if excess ~= FIXTURE_GETI_COUNT then
    fail("expected -O2 to have exactly %d more fast-prefix hits than -O0 "
         .. "(one per literal-indexed GETI in the fixture), but got n0=%d "
         .. "n2=%d excess=%d. Either the gate is emitting the prefix at -O0 "
         .. "(should not) or is not emitting it at -O2 (should).",
         FIXTURE_GETI_COUNT, n0, n2, excess)
  end
end

-- End-to-end: the -O2 exe's stdout must match what a plain Lua sum yields.
if e2 then
  local got = run_and_capture(e2)
  -- accept trailing whitespace / newlines from either the exe or the redirect
  local trimmed = got:gsub("%s+$", "")
  if trimmed ~= "450" then
    fail("-O2 exe printed %q, expected \"450\" ((10+20+30+40+50)*3). The inline "
         .. "path is returning wrong values -- check the isempty / bounds "
         .. "polarity.", trimmed)
  end
end

if #failures == 0 then
  print(("[+] PASS %s: -O2 emits one fast prefix per literal-indexed GETI; -O2 stdout matches")
        :format(NAME))
  os.exit(0)
end

for _, f in ipairs(failures) do print(("[-] FAIL %s: %s"):format(NAME, f)) end
os.exit(1)
