/*
** stdlib_anchor_string.c -- the string library's opt-in anchor. One anchor per
** translation unit, on purpose: see runtime/stdlib_anchor.h.
*/
#include "stdlib_anchor.h"

CLUA_STDLIB_ANCHOR( Clua_OpenStrlib, LUA_STRLIBNAME, luaopen_string )
