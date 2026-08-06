/*
** stdlib_anchor_utf8.c -- the utf8 library's opt-in anchor. One anchor per
** translation unit, on purpose: see runtime/stdlib_anchor.h.
*/
#include "stdlib_anchor.h"

CLUA_STDLIB_ANCHOR( Clua_OpenUtf8lib, LUA_UTF8LIBNAME, luaopen_utf8 )
