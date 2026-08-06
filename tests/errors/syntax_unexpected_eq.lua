-- @expect error
-- @line 7
-- @contains "'then' expected"
-- @hint "use == for comparison, = is assignment"
-- @code E_SYNTAX_EQ
local x = 1
if x = 1 then
  print("nope")
end
