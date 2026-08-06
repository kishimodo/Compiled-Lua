/*
** emit.h -- diagnostic dump modes for the CLua driver.
**
** Three flavours, all triggered by `--emit=<what>` on the driver CLI. Each
** writes a text listing to the given FILE*: the driver opens the -o path (or
** hands over stdout when the path is NULL or "-") and calls one of the three
** entry points below at the matching phase.
**
**   Lc_DumpBytecode -- after undump, before lift. One block per Proto,
**                      pc-indexed listing of the raw Lua 5.4 bytecode plus
**                      any RK constants inline (modeled on `luac -l`).
**   Lc_DumpIr       -- after the optimizer, before codegen. One block per
**                      LcFunc, one instruction per line with the IR opcode
**                      name and any known LcType info on the result.
**   Lc_DumpAsm      -- after codegen, before link. Per compiled function:
**                      offset, raw bytes, decoded mnemonic. Bytes that fall
**                      outside the ~30 opcodes CLua actually emits print
**                      as raw hex followed by `; ???`.
**
** These entry points never allocate the FILE* and never close it. Callers
** own it end to end -- lc_drive keeps the semantics of the -o path (fopen,
** dump, fclose) in one place next to the rest of the pipeline.
*/
#ifndef LUAC_DUMP_EMIT_H
#define LUAC_DUMP_EMIT_H

#include <stddef.h>
#include <stdio.h>

/* Opaque forward declarations. Including the full IR / codegen / lobject
** headers here would drag them into every translation unit that pulls in
** aotc.h; the .c files that implement these functions include what they
** need directly. */
struct Proto;
struct LcModule;
struct LcCodeModule;

/* Dump the raw Lua 5.4 bytecode reachable from `root` (root + its nested
** protos, depth-first, entry first). Format follows `luac -l`: a header
** line per function then one indented instruction per pc with the opcode
** name and its A/B/C operands. Constants referenced through Bx/RK slots
** are printed inline after a `; ` comment. */
int Lc_DumpBytecode( FILE *out, struct Proto *root );

/* Dump the optimized LcModule, one LcFunc per section. Instruction lines
** carry the IR opcode name (`LC_OP_...`), the originating bytecode pc/op
** for context, the SSA result's type (from LcType) when known, and the
** A/B/C operand triple lift.c decodes into each LcInst. */
int Lc_DumpIr( FILE *out, const struct LcModule *m );

/* Dump the emitted x64 machine code for each compiled function. Uses the
** minimal opcode table CLua's codegen actually reaches; anything outside
** the table is printed as raw hex followed by `; ???` so the output stays
** faithful without hiding bytes the disassembler cannot name. */
int Lc_DumpAsm( FILE *out, const struct LcCodeModule *cm );

#endif /* LUAC_DUMP_EMIT_H */
