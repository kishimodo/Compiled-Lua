-- aot_debugreflect.lua — a module that materializes the global environment as a
-- value (so a dynamic key could reach debug.setlocal) must produce output
-- identical to the interpreter at -O0 AND -O1. At -O1 the optimizer disables
-- its proof-producing type inference for exactly this shape
-- (AOT-DEBUGREFLECT-001): once _G/_ENV is hoisted to a first-class value, the
-- static INT/FLT proofs can no longer be trusted (a dynamically fetched
-- debug.setlocal could rewrite a live local), so the checked dynamic path runs.
-- Plain global reads and local indexing are unaffected. Deterministic stdout.

-- Hoist the global table as a value, then fetch libraries through it WITHOUT
-- their literal names — the pattern that evades the "debug" constant scan.
local g       = _G
local mathlib = g[("ma") .. ("th")]
local dbg     = g[("de") .. ("bug")]

print("has-math", type(mathlib) == "table")
print("has-debug", type(dbg) == "table")

-- A hot integer loop whose result a stale INT proof would corrupt. With proofs
-- disabled for this (globals-materializing) module, the sum is exact.
local sum = 0
for i = 1, 1000 do
    sum = sum + i * 3
end
print("int-sum", sum)                       -- 3 * (1000*1001/2) = 1501500

-- Mixed int/float arithmetic through a dynamically fetched builtin.
local acc = 0.0
for i = 1, 10 do
    acc = acc + mathlib.sqrt(i * i)         -- == i (exact in float for these)
end
print("float-acc", acc)                     -- 55.0

-- Dynamic global write + read round-trip (SETTABUP / GETTABUP on _ENV).
g["__probe_value"] = 7 * 6
print("dyn-global", _G["__probe_value"])    -- 42

-- Reading a plain global by literal name still works (and, in a separate
-- function, would keep its proofs — this file just checks correctness).
print("type-tostring", type(tostring))      -- function
