-- tools/test-inline-gettable-fastpath.lua : OP_GETTABLE array fast path lands at -O2 only.
--
-- Auto-discovered by tools/run-tests.lua (phase 6).
--
-- The claim under test: at -O2, codegen emits a runtime-checked prefix in
-- front of the Rt_GetTableF call for OP_GETTABLE (variable-index table
-- read). At -O0/-O1 it does not, keeping those tiers unchanged. The -O2
-- exe's stdout still matches the interpreter oracle for the same source.
--
-- Difference from the OP_GETI test: OP_GETI bakes a literal integer key
-- into the instruction (e.g. t[3]) so the fast path can commit to the
-- integer probe unconditionally. OP_GETTABLE's key sits in a register
-- (e.g. t[i]) and can be anything at runtime, so the fast prefix guards
-- on BOTH the table tag AND the key tag before the array probe. Detection
-- pattern here matches the paired tag checks:
--    80 7F <dispB>  45   -- cmp byte [rdi + B*16 + 8], 0x45 (VTABLE)
--    75 <rel8>            -- jne slow
--    80 7F <dispC>  03   -- cmp byte [rdi + C*16 + 8], 0x03 (VNUMINT)
-- That is 12 ordered bytes with a strict interior structure; it is
-- specific enough to the paired shape that it cannot line up in a plain
-- Rt_GetTableF call site or in the runtime bundle.
--
-- If build/bin/clua.exe is missing (a workspace that has not been built),
-- the test SKIPs rather than fails; the byte-identity gate is what proves
-- the -O0/-O1 no-op property in CI-like runs.

local NAME = "test-inline-gettable-fastpath"
local CLUA = "build\\bin\\clua.exe"
local TMP  = (os.getenv("TEMP") or os.getenv("TMP") or ".") .. "\\clua-inline-gettable"

local function file_exists(p)
  local f = io.open(p, "rb"); if not f then return false end
  f:close(); return true
end

if not file_exists(CLUA) then
  print(("[~] SKIP %s: %s not built (workspace was not compiled)"):format(NAME, CLUA))
  os.exit(0)
end

os.execute('if not exist "' .. TMP .. '" mkdir "' .. TMP .. '" >nul 2>&1')

-- OP_GETTABLE is emitted when the index is a REGISTER, not a literal
-- integer constant (`t[i]`); `t[3]` compiles to OP_GETI (covered by
-- test-inline-table-fastpath.lua). The fixture reads three variable-
-- indexed slots inside a loop so the sites stay in .text and the
-- structural check can find them by pattern.
--
-- Expected output: 3 * (10 + 20 + 30) = 180 per iteration times 10 = 600.
local SRC = [[
local t = {10, 20, 30}
local i = 1
local s = 0
for _ = 1, 10 do
  s = s + t[i] + t[i+1] + t[i+2]
end
print(s)
]]

local function write_src(path)
  local f = assert(io.open(path, "wb"))
  f:write(SRC); f:close()
end

local function build(level)
  local src = TMP .. "\\gettable_" .. level .. ".lua"
  local exe = TMP .. "\\gettable_" .. level .. ".exe"
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

-- The fast prefix's opening 12 bytes (for small B and C -- disp8 form
-- on both tag checks):
--   80 7F <dispB>  45   -- cmp byte [rdi + B*16 + 8], 0x45
--   75 <rel8>            -- jne slow
--   80 7F <dispC>  03   -- cmp byte [rdi + C*16 + 8], 0x03
--   75                   -- jne slow (opcode of the second JNE)
-- We do NOT constrain rel8 bytes or the exact displacements, but we do
-- pin the opcodes and the two immediates (0x45 for table, 0x03 for
-- integer) so a coincidental match in the runtime library is
-- vanishingly unlikely. Matching on this joint shape ALSO rules out
-- the single-tag prefix that lower_geti_inline emits (that path has
-- only one 80 7F .. 45 sequence, not two 80 7F .. tag pairs in a row).
-- CmpMem8Imm8( RDI, disp, imm ) uses two encodings:
--   disp fits int8_t:  80 7F <disp8>  imm8    (mod=01, ModR/M=0x7F)
--   otherwise:         80 BF <disp32> imm8    (mod=10, ModR/M=0xBF)
-- Both encodings appear in real programs (a register index of 8 already
-- pushes disp = 8*16+8 = 136 above int8_t). Match either form for both the
-- table-tag CMP and the key-tag CMP that immediately follows it, so the
-- test counts every fast-prefix site regardless of which pair of
-- encodings landed for the given B and C registers.
local function is_cmp_rdi_imm(data, i, imm)
  -- returns the length in bytes (4 or 7) if data starting at i is
  --   cmp byte [rdi + disp], imm
  -- else returns 0. The two forms differ only in ModR/M + disp width.
  if data:byte(i) ~= 0x80 then return 0 end
  local modrm = data:byte(i + 1)
  if modrm == 0x7F and data:byte(i + 3) == imm then return 4 end   -- disp8
  if modrm == 0xBF and data:byte(i + 6) == imm then return 7 end   -- disp32
  return 0
end
local function count_fast_prefix(data)
  local n = #data
  local hits = 0
  local i = 1
  while i <= n - 14 do   -- worst case: two disp32 cmps back to back = 14 bytes
    local w1 = is_cmp_rdi_imm(data, i, 0x45)                          -- table tag
    if w1 > 0 and data:byte(i + w1) == 0x75 then                     -- jne rel8
      local j = i + w1 + 2
      local w2 = is_cmp_rdi_imm(data, j, 0x03)                        -- int-key tag
      if w2 > 0 and data:byte(j + w2) == 0x75 then                    -- jne rel8
        hits = hits + 1
      end
    end
    i = i + 1
  end
  return hits
end

local function run_and_capture(exe)
  local out = TMP .. "\\gettable_run.txt"
  os.remove(out)
  os.execute('"' .. string.format('"%s" > "%s" 2>&1', exe, out) .. '"')
  local h = io.open(out, "rb")
  if not h then return "" end
  local s = h:read("*a"); h:close()
  return s
end

local failures = {}
local function fail(fmt, ...) failures[#failures + 1] = string.format(fmt, ...) end

-- The fixture reads three variable-indexed slots (t[i], t[i+1], t[i+2]);
-- the inline path fires on each, so -O2 must have STRICTLY MORE hits than
-- -O0 by exactly that count. We tolerate incidental matches in the runtime
-- bundle by comparing (n2 - n0) rather than n2 alone.
local FIXTURE_GETTABLE_COUNT = 3

local d0, e0, err0 = build(0)
local d1, e1, err1 = build(1)
local d2, e2, err2 = build(2)
if not d0 then fail("build -O0 failed: %s", err0) end
if not d1 then fail("build -O1 failed: %s", err1) end
if not d2 then fail("build -O2 failed: %s", err2) end

if d0 and d1 and d2 then
  local n0 = count_fast_prefix(d0)
  local n1 = count_fast_prefix(d1)
  local n2 = count_fast_prefix(d2)
  local excess = n2 - n0
  if excess ~= FIXTURE_GETTABLE_COUNT then
    fail("expected -O2 to have exactly %d more fast-prefix hits than -O0 "
         .. "(one per variable-indexed GETTABLE in the fixture), but got "
         .. "n0=%d n1=%d n2=%d excess=%d. Either the gate is emitting the "
         .. "prefix at -O0/-O1 (should not) or is not emitting it at -O2 "
         .. "(should).",
         FIXTURE_GETTABLE_COUNT, n0, n1, n2, excess)
  end
  -- -O1 must keep the -O0 byte behaviour on this fixture (the arc is
  -- gated on opt_level >= 2 specifically).
  if n1 ~= n0 then
    fail("expected -O1 to have the SAME fast-prefix count as -O0 (the "
         .. "OP_GETTABLE inline is gated at -O2), but n0=%d n1=%d.",
         n0, n1)
  end
end

-- End-to-end at every tier: the exe's stdout must match what the plain
-- interpreter oracle yields. Sum is (10+20+30) * 10 = 600 for the fixture.
local function check_stdout(exe, label)
  if not exe then return end
  local got = run_and_capture(exe)
  local trimmed = got:gsub("%s+$", "")
  if trimmed ~= "600" then
    fail("-%s exe printed %q, expected \"600\" ((10+20+30)*10). The %s "
         .. "path is returning wrong values -- check the tag / bounds / "
         .. "empty polarity.", label, trimmed, label)
  end
end
check_stdout(e0, "O0")
check_stdout(e1, "O1")
check_stdout(e2, "O2")

if #failures == 0 then
  print(("[+] PASS %s: -O2 emits one fast prefix per variable-indexed "
         .. "GETTABLE; -O0/-O1/-O2 stdout all match"):format(NAME))
  os.exit(0)
end

for _, f in ipairs(failures) do print(("[-] FAIL %s: %s"):format(NAME, f)) end
os.exit(1)
