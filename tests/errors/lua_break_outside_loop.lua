-- @expect error
-- @line 6
-- @contains "break outside a loop"
-- @hint "break is only valid inside for/while/repeat"
-- @code E_LUA_BREAK_OUTSIDE
break
