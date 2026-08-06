/*
** stdlib_anchor_io.c -- the io library's opt-in anchor. One anchor per
** translation unit, on purpose: see runtime/stdlib_anchor.h.
*/
#include "stdlib_anchor.h"

CLUA_STDLIB_ANCHOR( Clua_OpenIolib, LUA_IOLIBNAME, luaopen_io )
