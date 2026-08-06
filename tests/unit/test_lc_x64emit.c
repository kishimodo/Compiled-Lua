#include "test_harness.h"
#include "codegen/x64_emit.h"

#include <string.h>   /* memcmp, for the exact-byte-stream assertions */

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

    /* ---- X64Emit_MovImm32ToReg: all three tiers on all three argument
       registers the helper-call shim uses.

       These are exact-byte assertions because the failure mode is silent. The
       zero tier names Dst in BOTH the reg and rm fields, so a high register
       needs REX.R *and* REX.B: 45 31 C0 is xor r8d,r8d, while 41 31 C0 is
       xor r8d,eax -- which is not zero, and which no size measurement would
       flag. The negative tier must SIGN-extend (REX.W C7 /0) so the resulting
       64-bit register is bit-identical to the imm64 form it replaces; the
       shorter zero-extending B8+rd form would leave 0x00000000FFFFFFFF where
       the old code left 0xFFFFFFFFFFFFFFFF. */
    {
        struct { X64_GPR_T reg; int32_t imm; size_t n; unsigned char want[8]; }
        cases[] = {
            /* zero tier */
            { X64_RDX,  0, 2, { 0x31, 0xD2 } },
            { X64_R8,   0, 3, { 0x45, 0x31, 0xC0 } },
            { X64_R9,   0, 3, { 0x45, 0x31, 0xC9 } },
            /* positive tier: 0x11223344 makes a byte-order slip unmistakable */
            { X64_RDX,  0x11223344, 5, { 0xBA, 0x44, 0x33, 0x22, 0x11 } },
            { X64_R8,   0x11223344, 6, { 0x41, 0xB8, 0x44, 0x33, 0x22, 0x11 } },
            { X64_R9,   0x11223344, 6, { 0x41, 0xB9, 0x44, 0x33, 0x22, 0x11 } },
            /* negative tier (RDX-negative is unreachable from codegen today --
               argument `a` is always a register index or 0 -- but must be right) */
            { X64_RDX, -1, 7, { 0x48, 0xC7, 0xC2, 0xFF, 0xFF, 0xFF, 0xFF } },
            { X64_R8,  -1, 7, { 0x49, 0xC7, 0xC0, 0xFF, 0xFF, 0xFF, 0xFF } },
            { X64_R9,  -1, 7, { 0x49, 0xC7, 0xC1, 0xFF, 0xFF, 0xFF, 0xFF } },
        };
        size_t i;
        for ( i = 0; i < sizeof( cases ) / sizeof( cases[0] ); i++ ) {
            LcCodeBuf M;
            CHECK( LcCodeBuf_Init( &M, 16 ) == 1 );
            CHECK( X64Emit_MovImm32ToReg( &M, cases[i].reg, cases[i].imm ) == 1 );
            CHECK( M.used == cases[i].n );
            CHECK( memcmp( M.bytes, cases[i].want, cases[i].n ) == 0 );
            CHECK( M.nrelocs == 0 );   /* an immediate needs no relocation */
            LcCodeBuf_Free( &M );
        }
    }

    /* INT32_MIN takes the negative (sign-extending) tier, not a truncated one. */
    LcCodeBuf_Free( &C );
    CHECK( LcCodeBuf_Init( &C, 16 ) == 1 );
    CHECK( X64Emit_MovImm32ToReg( &C, X64_R9, ( int32_t )0x80000000 ) == 1 );
    CHECK( C.used == 7 );
    CHECK( C.bytes[0] == 0x49 && C.bytes[1] == 0xC7 && C.bytes[2] == 0xC1 );
    CHECK( C.bytes[3] == 0x00 && C.bytes[4] == 0x00 &&
           C.bytes[5] == 0x00 && C.bytes[6] == 0x80 );

    /* ---- X64Emit_JbeRel8: opcode 0x76 + signed rel8 byte, 2 bytes total.
       Rel range covers zero, INT8_MAX, INT8_MIN, and -1 so the sign-extension
       of the displacement is exercised end-to-end. */
    {
        struct { int8_t rel; unsigned char want[2]; } cases[] = {
            {    0, { 0x76, 0x00 } },
            {  127, { 0x76, 0x7F } },
            { -128, { 0x76, 0x80 } },
            {   -1, { 0x76, 0xFF } },
        };
        size_t i;
        for ( i = 0; i < sizeof( cases ) / sizeof( cases[0] ); i++ ) {
            LcCodeBuf M;
            CHECK( LcCodeBuf_Init( &M, 16 ) == 1 );
            CHECK( X64Emit_JbeRel8( &M, cases[i].rel ) == 1 );
            CHECK( M.used == 2 );
            CHECK( memcmp( M.bytes, cases[i].want, 2 ) == 0 );
            LcCodeBuf_Free( &M );
        }
    }

    /* ---- X64Emit_JeRel8: opcode 0x74, same shape as JbeRel8. */
    {
        struct { int8_t rel; unsigned char want[2]; } cases[] = {
            {    0, { 0x74, 0x00 } },
            {  127, { 0x74, 0x7F } },
            { -128, { 0x74, 0x80 } },
            {   -1, { 0x74, 0xFF } },
        };
        size_t i;
        for ( i = 0; i < sizeof( cases ) / sizeof( cases[0] ); i++ ) {
            LcCodeBuf M;
            CHECK( LcCodeBuf_Init( &M, 16 ) == 1 );
            CHECK( X64Emit_JeRel8( &M, cases[i].rel ) == 1 );
            CHECK( M.used == 2 );
            CHECK( memcmp( M.bytes, cases[i].want, 2 ) == 0 );
            LcCodeBuf_Free( &M );
        }
    }

    /* ---- X64Emit_TestMem8Imm8: F6 /0 ib.  Four cases cover the ModR/M
       encoding matrix that the shared EmitMemOp selects on:
         - RAX + disp0     -> mod=00, no SIB, no disp, no REX
         - RCX + disp8     -> mod=01, one-byte disp
         - RDI + disp32    -> mod=10, four-byte disp (0x11223344 makes any
                              byte-order slip unmistakable)
         - R8  + disp8     -> REX.B prefix + mod=01, disp8 (verifies the
                              high-register path)
       The imm8 sits in the last byte of every case. */
    {
        struct {
            X64_GPR_T base; int32_t disp; int8_t imm;
            size_t n; unsigned char want[8];
        } cases[] = {
            /* F6 00 42                       -- test byte [rax], 0x42 */
            { X64_RAX, 0x00000000, 0x42, 3,
              { 0xF6, 0x00, 0x42 } },
            /* F6 41 08 55                    -- test byte [rcx + 8], 0x55 */
            { X64_RCX, 0x00000008, 0x55, 4,
              { 0xF6, 0x41, 0x08, 0x55 } },
            /* F6 87 44 33 22 11 7F           -- test byte [rdi + 0x11223344], 0x7F.
               ModR/M = 10 000 111 = 0x87 (mod=disp32, reg=/0 opcode extension = 0,
               rm=RDI=7). The reg field must be 0 for F6 /0 (TEST); a 0xBF here
               would encode /7 and mean something different. */
            { X64_RDI, 0x11223344, 0x7F, 7,
              { 0xF6, 0x87, 0x44, 0x33, 0x22, 0x11, 0x7F } },
            /* 41 F6 40 10 01                 -- test byte [r8 + 0x10], 0x01 */
            { X64_R8,  0x00000010, 0x01, 5,
              { 0x41, 0xF6, 0x40, 0x10, 0x01 } },
        };
        size_t i;
        for ( i = 0; i < sizeof( cases ) / sizeof( cases[0] ); i++ ) {
            LcCodeBuf M;
            CHECK( LcCodeBuf_Init( &M, 16 ) == 1 );
            CHECK( X64Emit_TestMem8Imm8( &M, cases[i].base, cases[i].disp,
                                         cases[i].imm ) == 1 );
            CHECK( M.used == cases[i].n );
            CHECK( memcmp( M.bytes, cases[i].want, cases[i].n ) == 0 );
            CHECK( M.nrelocs == 0 );
            LcCodeBuf_Free( &M );
        }
    }

    LcCodeBuf_Free( &B );
    LcCodeBuf_Free( &C );
    TEST_END();
}
