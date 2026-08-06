-- @expect error
-- @line 6
-- @contains "attempt to perform arithmetic"
-- @hint "convert with tonumber()"
-- @code E_TYPE_ARITH
local x = "a" + 1
print(x)
