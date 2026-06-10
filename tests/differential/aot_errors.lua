-- Error-message fidelity (Plan 4 / LUAC-001): pcall catches errors and the
-- "source:line:" position prefix matches the interpreter (savedpc + lineinfo).
-- Only string error objects (table objects print non-deterministic addresses).
print(pcall(function() error("boom") end))
print(pcall(function() return (nil) + 1 end))
print(pcall(function() local s = "a" .. nil end))
local function deep(n) if n == 0 then error("deep error") end return deep(n - 1) end
print(pcall(deep, 5))
print(pcall(function() error("no position", 0) end))
print(pcall(function() return "ok", 1, 2 end))
