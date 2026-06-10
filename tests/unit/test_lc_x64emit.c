#include "test_harness.h"
#include "codegen/x64_emit.h"

int main( void ) {
    LcCodeBuf B;
    LcCodeBuf C;
    TEST_BEGIN( "lc_x64emit" );

    CHECK( LcCodeBuf_Init( &B, 16 ) == 1 );

    /* CALL rel32 to an external symbol: E8 + disp32=0, one REL32 reloc. */
    CHECK( X64Emit_CallSym( &B, "Rt_Len" ) == 1 );
    CHECK( B.used == 5 );
    CHECK( B.bytes[0] == 0xE8 );
    CHECK( B.nrelocs == 1 && B.relocs[0].kind == LC_RELOC_REL32 && B.relocs[0].offset == 1 );

    /* LEA RAX, [RIP + disp32] against a .rdata local symbol. */
    CHECK( X64Emit_LeaRipSym( &B, X64_RAX, "k0_str" ) == 1 );
    CHECK( B.bytes[5] == 0x48 && B.bytes[6] == 0x8D && B.bytes[7] == 0x05 );
    CHECK( B.nrelocs == 2 && B.relocs[1].kind == LC_RELOC_REL32_RDATA );

    /* sanity: a couple of plain encoder ops still produce correct bytes */
    CHECK( LcCodeBuf_Init( &C, 16 ) == 1 );
    CHECK( X64Emit_Ret( &C ) == 1 && C.used == 1 && C.bytes[0] == 0xC3 );

    /* MOV RAX, RCX  -> 48 89 C8 (mod=11 reg=RCX rm=RAX). */
    LcCodeBuf_Free( &C );
    CHECK( LcCodeBuf_Init( &C, 16 ) == 1 );
    CHECK( X64Emit_MovRegToReg( &C, X64_RAX, X64_RCX ) == 1 );
    CHECK( C.used == 3 && C.bytes[0] == 0x48 && C.bytes[1] == 0x89 && C.bytes[2] == 0xC8 );

    LcCodeBuf_Free( &B );
    LcCodeBuf_Free( &C );
    TEST_END();
}
