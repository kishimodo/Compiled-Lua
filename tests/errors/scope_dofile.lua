-- @expect error
-- @line 6
-- @contains "dofile()"
-- @hint "closed world: bundle the file at build time"
-- @code E_SCOPE_DOFILE
local v = dofile("x.lua")
print(v)
