/*
** stdlib_anchor_os.c -- the os library's opt-in anchor. One anchor per
** translation unit, on purpose: see runtime/stdlib_anchor.h.
*/
#include "stdlib_anchor.h"

CLUA_STDLIB_ANCHOR( Clua_OpenOslib, LUA_OSLIBNAME, luaopen_os )
