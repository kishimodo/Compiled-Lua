-- @expect error
-- @line 6
-- @contains "attempt to concatenate a nil value"
-- @hint "coerce with tostring() before .."
-- @code E_TYPE_CONCAT
local s = "x" .. nil
print(s)
