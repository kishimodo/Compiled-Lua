#include "jit/emit_x64.h"

#include <string.h>

/* REX prefix bits (Intel SDM Vol. 2A 2.2.1):
   bit 6 = constant 0b0100_xxxx (high nibble 4)
   W (bit 3): operand size = 64
   R (bit 2): extends ModR/M.reg to 4 bits
   X (bit 1): extends SIB.index
   B (bit 0): extends ModR/M.rm / opcode reg field */
#define REX_BASE 0x40
#define REX_W    0x08
#define REX_R    0x04
#define REX_X    0x02
#define REX_B    0x01

static int IsHi( X64_GPR_T R ) { return ( int )R >= 8; }
static unsigned Lo3( X64_GPR_T R ) { return ( unsigned )R & 0x7u; }

static int AppendByte( PEXEC_MEM_SLOT_T Slot, unsigned char B ) {
    return ExecMem_Append( Slot, &B, 1 );
}

static int AppendBytes( PEXEC_MEM_SLOT_T Slot, const void *P, size_t N ) {
    return ExecMem_Append( Slot, P, N );
}

/* ModR/M byte: mod(2) | reg(3) | rm(3) */
static unsigned char ModRm( unsigned Mod, unsigned Reg, unsigned Rm ) {
    return ( unsigned char )( ( Mod << 6 ) | ( ( Reg & 7 ) << 3 ) | ( Rm & 7 ) );
}

int EmitX64_MovImm64ToReg( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Dst, uint64_t Imm ) {
    unsigned char Rex = REX_BASE | REX_W | ( IsHi( Dst ) ? REX_B : 0 );
    if ( !AppendByte( Slot, Rex ) )                       return 0;
    if ( !AppendByte( Slot, 0xB8 | ( unsigned char )Lo3( Dst ) ) ) return 0;
    if ( !AppendBytes( Slot, &Imm, 8 ) )                  return 0;
    return 1;
}

int EmitX64_MovRegToReg( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Dst, X64_GPR_T Src ) {
    unsigned char Rex = REX_BASE | REX_W
                      | ( IsHi( Src ) ? REX_R : 0 )
                      | ( IsHi( Dst ) ? REX_B : 0 );
    /* 0x89 /r  MOV r/m64, r64.  ModR/M: mod=11, reg=src, rm=dst */
    if ( !AppendByte( Slot, Rex ) )                                    return 0;
    if ( !AppendByte( Slot, 0x89 ) )                                   return 0;
    if ( !AppendByte( Slot, ModRm( 3, Lo3( Src ), Lo3( Dst ) ) ) )     return 0;
    return 1;
}

int EmitX64_Ret( PEXEC_MEM_SLOT_T Slot ) {
    return AppendByte( Slot, 0xC3 );
}

/*!
 * Encode disp8 vs disp32 ModR/M for [Base + Disp].
 * Special cases handled:
 *   - Base == RBP or R13: mod=00 with rm=101 means RIP-relative; we must use
 *     mod=01 with disp8=0 instead. Easy: always use disp8 when Disp==0 for
 *     those bases.
 *   - Base == RSP or R12: rm=100 means a SIB byte follows; we synthesise a
 *     SIB (scale=00, index=100=none, base=Lo3(Base)).
 */
static int EmitMemOp( PEXEC_MEM_SLOT_T Slot,
                      unsigned char Opcode,
                      unsigned RegField,           /* the "reg" of ModR/M */
                      int       RegFieldHi,       /* extends to REX.R */
                      X64_GPR_T Base, int32_t Disp,
                      int       UseW ) {
    unsigned char Rex = REX_BASE
                      | ( UseW ? REX_W : 0 )
                      | ( RegFieldHi ? REX_R : 0 )
                      | ( IsHi( Base ) ? REX_B : 0 );
    int NeedsSib = ( Lo3( Base ) == 4 );             /* RSP/R12 */
    int RbpLike  = ( Lo3( Base ) == 5 );             /* RBP/R13 */
    int Disp8Ok  = ( Disp >= -128 && Disp <= 127 );
    unsigned Mod = { 0 };
    if ( Disp == 0 && !RbpLike ) {
        Mod = 0;
    } else if ( Disp8Ok ) {
        Mod = 1;
    } else {
        Mod = 2;
    }

    /* Emit REX only if any of its non-base bits are set. The REX_BASE alone
       (0x40) is a valid no-op prefix, but we always emit it when UseW or
       any high-reg extension is needed. For 32-bit ops with no extensions
       we omit it. */
    if ( UseW || RegFieldHi || IsHi( Base ) ) {
        if ( !AppendByte( Slot, Rex ) )                                        return 0;
    }
    if ( !AppendByte( Slot, Opcode ) )                                         return 0;
    if ( !AppendByte( Slot, ModRm( Mod, RegField, Lo3( Base ) ) ) )            return 0;
    if ( NeedsSib ) {
        /* SIB: scale=00, index=100 (none), base=Lo3(Base) */
        if ( !AppendByte( Slot, ( unsigned char )( ( 4u << 3 ) | Lo3( Base ) ) ) ) return 0;
    }
    if ( Mod == 1 ) {
        int8_t D8 = ( int8_t )Disp;
        if ( !AppendBytes( Slot, &D8, 1 ) )                                    return 0;
    } else if ( Mod == 2 ) {
        if ( !AppendBytes( Slot, &Disp, 4 ) )                                  return 0;
    }
    return 1;
}

int EmitX64_MovMemToReg( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Dst,
                         X64_GPR_T Base, int32_t Disp ) {
    /* 0x8B /r  MOV r64, r/m64 */
    return EmitMemOp( Slot, 0x8B, Lo3( Dst ), IsHi( Dst ), Base, Disp, 1 );
}

int EmitX64_MovRegToMem( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp,
                         X64_GPR_T Src ) {
    /* 0x89 /r  MOV r/m64, r64 */
    return EmitMemOp( Slot, 0x89, Lo3( Src ), IsHi( Src ), Base, Disp, 1 );
}

int EmitX64_MovImm32ToMem( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp,
                           int32_t Imm ) {
    /* C7 /0 id   MOV r/m32, imm32   (32-bit operand, no REX.W) */
    if ( !EmitMemOp( Slot, 0xC7, 0, 0, Base, Disp, 0 ) ) return 0;
    return AppendBytes( Slot, &Imm, 4 );
}

int EmitX64_CmpMem32Imm32( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp,
                           int32_t Imm ) {
    /* 81 /7 id   CMP r/m32, imm32 */
    if ( !EmitMemOp( Slot, 0x81, 7, 0, Base, Disp, 0 ) ) return 0;
    return AppendBytes( Slot, &Imm, 4 );
}

int EmitX64_CmpMem8Imm8( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp,
                         int8_t Imm ) {
    /* 80 /7 ib   CMP r/m8, imm8 */
    if ( !EmitMemOp( Slot, 0x80, 7, 0, Base, Disp, 0 ) ) return 0;
    return AppendBytes( Slot, &Imm, 1 );
}

int EmitX64_AddMemToReg( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Dst,
                         X64_GPR_T Base, int32_t Disp ) {
    /* 03 /r   ADD r64, r/m64 */
    return EmitMemOp( Slot, 0x03, Lo3( Dst ), IsHi( Dst ), Base, Disp, 1 );
}

int EmitX64_JneRel8( PEXEC_MEM_SLOT_T Slot, int8_t Rel ) {
    if ( !AppendByte( Slot, 0x75 ) )       return 0;
    return AppendBytes( Slot, &Rel, 1 );
}

int EmitX64_JmpRel8( PEXEC_MEM_SLOT_T Slot, int8_t Rel ) {
    if ( !AppendByte( Slot, 0xEB ) )       return 0;
    return AppendBytes( Slot, &Rel, 1 );
}

size_t EmitX64_JmpRel8_Placeholder( PEXEC_MEM_SLOT_T Slot ) {
    if ( Slot == NULL || Slot->Committed ) { return ( size_t )-1; }
    unsigned char Bytes[ 2 ] = { 0xEB, 0x00 };
    if ( !ExecMem_Append( Slot, Bytes, 2 ) ) { return ( size_t )-1; }
    return Slot->Used - 1;
}

int EmitX64_PatchRel8( PEXEC_MEM_SLOT_T Slot, size_t PatchOffset, size_t TargetOffset ) {
    if ( Slot == NULL || Slot->Code == NULL || Slot->Committed ) { return 0; }
    if ( PatchOffset >= Slot->Used ) { return 0; }
    long long Delta = ( long long )TargetOffset - ( long long )( PatchOffset + 1 );
    if ( Delta < -128 || Delta > 127 ) { return 0; }
    Slot->Code[ PatchOffset ] = ( unsigned char )( int8_t )Delta;
    return 1;
}

size_t EmitX64_JmpRel32_Placeholder( PEXEC_MEM_SLOT_T Slot ) {
    if ( Slot == NULL || Slot->Committed ) { return ( size_t )-1; }
    unsigned char Bytes[ 5 ] = { 0xE9, 0x00, 0x00, 0x00, 0x00 };
    if ( !ExecMem_Append( Slot, Bytes, 5 ) ) { return ( size_t )-1; }
    return Slot->Used - 4;
}

size_t EmitX64_JccRel32_Placeholder( PEXEC_MEM_SLOT_T Slot, unsigned Cc ) {
    if ( Slot == NULL || Slot->Committed ) { return ( size_t )-1; }
    unsigned char Bytes[ 6 ] = { 0x0F, ( unsigned char )( 0x80 | ( Cc & 0xF ) ),
                                  0x00, 0x00, 0x00, 0x00 };
    if ( !ExecMem_Append( Slot, Bytes, 6 ) ) { return ( size_t )-1; }
    return Slot->Used - 4;
}

int EmitX64_PatchRel32( PEXEC_MEM_SLOT_T Slot, size_t PatchOffset, size_t TargetOffset ) {
    if ( Slot == NULL || Slot->Code == NULL || Slot->Committed ) { return 0; }
    if ( PatchOffset + 4 > Slot->Used ) { return 0; }
    long long Delta = ( long long )TargetOffset - ( long long )( PatchOffset + 4 );
    if ( Delta < -2147483648LL || Delta > 2147483647LL ) { return 0; }
    int32_t Disp32 = ( int32_t )Delta;
    /* little-endian store */
    Slot->Code[ PatchOffset + 0 ] = ( unsigned char )( Disp32         & 0xFF );
    Slot->Code[ PatchOffset + 1 ] = ( unsigned char )( ( Disp32 >> 8  ) & 0xFF );
    Slot->Code[ PatchOffset + 2 ] = ( unsigned char )( ( Disp32 >> 16 ) & 0xFF );
    Slot->Code[ PatchOffset + 3 ] = ( unsigned char )( ( Disp32 >> 24 ) & 0xFF );
    return 1;
}

int EmitX64_PushReg( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Reg )
{
    /* PUSH r64: 50+r (opt REX.B for high regs).  PUSH defaults to 64-bit
       operand size on x64 — no REX.W needed. */
    if ( IsHi( Reg ) ) {
        if ( !AppendByte( Slot, REX_BASE | REX_B ) ) return 0;
    }
    return AppendByte( Slot, ( unsigned char )( 0x50 + Lo3( Reg ) ) );
}

int EmitX64_PopReg( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Reg )
{
    if ( IsHi( Reg ) ) {
        if ( !AppendByte( Slot, REX_BASE | REX_B ) ) return 0;
    }
    return AppendByte( Slot, ( unsigned char )( 0x58 + Lo3( Reg ) ) );
}

int EmitX64_SubRspImm( PEXEC_MEM_SLOT_T Slot, int32_t Imm )
{
    /* 48 81 EC id   SUB rsp, imm32   (always use imm32 form for simplicity) */
    if ( !AppendByte( Slot, REX_BASE | REX_W ) )                  return 0;
    if ( !AppendByte( Slot, 0x81 ) )                              return 0;
    if ( !AppendByte( Slot, ModRm( 3, 5, 4 ) ) )                  return 0; /* /5, rm=rsp */
    return AppendBytes( Slot, &Imm, 4 );
}

int EmitX64_AddRspImm( PEXEC_MEM_SLOT_T Slot, int32_t Imm )
{
    /* 48 81 C4 id   ADD rsp, imm32 */
    if ( !AppendByte( Slot, REX_BASE | REX_W ) )                  return 0;
    if ( !AppendByte( Slot, 0x81 ) )                              return 0;
    if ( !AppendByte( Slot, ModRm( 3, 0, 4 ) ) )                  return 0; /* /0, rm=rsp */
    return AppendBytes( Slot, &Imm, 4 );
}

int EmitX64_CallAbs( PEXEC_MEM_SLOT_T Slot, void *Target )
{
    /* 48 B8 imm64 ; FF D0 — mov rax, imm64 ; call rax */
    if ( !EmitX64_MovImm64ToReg( Slot, X64_RAX, ( uint64_t )( uintptr_t )Target ) ) return 0;
    if ( !AppendByte( Slot, 0xFF ) )                              return 0;
    if ( !AppendByte( Slot, ModRm( 3, 2, 0 ) ) )                  return 0; /* /2, rm=rax */
    return 1;
}

/*!
 * @brief
 *  Emit a "F2 0F <opcode> /r" SSE2 mem-form instruction with XMM0 as the
 *  reg-field operand and [Base + Disp] as the r/m operand. ModR/M uses
 *  the same disp0/disp8/disp32 selection logic as the integer EmitMemOp,
 *  but doesn't need a REX prefix for the XMM0..XMM7 + RAX..RDI case.
 */
static int EmitSse2MemForm( PEXEC_MEM_SLOT_T Slot, unsigned char Sse2Opcode,
                             X64_GPR_T Base, int32_t Disp ) {
    /* prefix: F2 0F <opcode> */
    unsigned char Prefix[ 3 ] = { 0xF2, 0x0F, Sse2Opcode };
    if ( !ExecMem_Append( Slot, Prefix, 3 ) ) return 0;

    /* ModR/M with reg=000 (XMM0), rm=Lo3(Base). */
    int      RbpLike = ( Lo3( Base ) == 5 );
    int      Mod     = ( Disp == 0 && !RbpLike ) ? 0 :
                       ( ( Disp >= -128 && Disp <= 127 ) ? 1 : 2 );
    unsigned ModRm8  = ( unsigned )( ( Mod << 6 ) | ( 0 << 3 ) | Lo3( Base ) );
    if ( !AppendByte( Slot, ( unsigned char )ModRm8 ) ) return 0;

    /* SIB for RSP-like bases (Lo3 == 4) */
    if ( Lo3( Base ) == 4 ) {
        unsigned char Sib = ( unsigned char )( ( 4u << 3 ) | Lo3( Base ) );
        if ( !AppendByte( Slot, Sib ) ) return 0;
    }
    if ( Mod == 1 ) {
        int8_t D8 = ( int8_t )Disp;
        if ( !AppendBytes( Slot, &D8, 1 ) ) return 0;
    } else if ( Mod == 2 ) {
        if ( !AppendBytes( Slot, &Disp, 4 ) ) return 0;
    }
    return 1;
}

int EmitX64_MovsdMemToXmm0( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp ) {
    return EmitSse2MemForm( Slot, 0x10, Base, Disp );
}
int EmitX64_MovsdXmm0ToMem( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp ) {
    return EmitSse2MemForm( Slot, 0x11, Base, Disp );
}
int EmitX64_AddsdMemToXmm0( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp ) {
    return EmitSse2MemForm( Slot, 0x58, Base, Disp );
}
int EmitX64_SubsdMemToXmm0( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp ) {
    return EmitSse2MemForm( Slot, 0x5C, Base, Disp );
}
int EmitX64_MulsdMemToXmm0( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp ) {
    return EmitSse2MemForm( Slot, 0x59, Base, Disp );
}
int EmitX64_DivsdMemToXmm0( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp ) {
    return EmitSse2MemForm( Slot, 0x5E, Base, Disp );
}

/* Internal: emit MOVSD or MOVSS into XmmN (0..7).
   Format: PrefixByte [REX] 0F 10 ModR/M [disp8|disp32].
   ModR/M.reg = XmmN, ModR/M.rm = Base GPR (low 3 bits).
   REX is needed only if Base is R8..R15 (we don't use those here). */
static int EmitMovScalarMemToXmmN( PEXEC_MEM_SLOT_T Slot, int PrefixByte,
                                   int XmmN, X64_GPR_T Base, int32_t Disp ) {
    if ( XmmN < 0 || XmmN > 7 ) return 0;
    if ( ( int )Base > 7 ) return 0;
    unsigned char Buf[ 8 ];
    int N = 0;
    Buf[ N++ ] = ( unsigned char )PrefixByte;
    Buf[ N++ ] = 0x0F;
    Buf[ N++ ] = 0x10;
    int Mod = ( Disp == 0 && ( int )Base != X64_RBP ) ? 0
            : ( Disp >= -128 && Disp <= 127 ) ? 1 : 2;
    Buf[ N++ ] = ( unsigned char )( ( Mod << 6 ) | ( ( XmmN & 7 ) << 3 ) | ( ( int )Base & 7 ) );
    if ( ( int )Base == X64_RSP ) {
        Buf[ N++ ] = 0x24;
    }
    if ( Mod == 1 ) {
        Buf[ N++ ] = ( unsigned char )( int8_t )Disp;
    } else if ( Mod == 2 ) {
        memcpy( &Buf[ N ], &Disp, 4 );
        N += 4;
    }
    return ExecMem_Append( Slot, Buf, ( size_t )N );
}

int EmitX64_MovsdMemToXmmN( PEXEC_MEM_SLOT_T Slot, int XmmN,
                            X64_GPR_T Base, int32_t Disp ) {
    return EmitMovScalarMemToXmmN( Slot, 0xF2, XmmN, Base, Disp );
}

int EmitX64_MovssMemToXmmN( PEXEC_MEM_SLOT_T Slot, int XmmN,
                            X64_GPR_T Base, int32_t Disp ) {
    return EmitMovScalarMemToXmmN( Slot, 0xF3, XmmN, Base, Disp );
}

int EmitX64_MovqXmm0ToReg64( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Dst ) {
    /* 66 REX.W 0F 7E /r -- MOVQ r/m64, xmm.  ModR/M reg = xmm0 (0), rm = Dst. */
    unsigned char Buf[ 5 ];
    int N = 0;
    Buf[ N++ ] = 0x66;
    Buf[ N++ ] = ( unsigned char )( 0x48 | ( ( ( int )Dst & 8 ) ? 0x01 : 0 ) );
    Buf[ N++ ] = 0x0F;
    Buf[ N++ ] = 0x7E;
    Buf[ N++ ] = ( unsigned char )( 0xC0 | ( ( 0 & 7 ) << 3 ) | ( ( int )Dst & 7 ) );
    return ExecMem_Append( Slot, Buf, ( size_t )N );
}

int EmitX64_MovqReg64ToXmm0( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Src ) {
    /* 66 REX.W 0F 6E /r -- MOVQ xmm, r/m64. */
    unsigned char Buf[ 5 ];
    int N = 0;
    Buf[ N++ ] = 0x66;
    Buf[ N++ ] = ( unsigned char )( 0x48 | ( ( ( int )Src & 8 ) ? 0x01 : 0 ) );
    Buf[ N++ ] = 0x0F;
    Buf[ N++ ] = 0x6E;
    Buf[ N++ ] = ( unsigned char )( 0xC0 | ( ( 0 & 7 ) << 3 ) | ( ( int )Src & 7 ) );
    return ExecMem_Append( Slot, Buf, ( size_t )N );
}
