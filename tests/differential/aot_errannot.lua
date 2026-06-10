-- LUAC-002: error messages carry operand-name annotations (field/global/len),
-- matching the interpreter. Uses an intervening op so the operand is reloaded
-- (LUAC-003: a bare arith-error immediately after a fresh-local load in a pcall'd
-- function can mis-report the operand *type* — narrow, value-correct edge).
local t = {}
print(pcall(function() return t.x.y end))
print(pcall(function() return undefined_global() end))
print(pcall(function() local m = {}; return #m.missing end))
print(pcall(function() local s = "s"; local r = s; return r.field end))
