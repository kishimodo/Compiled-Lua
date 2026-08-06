-- @expect error
-- @line any
-- @contains "syntax levels"
-- @hint "Lua 5.4 permits at most 200 syntactic nesting levels"
-- @code E_LUA_SYNTAX_LEVELS
-- 200+ nested `do ... end` blocks trip lparser's LUAI_MAXCCALLS ceiling
-- (the C-stack safety valve that bounds subgrammar recursion depth).
do do do do do do do do do do do do do do do do do do do do
do do do do do do do do do do do do do do do do do do do do
do do do do do do do do do do do do do do do do do do do do
do do do do do do do do do do do do do do do do do do do do
do do do do do do do do do do do do do do do do do do do do
do do do do do do do do do do do do do do do do do do do do
do do do do do do do do do do do do do do do do do do do do
do do do do do do do do do do do do do do do do do do do do
do do do do do do do do do do do do do do do do do do do do
do do do do do do do do do do do do do do do do do do do do
do do do do do do do do do do do do do do do do do do do do
return true
end end end end end end end end end end end end end end end end end end end end
end end end end end end end end end end end end end end end end end end end end
end end end end end end end end end end end end end end end end end end end end
end end end end end end end end end end end end end end end end end end end end
end end end end end end end end end end end end end end end end end end end end
end end end end end end end end end end end end end end end end end end end end
end end end end end end end end end end end end end end end end end end end end
end end end end end end end end end end end end end end end end end end end end
end end end end end end end end end end end end end end end end end end end end
end end end end end end end end end end end end end end end end end end end end
end end end end end end end end end end end end end end end end end end end end
