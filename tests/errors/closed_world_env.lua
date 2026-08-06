-- @expect error
-- @line 7
-- @contains "closed world"
-- @hint "dynamic _ENV access defeats dead-global pruning"
-- @code E_SCOPE_DYN_ENV
local key = "print"
-- _ENV[<non-literal>] cannot be pruned at build time
_ENV[key]("hi")
