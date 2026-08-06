-- @expect error
-- @line 7
-- @contains "dynamic require"
-- @hint "AOT closed world: name must be a string literal"
-- @code E_SCOPE_DYN_REQUIRE
local x = "js" .. "on"
-- dynamic require: string built at runtime, not a literal
local m = require(x)
print(m)
