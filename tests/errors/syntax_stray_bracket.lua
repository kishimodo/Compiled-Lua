-- @expect error
-- @line 6
-- @contains "unexpected symbol"
-- @hint "no matching '['"
-- @code E_SYNTAX_BRACKET
local t = {1, 2, ]}
print(t)
