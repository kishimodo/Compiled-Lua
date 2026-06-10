-- tests/packages/test_format.lua : the `format` Lua-source formatter.
-- Pure-Lua package (no external DLL). Asserts whitespace normalization,
-- requoting, the documented idempotency invariant, and the check()/diff()
-- contracts against KNOWN-CORRECT canonical Lua, not the formatter's own output.
local ok_req, format = pcall(require, "format")
if not ok_req then print("[~] SKIP test_format") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_format: " .. tostring(m)) end end

-- ===== Whitespace normalization (canonical reference values) =============
ok(format.format("local x=1+2")    == "local x = 1 + 2\n",  "spaces around = and binops")
ok(format.format("f(1,2,3)")       == "f(1, 2, 3)\n",       "space after commas, tight parens")
ok(format.format("a=b*c-d")        == "a = b * c - d\n",    "spaces around * and -")
ok(format.format("a . b : c ()")   == "a.b:c()\n",          "dot/colon/call kept tight")
ok(format.format("local t={1,2,3}")== "local t = {1, 2, 3}\n", "short table stays inline")

-- ===== Trailing-newline contract =========================================
ok(format.format("local x=1"):sub(-1) == "\n", "non-empty output ends with newline")
ok(format.format("")               == "",                  "empty input -> empty output (no added newline)")

-- ===== Requoting =========================================================
ok(format.format("local s='hi'")            == 'local s = "hi"\n', "single->double under default quote")
ok(format.format('local s="hi"')            == 'local s = "hi"\n', "double left as double (default)")
ok(format.format('local s="hi"', {quote="'"}) == "local s = 'hi'\n", "double->single under quote opt")
ok(format.format("local s='hi'", {quote='"'}) == 'local s = "hi"\n', "single->double under quote opt")
-- Bail-out: rewriting would have to (un)escape the target quote -> leave alone.
ok(format.format([[local s='a"b']], {quote='"'}) == [[local s = 'a"b']] .. "\n",
   "requote bails out when inner contains the target quote")

-- ===== Idempotency (the package's central documented invariant) ==========
-- format(format(x)) == format(x) for a spread of constructs.
local idem_inputs = {
  "local x=1+2", "if x then y=1 end", "local t={1,2,3}",
  "for i=1,10 do print(i) end", "local function f(a,b) return a+b end",
  "x = a and b or c", "local s = 'hi'", "y=foo.bar:baz(1,2)",
}
for _, src in ipairs(idem_inputs) do
  local once = format.format(src)
  ok(format.format(once) == once, "idempotent on: " .. src)
end

-- ===== check() agrees with "format(x) == x" ==============================
ok(format.check("local x = 1 + 2\n") == true,  "check() true on canonical form")
ok(format.check("local x=1")         == false, "check() false on non-canonical form")
for _, src in ipairs(idem_inputs) do
  ok(format.check(format.format(src)) == true, "check() true on own formatted output: " .. src)
end

-- ===== diff() contract ===================================================
ok(format.diff(format.format("local x=1+2")) == "", "diff() empty when already canonical")
local d = format.diff("local x=1")
ok(d ~= "", "diff() non-empty when input differs")
ok(d:find("--- original", 1, true) ~= nil, "diff() has '--- original' header")
ok(d:find("+++ formatted", 1, true) ~= nil, "diff() has '+++ formatted' header")
ok(d:find("-local x=1", 1, true) ~= nil, "diff() shows the removed original line")
ok(d:find("+local x = 1", 1, true) ~= nil, "diff() shows the added formatted line")

-- ===== format_file() (in place) ==========================================
do
  local tmp = os.tmpname()
  local wf = io.open(tmp, "wb"); wf:write("local q=1+1"); wf:close()
  local wrote, werr = format.format_file(tmp)
  ok(wrote == true and werr == nil, "format_file returns true,nil on success")
  local rf = io.open(tmp, "rb"); local got = rf and rf:read("*a"); if rf then rf:close() end
  ok(got == "local q = 1 + 1\n", "format_file rewrote the file canonically")
  os.remove(tmp)
end
do
  local okm, errm = format.format_file("Z:/no/such/dir/_format_missing_.lua")
  ok(okm == false and type(errm) == "string", "format_file returns false,<string> on a missing path")
end

-- ===== Statement / blank-line layout (FMT-001 + FMT-002, now fixed) =======
-- FMT-001: two statements separated by a SINGLE newline must stay on separate
-- lines (render now preserves top-level source newlines as soft breaks).
ok(format.format("local a=1\nlocal b=2") == "local a = 1\nlocal b = 2\n",
   "single-newline statement separator preserved (FMT-001)")
-- FMT-002: the documented default max_blank_lines=1 keeps ONE blank line.
ok(format.format("local a=1\n\nlocal b=2") == "local a = 1\n\nlocal b = 2\n",
   "default max_blank_lines=1 preserves one blank line (FMT-002)")
-- max_blank_lines=0 collapses blanks entirely.
ok(format.format("local a=1\n\n\nlocal b=2", {max_blank_lines=0}) == "local a = 1\nlocal b = 2\n",
   "max_blank_lines=0 collapses all blanks")

if fails == 0 then print("[+] PASS test_format") os.exit(0) else os.exit(1) end
