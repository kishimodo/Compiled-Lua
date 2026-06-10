#include "test_harness.h"
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lobject.h"
#include "driver/lc_undump.h"

typedef struct { unsigned char *p; size_t len, cap; } DumpBuf;

static int Writer( lua_State *L, const void *p, size_t sz, void *ud ) {
    (void)L;
    DumpBuf *b = (DumpBuf *)ud;
    if ( b->len + sz > b->cap ) return 1;   /* overflow -> error */
    memcpy( b->p + b->len, p, sz );
    b->len += sz;
    return 0;
}

int main( void ) {
    lua_State *L = luaL_newstate();
    Proto *P;
    static unsigned char buf[65536];
    DumpBuf db;

    TEST_BEGIN( "lc_undump" );

    CHECK( luaL_loadstring( L, "return 1 + 2" ) == LUA_OK );   /* pushes a closure */

    db.p   = buf;
    db.len = 0;
    db.cap = sizeof buf;
    CHECK( lua_dump( L, Writer, &db, 0 ) == 0 );   /* dump the top closure */
    lua_pop( L, 1 );                               /* remove source closure */

    P = Lc_Undump( L, db.p, db.len );
    CHECK( P != NULL );
    CHECK( P->sizecode > 0 );

    lua_close( L );
    TEST_END();
}
