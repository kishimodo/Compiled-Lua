/*!
 * @brief
 *  Primitive x64 instruction encoder. Each emitter appends bytes to an
 *  EXEC_MEM_SLOT_T's writable region. The encoder is "just enough" for
 *  Plan 2a's opcode set; later sub-plans extend it.
 */

#ifndef LUAVM_JIT_EMIT_X64_H
#define LUAVM_JIT_EMIT_X64_H

#include <stddef.h>
#include <stdint.h>

#include "jit/exec_mem.h"

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
int EmitX64_MovImm64ToReg( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Dst, uint64_t Imm );

/*!
 * @brief
 *  REX.W = 1 MOV r64, r/m64 with 8-bit or 32-bit displacement.
 *  Encodes:  MOV Dst, [Base + Disp]
 */
int EmitX64_MovMemToReg( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Dst,
                         X64_GPR_T Base, int32_t Disp );

/*!
 * @brief
 *  REX.W = 1 MOV r/m64, r64.   Encodes:  MOV [Base + Disp], Src
 */
int EmitX64_MovRegToMem( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp,
                         X64_GPR_T Src );

/*!
 * @brief
 *  REX.W = 1 MOV r64, r64.    Encodes:  MOV Dst, Src
 */
int EmitX64_MovRegToReg( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Dst, X64_GPR_T Src );

/*!
 * @brief
 *  MOV r/m32, imm32.   Encodes:  MOV [Base + Disp], imm32  (32-bit store).
 *  Used to write the TValue tag word (32 bits).
 */
int EmitX64_MovImm32ToMem( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp,
                           int32_t Imm );

/*!
 * @brief
 *  CMP r/m32, imm32   (zero-extended/sign-extended depending on imm size).
 *  Encodes:  CMP [Base + Disp], imm32
 */
int EmitX64_CmpMem32Imm32( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp,
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
int EmitX64_CmpMem8Imm8( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp,
                         int8_t Imm );

/*!
 * @brief
 *  REX.W = 1 ADD r64, r/m64.   Encodes:  ADD Dst, [Base + Disp]
 */
int EmitX64_AddMemToReg( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Dst,
                         X64_GPR_T Base, int32_t Disp );

/*!
 * @brief
 *  JNE rel8.  4-byte conditional skip-forward by N bytes.
 *  (We hand-compute the forward jump distance when emitting fast paths.)
 */
int EmitX64_JneRel8( PEXEC_MEM_SLOT_T Slot, int8_t Rel );

/*!
 * @brief
 *  JMP rel8.
 */
int EmitX64_JmpRel8( PEXEC_MEM_SLOT_T Slot, int8_t Rel );

/*!
 * @brief
 *  Emit JMP rel8 with placeholder displacement (0). Returns the offset of
 *  the displacement byte (inside Slot->Code) so the caller can patch it
 *  later once the target's position is known. Returns SIZE_MAX on failure.
 */
size_t EmitX64_JmpRel8_Placeholder( PEXEC_MEM_SLOT_T Slot );

/*!
 * @brief
 *  Patch a rel8 displacement byte (previously written by a Placeholder emit
 *  or any other rel8 instruction). `PatchOffset` is the position of the
 *  displacement byte; `TargetOffset` is where execution should land.
 *  Returns 1 on success, 0 if the offset doesn't fit in int8.
 */
int EmitX64_PatchRel8( PEXEC_MEM_SLOT_T Slot, size_t PatchOffset, size_t TargetOffset );

/*!
 * @brief
 *  Emit JMP rel32 (E9 disp32) with placeholder displacement (0). Returns
 *  the offset of the first byte of the disp32 word (4 bytes wide) so a
 *  caller can patch it via EmitX64_PatchRel32. Returns SIZE_MAX on failure.
 */
size_t EmitX64_JmpRel32_Placeholder( PEXEC_MEM_SLOT_T Slot );

/*!
 * @brief
 *  Emit Jcc rel32 with placeholder. `Cc` is the 4-bit condition code that
 *  goes into the opcode's low nibble (e.g. 0x4 = JE, 0x5 = JNE, 0xC = JL,
 *  0xD = JGE, 0xE = JLE, 0xF = JG — see Intel SDM Vol. 2A Appendix B).
 *  Encoded as 0F 8x disp32 (6 bytes). Returns disp32 byte offset.
 */
size_t EmitX64_JccRel32_Placeholder( PEXEC_MEM_SLOT_T Slot, unsigned Cc );

/*!
 * @brief
 *  Patch a 32-bit displacement at PatchOffset to point at TargetOffset.
 *  Same semantics as PatchRel8 but with int32 range.
 */
int EmitX64_PatchRel32( PEXEC_MEM_SLOT_T Slot, size_t PatchOffset, size_t TargetOffset );

/*!
 * @brief
 *  PUSH r64, POP r64.
 */
int EmitX64_PushReg( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Reg );
int EmitX64_PopReg ( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Reg );

/*!
 * @brief
 *  SUB r/m64, imm32. Used for stack-reserve.
 */
int EmitX64_SubRspImm( PEXEC_MEM_SLOT_T Slot, int32_t Imm );

/*!
 * @brief
 *  ADD r/m64, imm32. Used to release stack reserve.
 */
int EmitX64_AddRspImm( PEXEC_MEM_SLOT_T Slot, int32_t Imm );

/*!
 * @brief
 *  Indirect CALL via 64-bit absolute address.  We emit:
 *      mov rax, imm64  (10 bytes)
 *      call rax        (2 bytes)
 *  Total 12 bytes. Caller is responsible for stack alignment + shadow space.
 */
int EmitX64_CallAbs( PEXEC_MEM_SLOT_T Slot, void *Target );

/*!
 * @brief
 *  RET.   1 byte: 0xC3.
 */
int EmitX64_Ret( PEXEC_MEM_SLOT_T Slot );

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
int EmitX64_MovsdMemToXmm0( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp );
int EmitX64_MovsdXmm0ToMem( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp );
int EmitX64_AddsdMemToXmm0( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp );
int EmitX64_SubsdMemToXmm0( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp );
int EmitX64_MulsdMemToXmm0( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp );
int EmitX64_DivsdMemToXmm0( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Base, int32_t Disp );

/*!
 * @brief
 *  MOVSD xmm[X], [Base + Disp] for X in 0..7. Encoding: F2 [REX] 0F 10 ModR/M.
 *  Used for 64-bit float (double) loads.
 */
int EmitX64_MovsdMemToXmmN( PEXEC_MEM_SLOT_T Slot, int XmmN,
                            X64_GPR_T Base, int32_t Disp );

/*!
 * @brief
 *  MOVSS xmm[X], [Base + Disp] for X in 0..7. Encoding: F3 [REX] 0F 10 ModR/M.
 *  Used for 32-bit float loads.
 */
int EmitX64_MovssMemToXmmN( PEXEC_MEM_SLOT_T Slot, int XmmN,
                            X64_GPR_T Base, int32_t Disp );

/*!
 * @brief
 *  MOVQ r64, xmm0. Encoding: 66 REX.W 0F 7E /r -- moves the low 64 bits of
 *  xmm0 to the named GPR. Used to repack a double return from XMM0 to RAX.
 */
int EmitX64_MovqXmm0ToReg64( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Dst );

/*!
 * @brief
 *  MOVQ xmm0, r64. Encoding: 66 REX.W 0F 6E /r.
 */
int EmitX64_MovqReg64ToXmm0( PEXEC_MEM_SLOT_T Slot, X64_GPR_T Src );

#endif /* LUAVM_JIT_EMIT_X64_H */
