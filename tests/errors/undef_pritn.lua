-- @expect error
-- @line 7
-- @contains "did you mean 'print'"
-- @hint "typo: closest name in scope is 'print'"
-- @code E_DID_YOU_MEAN
-- 'pritn' is not defined; a did-you-mean pass should suggest 'print'.
pritn("hi")
