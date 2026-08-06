-- @expect error
-- @line 6
-- @contains "unfinished string"
-- @hint "opened here"
-- @code E_SYNTAX_STRING
local s = "no closing quote here
print(s)
