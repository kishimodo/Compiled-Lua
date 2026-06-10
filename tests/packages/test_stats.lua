local stats = require "stats"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_stats: " .. tostring(m)) end end

local function approx(a, b, tol) return math.abs(a - b) <= (tol or 1e-6) end

-- t_test(sample, mu0, opts) returns a table with field .p_value (two-sided by
-- default; one-sided when opts.alternative is "greater"/"less").

-- A sample clearly greater than mu0=0.
local sample = {3, 4, 5, 6, 7}  -- mean 5
local g = stats.t_test(sample, 0, { alternative = "greater" })
local l = stats.t_test(sample, 0, { alternative = "less" })

-- Directional inequalities: sample above mu0 -> "greater" significant (p<0.5),
-- "less" non-significant (p>0.5).
ok(g.p_value < 0.5, "greater p should be < 0.5 for sample above mu0")
ok(l.p_value > 0.5, "less p should be > 0.5 for sample above mu0")

-- Complementarity identity: one-sided 'greater' p == 1 - 'less' p for same data.
ok(approx(g.p_value, 1 - l.p_value, 1e-6), "greater p should equal 1 - less p")

-- Opposite-side case (the bug the fix addresses): sample BELOW mu0 with
-- alternative='greater' must give p > 0.5, NOT a naive two_sided/2.
local below = {-7, -6, -5, -4, -3}  -- mean -5
local gb = stats.t_test(below, 0, { alternative = "greater" })
ok(gb.p_value > 0.5, "greater p must exceed 0.5 when sample is below mu0")

-- Two-sided p is unchanged and equals twice the smaller one-sided tail.
local two = stats.t_test(sample, 0)
ok(approx(two.p_value, 2 * g.p_value, 1e-6), "two-sided p == 2 * (smaller one-sided tail)")

-- Two-sample path honours the same directional logic.
local A = {10, 11, 12, 13, 14}
local B = {1, 2, 3, 4, 5}
local g2 = stats.t_test(A, B, { alternative = "greater" })
local l2 = stats.t_test(A, B, { alternative = "less" })
ok(g2.p_value < 0.5, "two-sample greater p < 0.5 when A > B")
ok(l2.p_value > 0.5, "two-sample less p > 0.5 when A > B")
ok(approx(g2.p_value, 1 - l2.p_value, 1e-6), "two-sample greater p == 1 - less p")

if fails == 0 then print("[+] PASS test_stats") os.exit(0) else os.exit(1) end
