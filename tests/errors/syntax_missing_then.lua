-- @expect error
-- @line 7
-- @contains "'then' expected"
-- @hint "if <expr> then ... end"
-- @code E_SYNTAX_THEN
local x = 1
if x
  print("no then")
end
