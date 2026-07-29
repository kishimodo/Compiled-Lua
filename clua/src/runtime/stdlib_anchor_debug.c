/*
** stdlib_anchor_debug.c -- the debug library's opt-in anchor. One anchor per
** translation unit, on purpose: see runtime/stdlib_anchor.h.
*/
#include "stdlib_anchor.h"

CLUA_STDLIB_ANCHOR( Clua_OpenDbglib, LUA_DBLIBNAME, luaopen_debug )
