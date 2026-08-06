-- @expect error
-- @line 6
-- @contains "loadstring()"
-- @hint "closed world: no interpreter is bundled"
-- @code E_SCOPE_LOADSTRING
local f = loadstring("return 1")
print(f())
