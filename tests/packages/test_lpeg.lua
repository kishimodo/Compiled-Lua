-- tests/packages/test_lpeg.lua : LPeg '/' (division/transform) captures and
-- fixed-length look-behind. Assertions use spec-correct reference values, so
-- they hold for both the native lpeg and the pure-Lua fallback. Compiled to a
-- standalone exe by the runner (which bundles the lpeg package) and run.
local lpeg = require "lpeg"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_lpeg: " .. tostring(m)) end end

local P, C, Cs, R = lpeg.P, lpeg.C, lpeg.Cs, lpeg.R

-- '/' string substitution: replace each 'a' with 'X', keep other chars.
ok(lpeg.match(Cs((P'a'/'X' + P(1))^0), 'aba') == 'XbX',  "div: string replace inside Cs")

-- '/' with %N positional substitution.
local num = C(R'09'^1)
ok(lpeg.match(num * P'-' * num / '%2/%1', '7-9') == '9/7', "div: %N substitution")

-- '/' with %0 (whole match).
ok(lpeg.match(C(R'09'^1) / '[%0]', '77') == '[77]',       "div: %0 whole match")

-- '/' function: its return becomes the capture.
ok(lpeg.match(C(R'09'^1) / function(s) return tonumber(s) * 2 end, '21') == 42,
   "div: function transform")

-- '/' table: capture indexes the table.
ok(lpeg.match(C(R'az'^1) / { foo = 99 }, 'foo') == 99,    "div: table index")

-- '/' number: keep the Nth capture.
ok(lpeg.match((C(R'09') * C(R'09')) / 2, '42') == '2',    "div: keep Nth capture")

-- Fixed-length look-behind: B(P'ab') is 2 chars; succeeds right after "ab".
ok(lpeg.match(P(1) * P(1) * lpeg.B(P'ab') * C(P(1)), 'abc') == 'c',
   "B: 2-char literal look-behind")

-- Look-behind length computed over a seq of single-byte patterns (range+any).
ok(lpeg.match(P(2) * lpeg.B(R'az' * P(1)) * C(P(1)), 'abZ') == 'Z',
   "B: fixed length of seq")

if fails == 0 then print("[+] PASS test_lpeg") os.exit(0) else os.exit(1) end
