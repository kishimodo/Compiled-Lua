/*
** stdlib_anchor_table.c -- the table library's opt-in anchor. One anchor per
** translation unit, on purpose: see runtime/stdlib_anchor.h.
*/
#include "stdlib_anchor.h"

CLUA_STDLIB_ANCHOR( Clua_OpenTablib, LUA_TABLIBNAME, luaopen_table )
