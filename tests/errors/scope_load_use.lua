-- @expect error
-- @line 6
-- @contains "load()"
-- @hint "closed world: no interpreter or parser is bundled"
-- @code E_SCOPE_LOAD
local f = load("return 1")
print(f())
