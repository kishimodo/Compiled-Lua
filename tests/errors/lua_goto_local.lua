-- @expect error
-- @line 6
-- @contains "jumps into the scope of local"
-- @hint "the goto would skip the local's initializer"
-- @code E_LUA_GOTO_LOCAL
goto skip
local x = 1
::skip::
print(x)
