#include "driver/lc_undump.h"
#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lobject.h"

Proto *Lc_Undump( lua_State *L, const unsigned char *Bytes, size_t Len ) {
    if ( luaL_loadbufferx( L, ( const char * )Bytes, Len, "@aot", "b" ) != LUA_OK )
        return NULL;
    return ( Proto * )clLvalue( s2v( L->top.p - 1 ) )->p;   /* stays on L's stack */
}
