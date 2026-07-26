/* test_lc_codegen_frame.c -- LuaC AOT codegen frame scaffolding.
 *
 * Exercises the ported frame helpers (LcCg_EmitPrologue/EmitEpilogue/
 * EmitRestoreL/EmitReloadRdiAndCache + LcCg_EmitHelperCall3) against a real
 * LcCodeBuf, asserting the recognizable boundary bytes of the frame. The frame
 * shape is the v1 JIT frame (the removed v1 JIT codegen) minus the M0 cache
 * loop, plus RBP as the hoisted savedpc base (LUAC-001 size fix):
 *   prologue: PUSH RDI,RBX,R12,R13,R14,R15,RSI,RBP ; SUB RSP,0x28 ; RBX=L ;
 *             RAX=[RCX+ci]; RAX=[RAX+ci.func]; RDI=RAX ; ADD RDI,16 ;
 *             RBP=[RAX]; RBP=[RBP+LClosure.p]; RBP=[RBP+Proto.code]
 *   epilogue: ADD RSP,0x28 ; POP RBP,RSI,R15,R14,R13,R12,RBX,RDI ; RET
 *
 * The push/pop lists must stay exact mirrors: an asymmetric frame returns to
 * the runtime with a corrupt RSP, and 8 pushes + return address means the
 * reserve has to be 0x28 (not 0x20) to keep RSP 16-aligned at every call.
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
    CHECK( after_prologue > 8 );        /* 8 pushes + sub rsp + several movs + add */
    CHECK( B.bytes[0] == 0x57 );        /* PUSH RDI (reg 7, no REX) */
    CHECK( B.bytes[1] == 0x53 );        /* PUSH RBX (reg 3, no REX) */
    /* PUSH R12 needs REX.B: 41 54 */
    CHECK( B.bytes[2] == 0x41 && B.bytes[3] == 0x54 );
    /* R13,R14,R15 (41 55 / 41 56 / 41 57), then PUSH RSI (0x56), PUSH RBP
       (0x55) -- RBP is the hoisted savedpc base, pushed last. */
    CHECK( B.bytes[4] == 0x41 && B.bytes[5] == 0x55 );
    CHECK( B.bytes[6] == 0x41 && B.bytes[7] == 0x56 );
    CHECK( B.bytes[8] == 0x41 && B.bytes[9] == 0x57 );
    CHECK( B.bytes[10] == 0x56 );
    CHECK( B.bytes[11] == 0x55 );
    /* SUB RSP,0x28 -- 8 pushes (64) + return address (8) = 72; +40 = 112,
       16-aligned. 0x20 here would break every helper call's ABI alignment. */
    CHECK( B.bytes[12] == 0x48 && B.bytes[13] == 0x81 && B.bytes[14] == 0xEC );
    CHECK( B.bytes[15] == 0x28 && B.bytes[16] == 0x00 &&
           B.bytes[17] == 0x00 && B.bytes[18] == 0x00 );

    /* ---- epilogue ---- */
    CHECK( LcCg_EmitEpilogue( &B ) == 1 );
    CHECK( B.used > after_prologue );
    /* ADD RSP,0x28 must mirror the prologue's SUB RSP,0x28 exactly. */
    CHECK( B.bytes[after_prologue + 0] == 0x48 &&
           B.bytes[after_prologue + 1] == 0x81 &&
           B.bytes[after_prologue + 2] == 0xC4 &&
           B.bytes[after_prologue + 3] == 0x28 );
    CHECK( B.bytes[B.used - 1] == 0xC3 );  /* RET is the last byte */
    /* byte before RET is POP RDI (reg 7, no REX): 0x5F */
    CHECK( B.bytes[B.used - 2] == 0x5F );
    /* POP RBP (0x5D) is the FIRST pop (right after the 7-byte ADD RSP,imm32),
       mirroring the last push. */
    CHECK( B.bytes[after_prologue + 7] == 0x5D );

    /* ---- LEA r64,[base+disp] picks disp8 when it fits (the savedpc-site
            size win) and disp32 otherwise; RBP-based disp==0 must still
            emit a mod=01 form, never RIP-relative. ---- */
    LcCodeBuf L8;
    CHECK( LcCodeBuf_Init( &L8, 16 ) == 1 );
    CHECK( X64Emit_LeaRegMem( &L8, X64_R11, X64_RBP, 0x40 ) == 1 );
    CHECK( L8.used == 4 );
    CHECK( L8.bytes[0] == 0x4C && L8.bytes[1] == 0x8D &&
           L8.bytes[2] == 0x5D && L8.bytes[3] == 0x40 );
    L8.used = 0;
    CHECK( X64Emit_LeaRegMem( &L8, X64_R11, X64_RBP, 0 ) == 1 );
    CHECK( L8.used == 4 && L8.bytes[2] == 0x5D && L8.bytes[3] == 0x00 );
    L8.used = 0;
    CHECK( X64Emit_LeaRegMem( &L8, X64_R11, X64_RBP, -4096 ) == 1 );
    CHECK( L8.used == 7 );
    CHECK( L8.bytes[0] == 0x4C && L8.bytes[1] == 0x8D && L8.bytes[2] == 0x9D );
    LcCodeBuf_Free( &L8 );

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
