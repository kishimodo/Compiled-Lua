-- @expect error
-- @line 7
-- @contains "attempt to call a nil value"
-- @hint "undefined name or missing initializer"
-- @code E_TYPE_CALL_NIL
local f
-- f was never assigned; calling nil is a runtime type error
f()
