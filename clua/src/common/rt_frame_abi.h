/*!
 * @file rt_frame_abi.h
 * @brief
 *  The calling convention for table helpers that are handed the frame base.
 *
 *  THE PROBLEM. The original helpers take (L, A, B, C) and re-derive
 *  everything else from L:
 *
 *      StkId   Base = L->ci->func.p + 1;                        2 loads
 *      TValue *Key  = &clLvalue(s2v(L->ci->func.p))->p->k[C];   3 more
 *
 *  Five dependent loads before any real work, on every table access -- and the
 *  compiled code already HAS the frame base sitting in RDI, which it reloads
 *  after each call anyway. It was throwing that away and paying to rebuild it.
 *  Measured: table field r/w ran 0.80x the reference interpreter, the worst
 *  number in the project, on a kernel where the interpreter does the identical
 *  hash lookup. The gap was glue, not lookup.
 *
 *  THE CONVENTION. Pass the base, and pack the operands into one word:
 *
 *      RCX = L        (already in RBX for the whole function)
 *      RDX = Base     (already in RDI, valid at every call site)
 *      R8  = packed A, B, C, K
 *
 *  Base - 1 is L->ci->func.p, so the Proto chain costs 3 loads instead of 5,
 *  and the base itself costs none. The call site also SHRINKS, from three
 *  32-bit immediate moves (20 bytes) to a register copy plus one (12).
 *
 *  FIELD WIDTH. Ten bits per operand. Lua's iABC operands are 8 bits, so this
 *  has 4x headroom, and codegen refuses to use the convention when a
 *  lift-time-encoded operand does not fit -- see LC_RTF_FITS. Falling back
 *  costs speed, never correctness.
 *
 *  K is the setter helpers' "value operand is a constant" flag. Those take a
 *  SIGNED Ck where negative means K=1 (see DecodeCk in jit/runtime.c); codegen
 *  decodes it at compile time, since it is a constant there, and passes the bit.
 */

#ifndef CLUA_RT_FRAME_ABI_H
#define CLUA_RT_FRAME_ABI_H

#define LC_RTF_BITS  10
#define LC_RTF_MAX   ( ( 1 << LC_RTF_BITS ) - 1 )

/* TRUE iff a, b and c all fit the packed fields. c is passed already decoded
   (non-negative), so a caller holding a signed Ck must decode it first. */
#define LC_RTF_FITS( a, b, c )                                                \
    ( ( unsigned )( a ) <= LC_RTF_MAX &&                                      \
      ( unsigned )( b ) <= LC_RTF_MAX &&                                      \
      ( unsigned )( c ) <= LC_RTF_MAX )

/* Bit 30 is the highest used, so the word is always a positive int32 and can
   be emitted as a plain `mov r8d, imm32`. */
#define LC_RTF_PACK( a, b, c, k )                                             \
    ( ( unsigned )( a )                        |                              \
      ( ( unsigned )( b ) << LC_RTF_BITS )     |                              \
      ( ( unsigned )( c ) << ( 2 * LC_RTF_BITS ) ) |                          \
      ( ( unsigned )( ( k ) != 0 ) << ( 3 * LC_RTF_BITS ) ) )

#define LC_RTF_A( w ) ( ( int )(   ( unsigned )( w )                        & LC_RTF_MAX ) )
#define LC_RTF_B( w ) ( ( int )( ( ( unsigned )( w ) >> LC_RTF_BITS )       & LC_RTF_MAX ) )
#define LC_RTF_C( w ) ( ( int )( ( ( unsigned )( w ) >> ( 2 * LC_RTF_BITS ) ) & LC_RTF_MAX ) )
#define LC_RTF_K( w ) ( ( int )( ( ( unsigned )( w ) >> ( 3 * LC_RTF_BITS ) ) & 1u ) )

#endif /* CLUA_RT_FRAME_ABI_H */
