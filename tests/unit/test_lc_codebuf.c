#include "test_harness.h"
#include "codegen/lc_codebuf.h"

int main( void ) {
    uint8_t three[3] = { 0x90, 0x91, 0x92 };
    LcCodeBuf B;
    TEST_BEGIN( "lc_codebuf" );
    CHECK( LcCodeBuf_Init( &B, 4 ) == 1 );
    CHECK( LcCodeBuf_Append( &B, three, 3 ) == 1 );
    CHECK( LcCodeBuf_Append( &B, three, 3 ) == 1 );   /* forces a grow past cap 4 */
    CHECK( B.used == 6 );
    CHECK( B.bytes[4] == 0x91 );
    CHECK( LcCodeBuf_AddReloc( &B, LC_RELOC_REL32, 1, "Rt_Len", 0 ) == 1 );
    CHECK( B.nrelocs == 1 );
    CHECK( B.relocs[0].offset == 1 );
    LcCodeBuf_Free( &B );
    TEST_END();
}
