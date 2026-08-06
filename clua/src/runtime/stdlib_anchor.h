/*!
 * @file stdlib_anchor.h
 * @brief
 *  The one-line body every optional-standard-library anchor shares.
 *
 *  aot_entry.c opens base/package/coroutine directly and reaches each OPTIONAL
 *  library through a WEAK reference to one of these anchors. The driver
 *  force-undefs (`-Wl,--undefined=` / the internal linker's force-undef roots)
 *  only the anchors a program can actually reach -- see lc_module_used_libs()
 *  in opt/passes.c, whose soundness argument is what makes dropping the rest
 *  legal. An anchor that is not force-undef'd is swept, its luaopen_* goes with
 *  it, and `&Clua_OpenXxx` is a weak-undefined null that aot_entry skips.
 *
 *  ONE ANCHOR PER TRANSLATION UNIT -- that is the entire point of this header
 *  existing instead of a single stdlib_anchors.c. Archive member selection runs
 *  before section GC, so a shared TU is pulled in by whichever anchor was
 *  wanted and then drags in every luaopen_* it references. Splitting them means
 *  a program that only needs string pulls only lstrlib.o. Measured on
 *  `local a,b=2,3 local c=a+b print(c)`, which needs string alone.
 *
 *  Do not add a second anchor to any of these files.
 */

#ifndef CLUA_STDLIB_ANCHOR_H
#define CLUA_STDLIB_ANCHOR_H

#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"

#define CLUA_STDLIB_ANCHOR( Fn, Name, Open )         \
    void Fn( lua_State *L ) {                        \
        luaL_requiref( L, ( Name ), ( Open ), 1 );   \
        lua_pop( L, 1 );                             \
    }

#endif /* CLUA_STDLIB_ANCHOR_H */
