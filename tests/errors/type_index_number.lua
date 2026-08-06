-- @expect error
-- @line 6
-- @contains "attempt to index a number"
-- @hint "numbers have no fields"
-- @code E_TYPE_INDEX_NUMBER
local v = (42)[1]
print(v)
