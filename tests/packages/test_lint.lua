-- tests/packages/test_lint.lua : luacheck-lite linter. Deterministic: we feed
-- fixed source strings and assert exact issue codes/lines/severities.
local ok_req, lint = pcall(require, "lint")
if not ok_req then print("[~] SKIP test_lint (" .. tostring(lint) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_lint: " .. tostring(m)) end end
-- XFAIL helper: assert the CORRECT behavior for a known, unfixed bug without
-- failing the run; flips to XPASS when the bug is fixed.
local function xfail(cond, desc, bug)
    if cond then print(("[!] XPASS test_lint: %s -- bug %s appears FIXED, remove this xfail"):format(desc, bug))
    else        print(("[x] XFAIL test_lint: %s (known bug %s)"):format(desc, bug)) end
end

-- Helper: does the issue list contain a code (optionally at a given line)?
local function has(issues, code, line)
    for _, iss in ipairs(issues) do
        if iss.code == code and (line == nil or iss.line == line) then return iss end
    end
    return nil
end
local function count(issues, code)
    local n = 0
    for _, iss in ipairs(issues) do if iss.code == code then n = n + 1 end end
    return n
end

-- Lexer is exposed; tokenize a tiny source and check kinds/values.
local toks = lint.lex("local x = 42")
ok(toks[1].kind == "keyword" and toks[1].value == "local", "lex: first token is keyword local")
ok(toks[2].kind == "ident"   and toks[2].value == "x",      "lex: second token is ident x")
ok(toks[3].kind == "punct"   and toks[3].value == "=",      "lex: third token is = punct")
ok(toks[4].kind == "number"  and toks[4].value == "42",     "lex: number literal 42")
ok(toks[#toks].kind == "eof",                                "lex: stream ends with eof")

-- Clean program with NO function params: zero issues. (Param recognition is
-- broken -- see the LINT-PARAMS xfail below -- so keep this clean case
-- param-free to assert the genuinely-working clean path.)
local clean = lint.check("local x = 1\nlocal y = 2\nreturn x + y\n")
ok(#clean == 0, "clean param-free source produces no issues (got " .. #clean .. ")")

-- BUG (LINT-PARAMS-001): function parameters are reported as undefined globals.
-- declare_params() is DEFINED in lint/init.lua but NEVER CALLED at either the
-- `local function`/`function` site, so params are never declared as locals.
-- CORRECT behavior: `local function add(a,b) return a+b end` has ZERO issues.
-- ACTUAL: 4x E001 "undefined global 'a'/'b'". Affects all function forms.
local with_params = lint.check("local function add(a, b) return a + b end\nreturn add(1, 2)\n")
ok(#with_params == 0,
   "function params should not be flagged as undefined globals (regression LINT-PARAMS-001)")

-- Unused local -> W001 (warning) at the right line.
local unused = lint.check("local function f()\n  local y = 5\n  return 1\nend\nreturn f\n")
local w1 = has(unused, "W001")
ok(w1 ~= nil, "unused local triggers W001")
ok(w1 and w1.severity == "warning", "W001 severity is warning")
ok(w1 and w1.line == 2, "W001 reported on line 2 of the unused decl")

-- Underscore-prefixed locals are intentionally NOT flagged as unused.
local underscore = lint.check("local _unused = 1\nreturn 0\n")
ok(count(underscore, "W001") == 0, "underscore local is exempt from W001")

-- Undefined global -> E001 (error).
local undef = lint.check("return notdefinedglobal\n")
local e1 = has(undef, "E001")
ok(e1 ~= nil, "undefined global triggers E001")
ok(e1 and e1.severity == "error", "E001 severity is error")

-- A known std global (print) is allowed.
local stdg = lint.check("print('hi')\nreturn 1\n")
ok(count(stdg, "E001") == 0, "std global 'print' is not flagged")

-- opts.globals allowlist suppresses an otherwise-undefined global.
local allow = lint.check("return myglobal\n", { globals = { "myglobal" } })
ok(count(allow, "E001") == 0, "opts.globals allowlists a custom global")

-- opts.ignore suppresses a code entirely.
local ignored = lint.check("local z = 1\nreturn 0\n", { ignore = { "W001" } })
ok(count(ignored, "W001") == 0, "opts.ignore suppresses W001")

-- Syntax error -> E002. (Use an incomplete-expression form that does NOT trip
-- the nameless-local crash below.)
local syn = lint.check("local a = 1 +\nreturn a\n")
ok(has(syn, "E002") ~= nil, "syntax error triggers E002")

-- BUG (LINT-CRASH-001): lint.check() throws (instead of reporting E002) on a
-- malformed `local` with no names, e.g. `local = = =`. The token walker's
-- W003 branch dereferences names[1].line at lint/init.lua:429 without guarding
-- the empty-names case. check() must NEVER throw -- it has a load()-based E002
-- syntax check for exactly this. CORRECT: pcall succeeds + reports E002.
local crash_ok, crash_res = pcall(lint.check, "local = = =\n")
ok(crash_ok and has(crash_res, "E002") ~= nil,
   "check() must not throw on a nameless 'local =' (regression LINT-CRASH-001)")

-- Trailing whitespace -> W008.
local trail = lint.check("local q = 1   \nreturn q\n")
ok(has(trail, "W008", 1) ~= nil, "trailing whitespace triggers W008 on line 1")

-- max_line_length -> W007.
local longln = lint.check("local s = '" .. string.rep("x", 50) .. "'\nreturn s\n",
                          { max_line_length = 20 })
ok(has(longln, "W007", 1) ~= nil, "over-length line triggers W007")

-- Formatter: text output contains code + severity.
local txt = lint.format(undef, "text")
ok(txt:find("E001", 1, true) ~= nil, "format(text) mentions the E001 code")
ok(txt:find("error", 1, true) ~= nil, "format(text) mentions the severity")

-- Formatter: github-actions style uses the ::error annotation.
local gh = lint.format(undef, "github-actions")
ok(gh:find("::error", 1, true) ~= nil, "format(github-actions) uses ::error annotation")

-- Issues are sorted by (line, col, code): verify lines are nondecreasing.
local multi = lint.check("local a = 1\nlocal b = 2\nreturn nope\n")
local prev_line = 0
local sorted = true
for _, iss in ipairs(multi) do
    if iss.line < prev_line then sorted = false end
    prev_line = iss.line
end
ok(sorted, "issues are returned in nondecreasing line order")

-- lint() / lint_file() aliases exist and behave like check().
ok(type(lint.lint) == "function", "lint.lint alias exists")
local aliased = lint.lint("return notdefinedglobal\n")
ok(has(aliased, "E001") ~= nil, "lint() alias produces same E001 as check()")

if fails == 0 then print("[+] PASS test_lint") os.exit(0) else os.exit(1) end
