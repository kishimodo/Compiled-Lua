-- @expect warning
-- @wflag -Wunreachable
-- @line 9
-- @contains "unreachable"
-- @hint "statement follows an unconditional return"
-- @code W_UNREACHABLE
if true then
  return
end
print(1)
