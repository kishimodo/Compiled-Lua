-- @expect error
-- @line any
-- @contains "'end' expected"
-- @hint "return must be the last statement in its block"
-- @code E_LUA_RETURN_STMT
local function f()
  return
  x = 1
end
return f
