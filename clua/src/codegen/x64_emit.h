/*!
 * @brief
 *  Primitive x64 instruction encoder (retargeted from the v1 JIT encoder,
 *  which has since been removed from the tree). Each emitter appends bytes
 *  to an LcCodeBuf's growable region. ModR/M / SIB / REX / displacement /
 *  opcode logic is byte-for-byte identical to v1 — only the buffer plumbing
 *  and the public name prefix differ, plus two AOT-only reloc emitters
 *  (X64Emit_CallSym / X64Emit_LeaRipSym).
 */

#ifndef LUAC_CODEGEN_X64_EMIT_H
#define LUAC_CODEGEN_X64_EMIT_H

#include <stddef.h>
#include <stdint.h>

#include "codegen/lc_codebuf.h"

/* x64 general-purpose register identifiers (3-bit value + W bit handled by
   encoder). Names match Intel docs; the numeric value is the field that
   appears in ModR/M. */
typedef enum _X64_GPR {
    X64_RAX = 0,  X64_RCX = 1,  X64_RDX = 2,  X64_RBX = 3,
    X64_RSP = 4,  X64_RBP = 5,  X64_RSI = 6,  X64_RDI = 7,
    X64_R8  = 8,  X64_R9  = 9,  X64_R10 = 10, X64_R11 = 11,
    X64_R12 = 12, X64_R13 = 13, X64_R14 = 14, X64_R15 = 15
} X64_GPR_T;

/*!
 * @brief
 *  REX.W = 1 MOV r64, imm64.  10 bytes total.
 *      48+B B8+r  imm64
 */
int X64Emit_MovImm64ToReg( LcCodeBuf *Buf, X64_GPR_T Dst, uint64_t Imm );

/*!
 * @brief
 *  REX.W = 1 MOV r64, r/m64 with 8-bit or 32-bit displacement.
 *  Encodes:  MOV Dst, [Base + Disp]
 */
int X64Emit_MovMemToReg( LcCodeBuf *Buf, X64_GPR_T Dst,
                         X64_GPR_T Base, int32_t Disp );

/*!
 * @brief
 *  REX.W = 1 MOV r/m64, r64.   Encodes:  MOV [Base + Disp], Src
 */
int X64Emit_MovRegToMem( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp,
                         X64_GPR_T Src );

/*!
 * @brief
 *  REX.W = 1 MOV r64, r64.    Encodes:  MOV Dst, Src
 */
int X64Emit_MovRegToReg( LcCodeBuf *Buf, X64_GPR_T Dst, X64_GPR_T Src );

/*!
 * @brief
 *  MOV r/m32, imm32.   Encodes:  MOV [Base + Disp], imm32  (32-bit store).
 *  Used to write the TValue tag word (32 bits).
 */
int X64Emit_MovImm32ToMem( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp,
                           int32_t Imm );

/*!
 * @brief
 *  CMP r/m32, imm32   (zero-extended/sign-extended depending on imm size).
 *  Encodes:  CMP [Base + Disp], imm32
 */
int X64Emit_CmpMem32Imm32( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp,
                           int32_t Imm );

/*!
 * @brief
 *  CMP r/m8, imm8.  Encodes:  CMP byte [Base + Disp], imm8
 *  Use this for Lua TValue tag checks: tt_ is a 1-byte field at offset +8,
 *  with 7 bytes of uninitialized padding after it. A 32-bit dword cmp would
 *  read 3 stale bytes of padding and can falsely fail even when the tag
 *  itself matches (after setobjs2s, setnilvalue, etc. -- the Lua C helpers
 *  only write the tag byte, leaving padding untouched).
 */
int X64Emit_CmpMem8Imm8( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp,
                         int8_t Imm );

/*!
 * @brief
 *  REX.W = 1 ADD r64, r/m64.   Encodes:  ADD Dst, [Base + Disp]
 */
int X64Emit_AddMemToReg( LcCodeBuf *Buf, X64_GPR_T Dst,
                         X64_GPR_T Base, int32_t Disp );

/*!
 * @brief
 *  JNE rel8.  4-byte conditional skip-forward by N bytes.
 *  (We hand-compute the forward jump distance when emitting fast paths.)
 */
int X64Emit_JneRel8( LcCodeBuf *Buf, int8_t Rel );

/*!
 * @brief
 *  JMP rel8.
 */
int X64Emit_JmpRel8( LcCodeBuf *Buf, int8_t Rel );

/*!
 * @brief
 *  Emit JMP rel8 with placeholder displacement (0). Returns the offset of
 *  the displacement byte (inside Buf->bytes) so the caller can patch it
 *  later once the target's position is known. Returns SIZE_MAX on failure.
 */
size_t X64Emit_JmpRel8_Placeholder( LcCodeBuf *Buf );

/*!
 * @brief
 *  Patch a rel8 displacement byte (previously written by a Placeholder emit
 *  or any other rel8 instruction). `PatchOffset` is the position of the
 *  displacement byte; `TargetOffset` is where execution should land.
 *  Returns 1 on success, 0 if the offset doesn't fit in int8.
 */
int X64Emit_PatchRel8( LcCodeBuf *Buf, size_t PatchOffset, size_t TargetOffset );

/*!
 * @brief
 *  Emit JMP rel32 (E9 disp32) with placeholder displacement (0). Returns
 *  the offset of the first byte of the disp32 word (4 bytes wide) so a
 *  caller can patch it via X64Emit_PatchRel32. Returns SIZE_MAX on failure.
 */
size_t X64Emit_JmpRel32_Placeholder( LcCodeBuf *Buf );

/*!
 * @brief
 *  Emit Jcc rel32 with placeholder. `Cc` is the 4-bit condition code that
 *  goes into the opcode's low nibble (e.g. 0x4 = JE, 0x5 = JNE, 0xC = JL,
 *  0xD = JGE, 0xE = JLE, 0xF = JG — see Intel SDM Vol. 2A Appendix B).
 *  Encoded as 0F 8x disp32 (6 bytes). Returns disp32 byte offset.
 */
size_t X64Emit_JccRel32_Placeholder( LcCodeBuf *Buf, unsigned Cc );

/*!
 * @brief
 *  Patch a 32-bit displacement at PatchOffset to point at TargetOffset.
 *  Same semantics as PatchRel8 but with int32 range.
 */
int X64Emit_PatchRel32( LcCodeBuf *Buf, size_t PatchOffset, size_t TargetOffset );

/*!
 * @brief
 *  TEST eax, eax.  Bytes: 85 C0. Sets ZF iff eax == 0; used after a helper that
 *  returns a 0/1 (or skip/continue) flag in RAX to branch on it.
 */
int X64Emit_TestEaxEax( LcCodeBuf *Buf );

/*!
 * @brief
 *  CMP eax, imm8.  Bytes: 83 F8 ib (sign-extended imm8). Used to compare a
 *  comparison helper's 0/1 result against the k-bit.
 */
int X64Emit_CmpEaxImm8( LcCodeBuf *Buf, int8_t Imm );

/*!
 * @brief
 *  PUSH r64, POP r64.
 */
int X64Emit_PushReg( LcCodeBuf *Buf, X64_GPR_T Reg );
int X64Emit_PopReg ( LcCodeBuf *Buf, X64_GPR_T Reg );

/*!
 * @brief
 *  SUB r/m64, imm32. Used for stack-reserve.
 */
int X64Emit_SubRspImm( LcCodeBuf *Buf, int32_t Imm );

/*!
 * @brief
 *  ADD r/m64, imm32. Used to release stack reserve.
 */
int X64Emit_AddRspImm( LcCodeBuf *Buf, int32_t Imm );

/*!
 * @brief
 *  REX.W = 1 ADD r64, imm32.   Encodes:  ADD Reg, imm32   (81 /0 id form).
 *  General-purpose form (X64Emit_AddRspImm is RSP-specific). Used to advance
 *  RDI past the function slot (ADD RDI, 16) in the frame prologue/reload.
 */
int X64Emit_AddRegImm32( LcCodeBuf *Buf, X64_GPR_T Reg, int32_t Imm );

/*!
 * @brief
 *  Indirect CALL via 64-bit absolute address.  We emit:
 *      mov rax, imm64  (10 bytes)
 *      call rax        (2 bytes)
 *  Total 12 bytes. Caller is responsible for stack alignment + shadow space.
 */
int X64Emit_CallAbs( LcCodeBuf *Buf, void *Target );

/*!
 * @brief
 *  RET.   1 byte: 0xC3.
 */
int X64Emit_Ret( LcCodeBuf *Buf );

/*!
 * @brief
 *  SSE2 scalar-double emitters. XMM0..XMM7 only (high XMM regs not needed
 *  for the fast paths we emit). MemBase must be one of RAX..RDI (no REX.B
 *  needed); Disp can be any int32.
 *
 *  MOVSD xmm0, [base + disp]   F2 0F 10 /r
 *  MOVSD [base + disp], xmm0   F2 0F 11 /r
 *  ADDSD xmm0, [base + disp]   F2 0F 58 /r
 *  SUBSD xmm0, [base + disp]   F2 0F 5C /r
 *  MULSD xmm0, [base + disp]   F2 0F 59 /r
 *  DIVSD xmm0, [base + disp]   F2 0F 5E /r
 */
int X64Emit_MovsdMemToXmm0( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp );
int X64Emit_MovsdXmm0ToMem( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp );
int X64Emit_AddsdMemToXmm0( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp );
int X64Emit_SubsdMemToXmm0( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp );
int X64Emit_MulsdMemToXmm0( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp );
int X64Emit_DivsdMemToXmm0( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp );

/*!
 * @brief
 *  MOVSD xmm[X], [Base + Disp] for X in 0..7. Encoding: F2 [REX] 0F 10 ModR/M.
 *  Used for 64-bit float (double) loads.
 */
int X64Emit_MovsdMemToXmmN( LcCodeBuf *Buf, int XmmN,
                            X64_GPR_T Base, int32_t Disp );

/*!
 * @brief
 *  MOVSS xmm[X], [Base + Disp] for X in 0..7. Encoding: F3 [REX] 0F 10 ModR/M.
 *  Used for 32-bit float loads.
 */
int X64Emit_MovssMemToXmmN( LcCodeBuf *Buf, int XmmN,
                            X64_GPR_T Base, int32_t Disp );

/*!
 * @brief
 *  MOVQ r64, xmm0. Encoding: 66 REX.W 0F 7E /r -- moves the low 64 bits of
 *  xmm0 to the named GPR. Used to repack a double return from XMM0 to RAX.
 */
int X64Emit_MovqXmm0ToReg64( LcCodeBuf *Buf, X64_GPR_T Dst );

/*!
 * @brief
 *  MOVQ xmm0, r64. Encoding: 66 REX.W 0F 6E /r.
 */
int X64Emit_MovqReg64ToXmm0( LcCodeBuf *Buf, X64_GPR_T Src );

/*!
 * @brief
 *  MOVQ xmmN, r64 (N = 0..7). Encoding: 66 REX.W 0F 6E /r with ModR/M
 *  reg = XmmN. Used to materialize a compile-time double bit pattern into a
 *  scratch xmm for the float-K arith elision.
 */
int X64Emit_MovqReg64ToXmmN( LcCodeBuf *Buf, int XmmN, X64_GPR_T Src );

/*!
 * @brief
 *  ADDSD/SUBSD/MULSD/DIVSD xmm0, xmm1. Encoding: F2 0F <Op> C1 with
 *  Op = 0x58 (add), 0x5C (sub), 0x59 (mul), 0x5E (div).
 */
int X64Emit_ArithSdXmm0Xmm1( LcCodeBuf *Buf, unsigned char Op );

/*!
 * @brief
 *  UCOMISD xmm0, m64 / xmm0, xmm1 (66 0F 2E /r). Sets ZF/PF/CF;
 *  an unordered (NaN) compare sets all three -- so CF-based conditions
 *  (seta/setae) yield false-on-NaN, matching Lua comparison semantics.
 */
int X64Emit_UcomisdXmm0Mem( LcCodeBuf *Buf, X64_GPR_T Base, int32_t Disp );
int X64Emit_UcomisdXmm0Xmm1( LcCodeBuf *Buf );

/*!
 * @brief
 *  64-bit ALU op RAX, rN (register-direct). Op: 0x03 ADD, 0x2B SUB,
 *  0x23 AND, 0x0B OR, 0x33 XOR, 0x3B CMP, 0xAF IMUL (emitted as 0F AF).
 *  Used by the loop-region register-residency lowering.
 */
int X64Emit_ArithRaxReg( LcCodeBuf *Buf, unsigned char Op, X64_GPR_T Src );

/*!
 * @brief
 *  Wide-bank (xmm0..xmm15, REX.R/REX.B as needed) scalar-double and 128-bit
 *  SSE forms for the float register residency:
 *    MovsdLoadXmm / MovsdStoreXmm  -- xmmN <-> qword [Base + Disp]
 *    MovsdXmmXmm                   -- xmmDst = xmmSrc (low 64)
 *    ArithSdXmm0Xmm / ArithSdXmm0Mem -- addsd/subsd/mulsd/divsd xmm0, rhs
 *                                        (Op = 0x58/0x5C/0x59/0x5E)
 *    UcomisdXmm0Xmm                -- ucomisd xmm0, xmmN
 *    MovupsStoreXmm / MovupsLoadXmm -- full 128-bit save/restore (prologue
 *                                      xmm6..xmm10 spill area)
 */
int X64Emit_MovsdLoadXmm( LcCodeBuf *Buf, int XmmN, X64_GPR_T Base, int32_t Disp );
int X64Emit_MovsdStoreXmm( LcCodeBuf *Buf, int XmmN, X64_GPR_T Base, int32_t Disp );
int X64Emit_MovsdXmmXmm( LcCodeBuf *Buf, int Dst, int Src );
int X64Emit_ArithSdXmm0Xmm( LcCodeBuf *Buf, unsigned char Op, int Src );
int X64Emit_ArithSdXmm0Mem( LcCodeBuf *Buf, unsigned char Op,
                            X64_GPR_T Base, int32_t Disp );
int X64Emit_UcomisdXmm0Xmm( LcCodeBuf *Buf, int Src );
int X64Emit_ArithSdXmmXmm( LcCodeBuf *Buf, unsigned char Op, int Dst, int Src );
int X64Emit_ArithSdXmmMem( LcCodeBuf *Buf, unsigned char Op, int Dst,
                           X64_GPR_T Base, int32_t Disp );
int X64Emit_MovupsStoreXmm( LcCodeBuf *Buf, int XmmN, X64_GPR_T Base, int32_t Disp );
int X64Emit_MovupsLoadXmm( LcCodeBuf *Buf, int XmmN, X64_GPR_T Base, int32_t Disp );

/*!
 * @brief
 *  CALL rel32 to an external symbol. Emits E8 <disp32=0> and records an
 *  LC_RELOC_REL32 against `Sym` at the disp32 offset. The linker resolves it.
 */
int X64Emit_CallSym( LcCodeBuf *Buf, const char *Sym );

/*!
 * @brief
 *  LEA Dst, [RIP + disp32] referencing a .rdata local symbol. Emits 48 8D /r
 *  with disp32=0 and records LC_RELOC_REL32_RDATA against `Sym`.
 */
int X64Emit_LeaRipSym( LcCodeBuf *Buf, X64_GPR_T Dst, const char *Sym );

#endif /* LUAC_CODEGEN_X64_EMIT_H */
