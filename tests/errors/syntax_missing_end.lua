-- @expect error
-- @line any
-- @contains "'end' expected"
-- @hint "block opened earlier was never closed"
-- @code E_SYNTAX_END
local function foo(x)
  return x + 1

