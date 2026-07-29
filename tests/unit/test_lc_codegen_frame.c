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

#include <string.h>   /* memcmp, for the exact-byte-stream assertions */

int main( void ) {
    LcCodeBuf B;
    TEST_BEGIN( "lc_codegen_frame" );

    CHECK( LcCodeBuf_Init( &B, 64 ) == 1 );

    /* ---- prologue ---- */
    /* The prologue and epilogue now take an explicit frame descriptor instead
       of reading file-scope globals, so the two must be handed the SAME object:
       an asymmetric frame returns with a corrupt RSP. This case uses the plain
       frame (no xmm spill, zero bias), which is what the byte assertions below
       were written against. */
    LcCgFrame frame;
    frame.savedpc_bias = 0;
    frame.save_xmm     = 0;
    CHECK( LcCg_EmitPrologue( &B, &frame ) == 1 );
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
       16-aligned. 0x20 here would break every helper call's ABI alignment.

       Encoded `48 83 EC 28` (imm8), not `48 81 EC 28 00 00 00` (imm32): `83 /n ib`
       sign-extends its imm8 under REX.W, so the two forms leave RSP identical for
       any value in [-128,127], and the short one is 3 bytes cheaper on every
       prologue and every epilogue. The RESERVE VALUE is what matters here, so it
       is asserted separately from the encoding below. */
    CHECK( B.bytes[12] == 0x48 && B.bytes[13] == 0x83 && B.bytes[14] == 0xEC );
    CHECK( B.bytes[15] == 0x28 );

    /* ---- epilogue ---- */
    CHECK( LcCg_EmitEpilogue( &B, &frame ) == 1 );
    CHECK( B.used > after_prologue );
    /* ADD RSP,0x28 -- the imm8 form, mirroring the prologue's SUB. If these two
       ever disagree on the reserve the return address is wrong and the process
       dies, so both are asserted against the same literal 0x28. */
    CHECK( B.bytes[after_prologue + 0] == 0x48 &&
           B.bytes[after_prologue + 1] == 0x83 &&
           B.bytes[after_prologue + 2] == 0xC4 &&
           B.bytes[after_prologue + 3] == 0x28 );
    CHECK( B.bytes[B.used - 1] == 0xC3 );  /* RET is the last byte */
    /* byte before RET is POP RDI (reg 7, no REX): 0x5F */
    CHECK( B.bytes[B.used - 2] == 0x5F );
    /* POP RBP (0x5D) is the FIRST pop, immediately after the ADD RSP. Derived
       from the ADD's length rather than hardcoded: the imm8 encoding is 4 bytes
       where imm32 was 7, and an offset literal here would silently drift again the
       next time an encoding shortens. */
    CHECK( B.bytes[after_prologue + 4] == 0x5D );
    /* And the pops must mirror the pushes in reverse: RBP, RSI, R15, R14, R13,
       R12, RBX, RDI. Asserting the whole sequence is what actually guarantees the
       frame unwinds to the same RSP it was entered with. */
    CHECK( B.bytes[after_prologue + 5] == 0x5E );                          /* POP RSI  */
    CHECK( B.bytes[after_prologue + 6] == 0x41 && B.bytes[after_prologue + 7]  == 0x5F ); /* R15 */
    CHECK( B.bytes[after_prologue + 8] == 0x41 && B.bytes[after_prologue + 9]  == 0x5E ); /* R14 */
    CHECK( B.bytes[after_prologue + 10] == 0x41 && B.bytes[after_prologue + 11] == 0x5D ); /* R13 */
    CHECK( B.bytes[after_prologue + 12] == 0x41 && B.bytes[after_prologue + 13] == 0x5C ); /* R12 */
    CHECK( B.bytes[after_prologue + 14] == 0x5B );                         /* POP RBX  */

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

    /* ---- helper-call shim: exact byte stream, all three argument tiers ----
       The shim loads its three int arguments with the imm32 encoder, so these
       assert the WHOLE stream, not just the reloc. A missing REX.B on R8/R9
       would silently load EAX/ECX instead and pass a wrong argument -- a
       miscompile a size measurement would happily report as a bigger win. */
    LcCodeBuf E;
    CHECK( LcCodeBuf_Init( &E, 32 ) == 1 );
    CHECK( LcCg_EmitHelperCall3( &E, "Rt_Len", 1, 2, 3, 0 ) == 1 );
    CHECK( E.nrelocs == 1 && E.relocs[0].kind == LC_RELOC_REL32 );
    {   /* 48 89 D9 | BA 01.. | 41 B8 02.. | 41 B9 03.. | E8 00 00 00 00 */
        static const unsigned char want[] = {
            0x48, 0x89, 0xD9,
            0xBA, 0x01, 0x00, 0x00, 0x00,
            0x41, 0xB8, 0x02, 0x00, 0x00, 0x00,
            0x41, 0xB9, 0x03, 0x00, 0x00, 0x00,
            0xE8, 0x00, 0x00, 0x00, 0x00
        };
        CHECK( E.used == sizeof( want ) );
        CHECK( memcmp( E.bytes, want, sizeof( want ) ) == 0 );
        CHECK( E.relocs[0].offset == 21 );
    }

    /* all-zero arguments: xor tier, and the R8/R9 forms need REX.R *and* REX.B */
    LcCodeBuf E2;
    CHECK( LcCodeBuf_Init( &E2, 32 ) == 1 );
    CHECK( LcCg_EmitHelperCall3( &E2, "Rt_Close", 0, 0, 0, 0 ) == 1 );
    {   /* 48 89 D9 | 31 D2 | 45 31 C0 | 45 31 C9 | E8 00 00 00 00 */
        static const unsigned char want[] = {
            0x48, 0x89, 0xD9,
            0x31, 0xD2,
            0x45, 0x31, 0xC0,
            0x45, 0x31, 0xC9,
            0xE8, 0x00, 0x00, 0x00, 0x00
        };
        CHECK( E2.used == sizeof( want ) );
        CHECK( memcmp( E2.bytes, want, sizeof( want ) ) == 0 );
        CHECK( E2.nrelocs == 1 && E2.relocs[0].offset == 12 );
    }

    /* negative arguments (real: NArgs/NResults == -1 for multret) must
       SIGN-extend, so the 64-bit register matches the old imm64 form exactly */
    LcCodeBuf E3;
    CHECK( LcCodeBuf_Init( &E3, 32 ) == 1 );
    CHECK( LcCg_EmitHelperCall3( &E3, "Rt_Call", 0, -1, -1, 0 ) == 1 );
    {   /* 48 89 D9 | 31 D2 | 49 C7 C0 FF.. | 49 C7 C1 FF.. | E8 00 00 00 00 */
        static const unsigned char want[] = {
            0x48, 0x89, 0xD9,
            0x31, 0xD2,
            0x49, 0xC7, 0xC0, 0xFF, 0xFF, 0xFF, 0xFF,
            0x49, 0xC7, 0xC1, 0xFF, 0xFF, 0xFF, 0xFF,
            0xE8, 0x00, 0x00, 0x00, 0x00
        };
        CHECK( E3.used == sizeof( want ) );
        CHECK( memcmp( E3.bytes, want, sizeof( want ) ) == 0 );
        CHECK( E3.nrelocs == 1 && E3.relocs[0].offset == 20 );
    }

    LcCodeBuf_Free( &B );
    LcCodeBuf_Free( &C );
    LcCodeBuf_Free( &D );
    LcCodeBuf_Free( &E );
    LcCodeBuf_Free( &E2 );
    LcCodeBuf_Free( &E3 );
    TEST_END();
}
