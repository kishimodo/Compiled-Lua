#include "codegen/x64_emit.h"

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

static int AppendByte( LcCodeBuf *Buf, unsigned char B ) {
    return LcCodeBuf_Append( Buf, &B, 1 );
}

static int AppendBytes( LcCodeBuf *Buf, const void *P, size_t N ) {
    return LcCodeBuf_Append( Buf, ( const uint8_t * )P, N );
}

/* ModR/M byte: mod(2) | reg(3) | rm(3) */
static unsigned char ModRm( unsigned Mod, unsigned Reg, unsigned Rm ) {
    return ( unsigned char )( ( Mod << 6 ) | ( ( Reg & 7 ) << 3 ) | ( Rm & 7 ) );
}

int X64Emit_MovImm64ToReg( LcCodeBuf *Buf, X64_GPR_T Dst, uint64_t Imm ) {
    unsigned char Rex = REX_BASE | REX_W | ( IsHi( Dst ) ? REX_B : 0 );
    if ( !AppendByte( Buf, Rex ) )                       return 0;
    if ( !AppendByte( Buf, 0xB8 | ( unsigned char )Lo3( Dst ) ) ) return 0;
    if ( !AppendBytes( Buf, &Imm, 8 ) )                  return 0;
    return 1;
}

int X64Emit_MovRegToReg( LcCodeBuf *Buf, X64_GPR_T Dst, X64_GPR_T Src ) {
    unsigned char Rex = REX_BASE | REX_W
                      | ( IsHi( Src ) ? REX_R : 0 )
                      | ( IsHi( Dst ) ? REX_B : 0 );
    /* 0x89 /r  MOV r/m64, r64.  ModR/M: mod=11, reg=src, rm=dst */
    if ( !AppendByte( Buf, Rex ) )                                    return 0;
    if ( !AppendByte( Buf, 0x89 ) )                                   return 0;
    if ( !AppendByte( Buf, ModRm( 3, Lo3( Src ), Lo3( Dst ) ) ) )     return 0;
    return 1;
}

int X64Emit_ArithRaxReg( LcCodeBuf *Buf, unsigned char Op, X64_GPR_T Src ) {
    /* REX.W <Op> /r with reg = RAX, rm = Src (register-direct).
       Op: 0x03 ADD, 0x2B SUB, 0x23 AND, 0x0B OR, 0x33 XOR, 0x3B CMP,
       0xAF -> 0F AF IMUL rax, rN. */
    unsigned char Rex = REX_BASE | REX_W | ( IsHi( Src ) ? REX_B : 0 );
    if ( !AppendByte( Buf, Rex ) )                                return 0;
    if ( Op == 0xAF && !AppendByte( Buf, 0x0F ) )                 return 0;
    if ( !AppendByte( Buf, Op ) )                                 return 0;
    return AppendByte( Buf, ModRm( 3, 0, Lo3( Src ) ) );
}

int X64Emit_Ret( LcCodeBuf *Buf ) {
    return AppendByte( Buf, 0xC3 );
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
static int EmitMemOp( LcCodeBuf *Buf,
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
        if ( !AppendByte( Buf, Rex ) )                                        return 0;
    }
    if ( !AppendByte( Buf, Opcode ) )                                         return 0;
    if ( !AppendByte( Buf, ModRm( Mod, RegField, Lo3( Base ) ) ) )            return 0;
    if ( NeedsSib ) {
        /* SIB: scale=00, index=100 (none), base=Lo3(Base) */
        if ( !AppendByte( Buf, ( unsigned char )( ( 4u << 3 ) | Lo3( Base ) ) ) ) return 0;
    }
    if ( Mod == 1 ) {
        int8_t D8 = ( int8_t )Disp;
        if ( !AppendBytes( Buf, &D8, 1 ) )                                    return 0;
    } else if ( Mod == 2 ) {
        if ( !AppendBytes( Buf, &Disp, 4 ) )                                  return 0;
    }
    return 1;
}

int X64Emit_MovMemToReg( LcCodeBuf *Buf, X64_GPR_T Dst,
                         X64_GPR_T Base, int32_t Disp ) {
    /* 0x8B /r  MOV r64, r/m64 */
    return EmitMemOp( Buf, 0x8B, Lo3( Dst ), IsHi( Dst ), Base, Disp, 1 );
}

int X64Emit_LeaRegMem( LcCodeBuf *Buf, X64_GPR_T Dst,
                       X64_GPR_T Base, int32_t Disp ) {
    /* 0x8D /r  LEA r64, [Base + Disp] */
    return EmitMemOp( Buf, 0x8D, Lo3( Dst ), IsHi( Dst ), Base, Disp, 1 );
}

int X64Emit_MovRegToMem( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp,
                         X64_GPR_T Src ) {
    /* 0x89 /r  MOV r/m64, r64 */
    return EmitMemOp( Buf, 0x89, Lo3( Src ), IsHi( Src ), Base, Disp, 1 );
}

int X64Emit_MovImm32ToMem( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp,
                           int32_t Imm ) {
    /* C7 /0 id   MOV r/m32, imm32   (32-bit operand, no REX.W) */
    if ( !EmitMemOp( Buf, 0xC7, 0, 0, Base, Disp, 0 ) ) return 0;
    return AppendBytes( Buf, &Imm, 4 );
}

int X64Emit_CmpMem32Imm32( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp,
                           int32_t Imm ) {
    /* 81 /7 id   CMP r/m32, imm32 */
    if ( !EmitMemOp( Buf, 0x81, 7, 0, Base, Disp, 0 ) ) return 0;
    return AppendBytes( Buf, &Imm, 4 );
}

int X64Emit_CmpMem8Imm8( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp,
                         int8_t Imm ) {
    /* 80 /7 ib   CMP r/m8, imm8 */
    if ( !EmitMemOp( Buf, 0x80, 7, 0, Base, Disp, 0 ) ) return 0;
    return AppendBytes( Buf, &Imm, 1 );
}

int X64Emit_AddMemToReg( LcCodeBuf *Buf, X64_GPR_T Dst,
                         X64_GPR_T Base, int32_t Disp ) {
    /* 03 /r   ADD r64, r/m64 */
    return EmitMemOp( Buf, 0x03, Lo3( Dst ), IsHi( Dst ), Base, Disp, 1 );
}

int X64Emit_JneRel8( LcCodeBuf *Buf, int8_t Rel ) {
    if ( !AppendByte( Buf, 0x75 ) )       return 0;
    return AppendBytes( Buf, &Rel, 1 );
}

int X64Emit_JmpRel8( LcCodeBuf *Buf, int8_t Rel ) {
    if ( !AppendByte( Buf, 0xEB ) )       return 0;
    return AppendBytes( Buf, &Rel, 1 );
}

size_t X64Emit_JmpRel8_Placeholder( LcCodeBuf *Buf ) {
    if ( Buf == NULL ) { return ( size_t )-1; }
    unsigned char Bytes[ 2 ] = { 0xEB, 0x00 };
    if ( !LcCodeBuf_Append( Buf, Bytes, 2 ) ) { return ( size_t )-1; }
    return Buf->used - 1;
}

int X64Emit_PatchRel8( LcCodeBuf *Buf, size_t PatchOffset, size_t TargetOffset ) {
    if ( Buf == NULL || Buf->bytes == NULL ) { return 0; }
    if ( PatchOffset >= Buf->used ) { return 0; }
    long long Delta = ( long long )TargetOffset - ( long long )( PatchOffset + 1 );
    if ( Delta < -128 || Delta > 127 ) { return 0; }
    Buf->bytes[ PatchOffset ] = ( unsigned char )( int8_t )Delta;
    return 1;
}

size_t X64Emit_JmpRel32_Placeholder( LcCodeBuf *Buf ) {
    if ( Buf == NULL ) { return ( size_t )-1; }
    unsigned char Bytes[ 5 ] = { 0xE9, 0x00, 0x00, 0x00, 0x00 };
    if ( !LcCodeBuf_Append( Buf, Bytes, 5 ) ) { return ( size_t )-1; }
    return Buf->used - 4;
}

size_t X64Emit_JccRel32_Placeholder( LcCodeBuf *Buf, unsigned Cc ) {
    if ( Buf == NULL ) { return ( size_t )-1; }
    unsigned char Bytes[ 6 ] = { 0x0F, ( unsigned char )( 0x80 | ( Cc & 0xF ) ),
                                  0x00, 0x00, 0x00, 0x00 };
    if ( !LcCodeBuf_Append( Buf, Bytes, 6 ) ) { return ( size_t )-1; }
    return Buf->used - 4;
}

int X64Emit_PatchRel32( LcCodeBuf *Buf, size_t PatchOffset, size_t TargetOffset ) {
    if ( Buf == NULL || Buf->bytes == NULL ) { return 0; }
    if ( PatchOffset + 4 > Buf->used ) { return 0; }
    long long Delta = ( long long )TargetOffset - ( long long )( PatchOffset + 4 );
    if ( Delta < -2147483648LL || Delta > 2147483647LL ) { return 0; }
    int32_t Disp32 = ( int32_t )Delta;
    /* little-endian store */
    Buf->bytes[ PatchOffset + 0 ] = ( unsigned char )( Disp32         & 0xFF );
    Buf->bytes[ PatchOffset + 1 ] = ( unsigned char )( ( Disp32 >> 8  ) & 0xFF );
    Buf->bytes[ PatchOffset + 2 ] = ( unsigned char )( ( Disp32 >> 16 ) & 0xFF );
    Buf->bytes[ PatchOffset + 3 ] = ( unsigned char )( ( Disp32 >> 24 ) & 0xFF );
    return 1;
}

int X64Emit_TestEaxEax( LcCodeBuf *Buf )
{
    /* 85 C0   TEST eax, eax  (32-bit; ModR/M mod=11 reg=eax rm=eax) */
    unsigned char Bytes[ 2 ] = { 0x85, 0xC0 };
    return AppendBytes( Buf, Bytes, 2 );
}

int X64Emit_CmpEaxImm8( LcCodeBuf *Buf, int8_t Imm )
{
    /* 83 F8 ib   CMP eax, imm8  (/7, sign-extended imm8) */
    unsigned char Bytes[ 3 ] = { 0x83, 0xF8, ( unsigned char )Imm };
    return AppendBytes( Buf, Bytes, 3 );
}

int X64Emit_PushReg( LcCodeBuf *Buf, X64_GPR_T Reg )
{
    /* PUSH r64: 50+r (opt REX.B for high regs).  PUSH defaults to 64-bit
       operand size on x64 — no REX.W needed. */
    if ( IsHi( Reg ) ) {
        if ( !AppendByte( Buf, REX_BASE | REX_B ) ) return 0;
    }
    return AppendByte( Buf, ( unsigned char )( 0x50 + Lo3( Reg ) ) );
}

int X64Emit_PopReg( LcCodeBuf *Buf, X64_GPR_T Reg )
{
    if ( IsHi( Reg ) ) {
        if ( !AppendByte( Buf, REX_BASE | REX_B ) ) return 0;
    }
    return AppendByte( Buf, ( unsigned char )( 0x58 + Lo3( Reg ) ) );
}

int X64Emit_SubRspImm( LcCodeBuf *Buf, int32_t Imm )
{
    /* 48 81 EC id   SUB rsp, imm32   (always use imm32 form for simplicity) */
    if ( !AppendByte( Buf, REX_BASE | REX_W ) )                  return 0;
    if ( !AppendByte( Buf, 0x81 ) )                              return 0;
    if ( !AppendByte( Buf, ModRm( 3, 5, 4 ) ) )                  return 0; /* /5, rm=rsp */
    return AppendBytes( Buf, &Imm, 4 );
}

int X64Emit_AddRspImm( LcCodeBuf *Buf, int32_t Imm )
{
    /* 48 81 C4 id   ADD rsp, imm32 */
    if ( !AppendByte( Buf, REX_BASE | REX_W ) )                  return 0;
    if ( !AppendByte( Buf, 0x81 ) )                              return 0;
    if ( !AppendByte( Buf, ModRm( 3, 0, 4 ) ) )                  return 0; /* /0, rm=rsp */
    return AppendBytes( Buf, &Imm, 4 );
}

int X64Emit_AddRegImm32( LcCodeBuf *Buf, X64_GPR_T Reg, int32_t Imm )
{
    /* REX.W [+B] 81 /0 id   ADD r64, imm32.  Always uses the imm32 form for
       simplicity and byte-stability (matches v1's hand-emitted ADD RDI,16:
       48 81 C7 10 00 00 00). */
    unsigned char Rex = REX_BASE | REX_W | ( IsHi( Reg ) ? REX_B : 0 );
    if ( !AppendByte( Buf, Rex ) )                               return 0;
    if ( !AppendByte( Buf, 0x81 ) )                              return 0;
    if ( !AppendByte( Buf, ModRm( 3, 0, Lo3( Reg ) ) ) )         return 0; /* /0, rm=Reg */
    return AppendBytes( Buf, &Imm, 4 );
}

int X64Emit_CallAbs( LcCodeBuf *Buf, void *Target )
{
    /* 48 B8 imm64 ; FF D0 — mov rax, imm64 ; call rax */
    if ( !X64Emit_MovImm64ToReg( Buf, X64_RAX, ( uint64_t )( uintptr_t )Target ) ) return 0;
    if ( !AppendByte( Buf, 0xFF ) )                              return 0;
    if ( !AppendByte( Buf, ModRm( 3, 2, 0 ) ) )                  return 0; /* /2, rm=rax */
    return 1;
}

/*!
 * @brief
 *  Emit a "F2 0F <opcode> /r" SSE2 mem-form instruction with XMM0 as the
 *  reg-field operand and [Base + Disp] as the r/m operand. ModR/M uses
 *  the same disp0/disp8/disp32 selection logic as the integer EmitMemOp,
 *  but doesn't need a REX prefix for the XMM0..XMM7 + RAX..RDI case.
 */
static int EmitSse2MemForm( LcCodeBuf *Buf, unsigned char Sse2Opcode,
                             X64_GPR_T Base, int32_t Disp ) {
    /* prefix: F2 0F <opcode> */
    unsigned char Prefix[ 3 ] = { 0xF2, 0x0F, Sse2Opcode };
    if ( !LcCodeBuf_Append( Buf, Prefix, 3 ) ) return 0;

    /* ModR/M with reg=000 (XMM0), rm=Lo3(Base). */
    int      RbpLike = ( Lo3( Base ) == 5 );
    int      Mod     = ( Disp == 0 && !RbpLike ) ? 0 :
                       ( ( Disp >= -128 && Disp <= 127 ) ? 1 : 2 );
    unsigned ModRm8  = ( unsigned )( ( Mod << 6 ) | ( 0 << 3 ) | Lo3( Base ) );
    if ( !AppendByte( Buf, ( unsigned char )ModRm8 ) ) return 0;

    /* SIB for RSP-like bases (Lo3 == 4) */
    if ( Lo3( Base ) == 4 ) {
        unsigned char Sib = ( unsigned char )( ( 4u << 3 ) | Lo3( Base ) );
        if ( !AppendByte( Buf, Sib ) ) return 0;
    }
    if ( Mod == 1 ) {
        int8_t D8 = ( int8_t )Disp;
        if ( !AppendBytes( Buf, &D8, 1 ) ) return 0;
    } else if ( Mod == 2 ) {
        if ( !AppendBytes( Buf, &Disp, 4 ) ) return 0;
    }
    return 1;
}

/* Same mem-form encoder with the 66 prefix (ucomisd family). */
static int EmitSse66MemForm( LcCodeBuf *Buf, unsigned char Opcode,
                              X64_GPR_T Base, int32_t Disp ) {
    unsigned char Prefix[ 3 ] = { 0x66, 0x0F, Opcode };
    int      RbpLike, Mod;
    unsigned ModRm8;
    if ( !LcCodeBuf_Append( Buf, Prefix, 3 ) ) return 0;
    RbpLike = ( Lo3( Base ) == 5 );
    Mod     = ( Disp == 0 && !RbpLike ) ? 0 :
              ( ( Disp >= -128 && Disp <= 127 ) ? 1 : 2 );
    ModRm8  = ( unsigned )( ( Mod << 6 ) | ( 0 << 3 ) | Lo3( Base ) );
    if ( !AppendByte( Buf, ( unsigned char )ModRm8 ) ) return 0;
    if ( Lo3( Base ) == 4 ) {
        unsigned char Sib = ( unsigned char )( ( 4u << 3 ) | Lo3( Base ) );
        if ( !AppendByte( Buf, Sib ) ) return 0;
    }
    if ( Mod == 1 ) {
        int8_t D8 = ( int8_t )Disp;
        if ( !AppendBytes( Buf, &D8, 1 ) ) return 0;
    } else if ( Mod == 2 ) {
        if ( !AppendBytes( Buf, &Disp, 4 ) ) return 0;
    }
    return 1;
}

int X64Emit_UcomisdXmm0Mem( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp ) {
    /* 66 0F 2E /r -- UCOMISD xmm0, m64 (sets ZF/PF/CF; unordered = all 1). */
    return EmitSse66MemForm( Buf, 0x2E, Base, Disp );
}

/*!
 * @brief
 *  General SSE "<Pfx> [REX] 0F <Op> /r" encoder with an XMM reg-field operand
 *  (0..15) and either an XMM register r/m (RmXmm >= 0) or a [Base + Disp]
 *  memory r/m (RmXmm < 0; Base must be a low GPR -- RDI/RSP here). Pfx 0
 *  emits no prefix byte (movups). Emits REX only when an XMM operand is >= 8
 *  (REX.R for the reg field, REX.B for a register r/m).
 */
static int EmitSseXmmRm( LcCodeBuf *Buf, int Pfx, unsigned char Op,
                          int XmmReg, int RmXmm, X64_GPR_T Base, int32_t Disp ) {
    unsigned char Tmp[ 10 ];
    int N = 0;
    unsigned char Rex = 0x40;
    if ( XmmReg < 0 || XmmReg > 15 ) return 0;
    if ( Pfx ) Tmp[ N++ ] = ( unsigned char )Pfx;
    if ( XmmReg >= 8 ) Rex |= 0x04;                       /* REX.R */
    if ( RmXmm >= 8 )  Rex |= 0x01;                       /* REX.B */
    if ( Rex != 0x40 ) Tmp[ N++ ] = Rex;
    Tmp[ N++ ] = 0x0F;
    Tmp[ N++ ] = Op;
    if ( RmXmm >= 0 ) {                                   /* register form */
        Tmp[ N++ ] = ( unsigned char )( 0xC0 | ( ( XmmReg & 7 ) << 3 ) | ( RmXmm & 7 ) );
    } else {                                              /* [Base + Disp] */
        int Mod = ( Disp == 0 && ( int )Base != X64_RBP ) ? 0
                : ( Disp >= -128 && Disp <= 127 ) ? 1 : 2;
        if ( ( int )Base > 7 ) return 0;
        Tmp[ N++ ] = ( unsigned char )( ( Mod << 6 ) | ( ( XmmReg & 7 ) << 3 ) | ( ( int )Base & 7 ) );
        if ( ( int )Base == X64_RSP ) Tmp[ N++ ] = 0x24;  /* SIB */
        if ( Mod == 1 ) {
            Tmp[ N++ ] = ( unsigned char )( int8_t )Disp;
        } else if ( Mod == 2 ) {
            memcpy( &Tmp[ N ], &Disp, 4 ); N += 4;
        }
    }
    return LcCodeBuf_Append( Buf, Tmp, ( size_t )N );
}

int X64Emit_MovsdLoadXmm( LcCodeBuf *Buf, int XmmN, X64_GPR_T Base, int32_t Disp ) {
    return EmitSseXmmRm( Buf, 0xF2, 0x10, XmmN, -1, Base, Disp );   /* xmmN = m64 */
}
int X64Emit_MovsdStoreXmm( LcCodeBuf *Buf, int XmmN, X64_GPR_T Base, int32_t Disp ) {
    return EmitSseXmmRm( Buf, 0xF2, 0x11, XmmN, -1, Base, Disp );   /* m64 = xmmN */
}
int X64Emit_MovsdXmmXmm( LcCodeBuf *Buf, int Dst, int Src ) {
    return EmitSseXmmRm( Buf, 0xF2, 0x10, Dst, Src, X64_RAX, 0 );   /* xmmD = xmmS */
}
int X64Emit_ArithSdXmm0Xmm( LcCodeBuf *Buf, unsigned char Op, int Src ) {
    return EmitSseXmmRm( Buf, 0xF2, Op, 0, Src, X64_RAX, 0 );       /* xmm0 op= xmmS */
}
int X64Emit_ArithSdXmm0Mem( LcCodeBuf *Buf, unsigned char Op,
                            X64_GPR_T Base, int32_t Disp ) {
    return EmitSseXmmRm( Buf, 0xF2, Op, 0, -1, Base, Disp );        /* xmm0 op= m64 */
}
int X64Emit_UcomisdXmm0Xmm( LcCodeBuf *Buf, int Src ) {
    return EmitSseXmmRm( Buf, 0x66, 0x2E, 0, Src, X64_RAX, 0 );
}
int X64Emit_ArithSdXmmXmm( LcCodeBuf *Buf, unsigned char Op, int Dst, int Src ) {
    return EmitSseXmmRm( Buf, 0xF2, Op, Dst, Src, X64_RAX, 0 );
}
int X64Emit_ArithSdXmmMem( LcCodeBuf *Buf, unsigned char Op, int Dst,
                           X64_GPR_T Base, int32_t Disp ) {
    return EmitSseXmmRm( Buf, 0xF2, Op, Dst, -1, Base, Disp );
}
int X64Emit_MovupsStoreXmm( LcCodeBuf *Buf, int XmmN, X64_GPR_T Base, int32_t Disp ) {
    return EmitSseXmmRm( Buf, 0, 0x11, XmmN, -1, Base, Disp );      /* m128 = xmmN */
}
int X64Emit_MovupsLoadXmm( LcCodeBuf *Buf, int XmmN, X64_GPR_T Base, int32_t Disp ) {
    return EmitSseXmmRm( Buf, 0, 0x10, XmmN, -1, Base, Disp );      /* xmmN = m128 */
}

int X64Emit_UcomisdXmm0Xmm1( LcCodeBuf *Buf ) {
    /* 66 0F 2E C1 -- UCOMISD xmm0, xmm1. */
    unsigned char Tmp[ 4 ] = { 0x66, 0x0F, 0x2E, 0xC1 };
    return LcCodeBuf_Append( Buf, Tmp, 4 );
}

int X64Emit_MovsdMemToXmm0( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp ) {
    return EmitSse2MemForm( Buf, 0x10, Base, Disp );
}
int X64Emit_MovsdXmm0ToMem( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp ) {
    return EmitSse2MemForm( Buf, 0x11, Base, Disp );
}
int X64Emit_AddsdMemToXmm0( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp ) {
    return EmitSse2MemForm( Buf, 0x58, Base, Disp );
}
int X64Emit_SubsdMemToXmm0( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp ) {
    return EmitSse2MemForm( Buf, 0x5C, Base, Disp );
}
int X64Emit_MulsdMemToXmm0( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp ) {
    return EmitSse2MemForm( Buf, 0x59, Base, Disp );
}
int X64Emit_DivsdMemToXmm0( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp ) {
    return EmitSse2MemForm( Buf, 0x5E, Base, Disp );
}

/* Internal: emit MOVSD or MOVSS into XmmN (0..7).
   Format: PrefixByte [REX] 0F 10 ModR/M [disp8|disp32].
   ModR/M.reg = XmmN, ModR/M.rm = Base GPR (low 3 bits).
   REX is needed only if Base is R8..R15 (we don't use those here). */
static int EmitMovScalarMemToXmmN( LcCodeBuf *Buf, int PrefixByte,
                                   int XmmN, X64_GPR_T Base, int32_t Disp ) {
    if ( XmmN < 0 || XmmN > 7 ) return 0;
    if ( ( int )Base > 7 ) return 0;
    unsigned char Tmp[ 8 ];
    int N = 0;
    Tmp[ N++ ] = ( unsigned char )PrefixByte;
    Tmp[ N++ ] = 0x0F;
    Tmp[ N++ ] = 0x10;
    int Mod = ( Disp == 0 && ( int )Base != X64_RBP ) ? 0
            : ( Disp >= -128 && Disp <= 127 ) ? 1 : 2;
    Tmp[ N++ ] = ( unsigned char )( ( Mod << 6 ) | ( ( XmmN & 7 ) << 3 ) | ( ( int )Base & 7 ) );
    if ( ( int )Base == X64_RSP ) {
        Tmp[ N++ ] = 0x24;
    }
    if ( Mod == 1 ) {
        Tmp[ N++ ] = ( unsigned char )( int8_t )Disp;
    } else if ( Mod == 2 ) {
        memcpy( &Tmp[ N ], &Disp, 4 );
        N += 4;
    }
    return LcCodeBuf_Append( Buf, Tmp, ( size_t )N );
}

int X64Emit_MovsdMemToXmmN( LcCodeBuf *Buf, int XmmN,
                            X64_GPR_T Base, int32_t Disp ) {
    return EmitMovScalarMemToXmmN( Buf, 0xF2, XmmN, Base, Disp );
}

int X64Emit_MovssMemToXmmN( LcCodeBuf *Buf, int XmmN,
                            X64_GPR_T Base, int32_t Disp ) {
    return EmitMovScalarMemToXmmN( Buf, 0xF3, XmmN, Base, Disp );
}

int X64Emit_MovqXmm0ToReg64( LcCodeBuf *Buf, X64_GPR_T Dst ) {
    /* 66 REX.W 0F 7E /r -- MOVQ r/m64, xmm.  ModR/M reg = xmm0 (0), rm = Dst. */
    unsigned char Tmp[ 5 ];
    int N = 0;
    Tmp[ N++ ] = 0x66;
    Tmp[ N++ ] = ( unsigned char )( 0x48 | ( ( ( int )Dst & 8 ) ? 0x01 : 0 ) );
    Tmp[ N++ ] = 0x0F;
    Tmp[ N++ ] = 0x7E;
    Tmp[ N++ ] = ( unsigned char )( 0xC0 | ( ( 0 & 7 ) << 3 ) | ( ( int )Dst & 7 ) );
    return LcCodeBuf_Append( Buf, Tmp, ( size_t )N );
}

int X64Emit_MovqReg64ToXmm0( LcCodeBuf *Buf, X64_GPR_T Src ) {
    /* 66 REX.W 0F 6E /r -- MOVQ xmm, r/m64. */
    unsigned char Tmp[ 5 ];
    int N = 0;
    Tmp[ N++ ] = 0x66;
    Tmp[ N++ ] = ( unsigned char )( 0x48 | ( ( ( int )Src & 8 ) ? 0x01 : 0 ) );
    Tmp[ N++ ] = 0x0F;
    Tmp[ N++ ] = 0x6E;
    Tmp[ N++ ] = ( unsigned char )( 0xC0 | ( ( 0 & 7 ) << 3 ) | ( ( int )Src & 7 ) );
    return LcCodeBuf_Append( Buf, Tmp, ( size_t )N );
}

int X64Emit_MovqReg64ToXmmN( LcCodeBuf *Buf, int XmmN, X64_GPR_T Src ) {
    /* 66 REX.W 0F 6E /r -- MOVQ xmm, r/m64.  ModR/M reg = XmmN (0..15, REX.R
       for the high bank), rm = Src. */
    unsigned char Tmp[ 5 ];
    int N = 0;
    if ( XmmN < 0 || XmmN > 15 ) return 0;
    Tmp[ N++ ] = 0x66;
    Tmp[ N++ ] = ( unsigned char )( 0x48 | ( ( XmmN & 8 ) ? 0x04 : 0 )
                                         | ( ( ( int )Src & 8 ) ? 0x01 : 0 ) );
    Tmp[ N++ ] = 0x0F;
    Tmp[ N++ ] = 0x6E;
    Tmp[ N++ ] = ( unsigned char )( 0xC0 | ( ( XmmN & 7 ) << 3 ) | ( ( int )Src & 7 ) );
    return LcCodeBuf_Append( Buf, Tmp, ( size_t )N );
}

int X64Emit_ArithSdXmm0Xmm1( LcCodeBuf *Buf, unsigned char Op ) {
    /* F2 0F <Op> /r -- scalar-double op, ModR/M C1 = xmm0, xmm1. */
    unsigned char Tmp[ 4 ];
    if ( Op != 0x58 && Op != 0x5C && Op != 0x59 && Op != 0x5E ) return 0;
    Tmp[ 0 ] = 0xF2;
    Tmp[ 1 ] = 0x0F;
    Tmp[ 2 ] = Op;
    Tmp[ 3 ] = 0xC1;
    return LcCodeBuf_Append( Buf, Tmp, 4 );
}

/* ---- AOT-only reloc emitters -------------------------------------------- */

int X64Emit_CallSym( LcCodeBuf *Buf, const char *Sym ) {
    uint8_t op = 0xE8;
    if ( !LcCodeBuf_Append( Buf, &op, 1 ) ) return 0;
    uint32_t at = ( uint32_t )Buf->used;            /* disp32 starts here */
    uint8_t z4[4] = { 0, 0, 0, 0 };
    if ( !LcCodeBuf_Append( Buf, z4, 4 ) ) return 0;
    /* REL32 addend -4: disp is relative to the END of the instruction. */
    return LcCodeBuf_AddReloc( Buf, LC_RELOC_REL32, at, Sym, -4 );
}

int X64Emit_LeaRipSym( LcCodeBuf *Buf, X64_GPR_T Dst, const char *Sym ) {
    /* 48 8D /r  ModRM = mod=00 reg=Dst rm=101 (RIP-relative) */
    uint8_t rex   = ( uint8_t )( 0x48 | ( ( Dst >= X64_R8 ) ? 0x04 : 0x00 ) );
    uint8_t opc   = 0x8D;
    uint8_t modrm = ( uint8_t )( 0x00 | ( ( Dst & 7 ) << 3 ) | 0x05 );
    uint8_t pre[3] = { rex, opc, modrm };
    if ( !LcCodeBuf_Append( Buf, pre, 3 ) ) return 0;
    uint32_t at = ( uint32_t )Buf->used;
    uint8_t z4[4] = { 0, 0, 0, 0 };
    if ( !LcCodeBuf_Append( Buf, z4, 4 ) ) return 0;
    return LcCodeBuf_AddReloc( Buf, LC_RELOC_REL32_RDATA, at, Sym, -4 );
}
