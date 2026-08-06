/*
** stdlib_anchor_math.c -- the math library's opt-in anchor. One anchor per
** translation unit, on purpose: see runtime/stdlib_anchor.h.
*/
#include "stdlib_anchor.h"

CLUA_STDLIB_ANCHOR( Clua_OpenMathlib, LUA_MATHLIBNAME, luaopen_math )
