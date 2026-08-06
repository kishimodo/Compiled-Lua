-- @expect error
-- @line any
-- @contains "non-closable"
-- @hint "value assigned to <close> must have a __close metamethod (or be nil/false)"
-- @code E_LUA_CLOSE_NONCLOSE
local x <close> = 5
print(x)
