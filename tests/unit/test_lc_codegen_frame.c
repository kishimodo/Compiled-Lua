/* test_lc_codegen_frame.c -- LuaC AOT codegen frame scaffolding.
 *
 * Exercises the ported frame helpers (LcCg_EmitPrologue/EmitEpilogue/
 * EmitRestoreL/EmitReloadRdiAndCache + LcCg_EmitHelperCall3) against a real
 * LcCodeBuf, asserting the recognizable boundary bytes of the frame. The frame
 * shape is the v1 JIT frame (the removed v1 JIT codegen) minus the M0 cache loop:
 *   prologue: PUSH RDI,RBX,R12,R13,R14,R15,RSI ; SUB RSP,0x20 ; RBX=L ;
 *             RAX=[RCX+ci]; RAX=[RAX+ci.func]; RDI=RAX ; ADD RDI,16
 *   epilogue: ADD RSP,0x20 ; POP RSI,R15,R14,R13,R12,RBX,RDI ; RET
 */
#include "test_harness.h"
#include "codegen/codegen.h"
#include "codegen/x64_emit.h"

int main( void ) {
    LcCodeBuf B;
    TEST_BEGIN( "lc_codegen_frame" );

    CHECK( LcCodeBuf_Init( &B, 64 ) == 1 );

    /* ---- prologue ---- */
    CHECK( LcCg_EmitPrologue( &B ) == 1 );
    size_t after_prologue = B.used;
    CHECK( after_prologue > 8 );        /* 7 pushes + sub rsp + several movs + add */
    CHECK( B.bytes[0] == 0x57 );        /* PUSH RDI (reg 7, no REX) */
    CHECK( B.bytes[1] == 0x53 );        /* PUSH RBX (reg 3, no REX) */
    /* PUSH R12 needs REX.B: 41 54 */
    CHECK( B.bytes[2] == 0x41 && B.bytes[3] == 0x54 );

    /* ---- epilogue ---- */
    CHECK( LcCg_EmitEpilogue( &B ) == 1 );
    CHECK( B.used > after_prologue );
    CHECK( B.bytes[B.used - 1] == 0xC3 );  /* RET is the last byte */
    /* byte before RET is POP RDI (reg 7, no REX): 0x5F */
    CHECK( B.bytes[B.used - 2] == 0x5F );

    /* ---- ADD RDI,16 emitter is byte-correct (matches v1 hand bytes) ---- */
    LcCodeBuf C;
    CHECK( LcCodeBuf_Init( &C, 16 ) == 1 );
    CHECK( X64Emit_AddRegImm32( &C, X64_RDI, 16 ) == 1 );
    CHECK( C.used == 7 );
    CHECK( C.bytes[0] == 0x48 && C.bytes[1] == 0x81 && C.bytes[2] == 0xC7 );
    CHECK( C.bytes[3] == 0x10 && C.bytes[4] == 0x00 &&
           C.bytes[5] == 0x00 && C.bytes[6] == 0x00 );

    /* ---- EmitRestoreL is MOV RCX,RBX -> 48 89 D9 ---- */
    LcCodeBuf D;
    CHECK( LcCodeBuf_Init( &D, 16 ) == 1 );
    CHECK( LcCg_EmitRestoreL( &D ) == 1 );
    CHECK( D.used == 3 && D.bytes[0] == 0x48 && D.bytes[1] == 0x89 && D.bytes[2] == 0xD9 );

    /* ---- helper-call shim records one CALL rel32 reloc against the symbol ---- */
    LcCodeBuf E;
    CHECK( LcCodeBuf_Init( &E, 32 ) == 1 );
    CHECK( LcCg_EmitHelperCall3( &E, "Rt_Len", 1, 2, 3, 0 ) == 1 );
    CHECK( E.nrelocs == 1 && E.relocs[0].kind == LC_RELOC_REL32 );

    LcCodeBuf_Free( &B );
    LcCodeBuf_Free( &C );
    LcCodeBuf_Free( &D );
    LcCodeBuf_Free( &E );
    TEST_END();
}
