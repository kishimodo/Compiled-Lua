-- JIT-vs-interpreter equivalence for OP_SELF method dispatch, including method
-- names longer than LUAI_MAXSHORTLEN (40 chars). Such a name interns as a LONG
-- string; Rt_Self must resolve it with luaH_getstr, not luaH_getshortstr (which
-- reads a long string's lazily-computed hash before it exists). Deterministic
-- prints; the runner diffs JIT stdout against the interpreter.
local t = {}
function t:m(x) return x + 1 end
function t:this_is_a_really_long_method_name_well_over_forty_chars(a, b) return a * b end
function t:another_extremely_long_method_identifier_beyond_forty_chars() return "ok" end
print(t:m(41))
print(t:this_is_a_really_long_method_name_well_over_forty_chars(6, 7))
print(t:another_extremely_long_method_identifier_beyond_forty_chars())
-- methods routed through a metatable __index (string library)
print(("hello"):upper())
print(("HELLO"):sub(2, 4))
-- self on a table whose method comes from an __index metatable
local base = { greet = function(self, who) return "hi " .. who end }
local obj = setmetatable({}, { __index = base })
print(obj:greet("world"))
