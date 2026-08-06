-- @expect error
-- @line 7
-- @contains "attempt to index a nil value"
-- @hint "value was never assigned a table"
-- @code E_TYPE_INDEX_NIL
local t
-- t is nil; indexing nil is a runtime type error the compiler can flag
return t.x
