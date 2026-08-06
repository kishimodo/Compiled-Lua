-- @expect warning
-- @wflag -Wshadow
-- @line 8
-- @contains "shadow"
-- @hint "shadows earlier local 'x' on line 7"
-- @code W_SHADOW
local x = 1
local x = 2
print(x)
