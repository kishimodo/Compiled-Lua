-- @expect error
-- @line 7
-- @contains "const"
-- @hint "attempt to assign to const variable 'x'"
-- @code E_LUA_CONST_REASSIGN
local x <const> = 1
x = 2
print(x)
