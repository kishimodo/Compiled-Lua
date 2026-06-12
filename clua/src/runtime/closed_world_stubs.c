/* ------------------------------------------------------------------ */
/* Closed-world stubs (AOT-CLOSEDWORLD-002).                           */
/*                                                                     */
/* A compiled CLua program can never legally reach the Lua front-end:  */
/* load/loadstring/dofile/string.dump/dynamic require are compile      */
/* errors (src/driver/closed_world.c). The only references that drag   */
/* lparser.o/lcode.o/llex.o/lundump.o/ldump.o out of liblua54 are      */
/* core-side (ldo.c f_parser, lstate.c f_luaopen, lapi.c lua_dump) --  */
/* defining the four trigger symbols here keeps ld from ever           */
/* extracting those members (~34 KB of dead text per exe). A           */
/* closed-world-EVADING program (e.g. _G["lo".."ad"]) hits a runtime   */
/* error here instead of parsing -- a documented bounded divergence,   */
/* same class as AOT-DEBUGREFLECT-001.                                 */
/*                                                                     */
/* luaX_init is a no-op: it only interns + GC-pins the reserved words  */
/* for the lexer we just excluded (interning is content-based, so      */
/* semantics are unchanged; the pin is a pure GC optimization).        */
/*                                                                     */
/* TWO consumers, ONE source of truth:                                 */
/*   * static exes — aot_entry.c #includes this file, so aot_entry.o   */
/*     defines the stubs ahead of the archives on the link line,       */
/*     exactly as it always has (the static link is unchanged);        */
/*   * clua-rt.dll — compiled standalone (obj-aot pattern rule) into   */
/*     the shared runtime, whose ldo.o/lstate.o/lapi.o resolve the     */
/*     four symbols DLL-internally (the DLL carries no front-end       */
/*     either; see build/Makefile, clua-rt).                           */
/* ------------------------------------------------------------------ */
#include "lua.h"
#include "lobject.h"     /* luaO_pushfstring */
#include "ldo.h"         /* luaD_throw */
#include "lzio.h"        /* stub signatures (luaY_parser/luaU_*) */
#include "llex.h"
#include "lparser.h"
#include "lundump.h"

LUAI_FUNC LClosure *luaY_parser( lua_State *L, ZIO *z, Mbuffer *buff,
                                 Dyndata *dyd, const char *name,
                                 int firstchar ) {
    ( void )z; ( void )buff; ( void )dyd; ( void )name; ( void )firstchar;
    luaO_pushfstring( L, "source chunk loading is disabled in a compiled "
                         "CLua program (closed world)" );
    luaD_throw( L, LUA_ERRSYNTAX );
    return NULL;   /* unreachable */
}

LUAI_FUNC LClosure *luaU_undump( lua_State *L, ZIO *Z, const char *name ) {
    ( void )Z; ( void )name;
    luaO_pushfstring( L, "binary chunk loading is disabled in a compiled "
                         "CLua program (closed world)" );
    luaD_throw( L, LUA_ERRSYNTAX );
    return NULL;   /* unreachable */
}

LUAI_FUNC int luaU_dump( lua_State *L, const Proto *f, lua_Writer w,
                         void *data, int strip ) {
    /* lua_dump propagates nonzero; string.dump then raises its own
    ** "unable to dump given function" -- string.dump by name is already a
    ** compile error, so only evading programs see this. */
    ( void )L; ( void )f; ( void )w; ( void )data; ( void )strip;
    return 1;
}

LUAI_FUNC void luaX_init( lua_State *L ) {
    ( void )L;
}
