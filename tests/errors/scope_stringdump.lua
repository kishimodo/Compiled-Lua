-- @expect error
-- @line 7
-- @contains "string.dump"
-- @hint "closed world: no bytecode loader to consume it"
-- @code E_SCOPE_STRINGDUMP
local function f() return 1 end
local blob = string.dump(f)
print(#blob)
