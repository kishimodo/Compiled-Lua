-- mfpkg.helper -- a NON-entry-point file. Whole-tree integrity must cover this:
-- swapping this file (without touching init.lua) must make `verify` fail.
local H = {}
function H.tag() return "genuine-helper" end
return H
