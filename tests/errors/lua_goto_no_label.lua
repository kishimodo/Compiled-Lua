-- @expect error
-- @line 6
-- @contains "no visible label"
-- @hint "declare '::missing::' somewhere reachable"
-- @code E_LUA_GOTO_NOLABEL
goto missing
print("unreachable")
