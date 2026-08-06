-- @expect warning
-- @wflag -Wunused
-- @line 7
-- @contains "Wunused"
-- @hint "unused local 'x'"
-- @code W_UNUSED_LOCAL
local x = 1
print("hello")
