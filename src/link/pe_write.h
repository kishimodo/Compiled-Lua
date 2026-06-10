/*
** pe_write.h — Standard Windows x64 PE writer for LuaC.
**
** This REPLACES v1's blob-embedding linker (src/compiler/pe_link.c, which appends
** a bytecode blob the in-binary loader later parses). LuaC emits an ORDINARY PE:
** native code in .text, no blob, no overlay, no loader stub. The result is a
** GCC-style compiled binary whose only companion is the statically-linked runtime
** library (the Lua-equivalent of libc).
**
** Sections emitted (see ../../PROMPT.md §PE emission):
**   .text   — generated machine code (LcCodeModule) + the runtime library code
**   .rdata  — constant pool, vtables/intrinsic tables, import-name strings
**   .data   — initialized mutable globals (the global Lua state seed)
**   .bss    — zero-initialized globals
**   .pdata  — RUNTIME_FUNCTION entries (one per function with a frame)
**   .xdata  — UNWIND_INFO blobs referenced by .pdata (SEH unwind)
**   .idata  — import directory (kernel32 etc.; FFI loads its own libs at runtime)
**   .reloc  — base relocations (unless we commit to a fixed image base + /FIXED)
**
** Two link strategies (PROMPT.md weighs them):
**   A) Self-contained: write the object + runtime .o set and run our own tiny
**      linker to a final PE (no external toolchain — matches "fresh backend").
**   B) Delegate: emit a COFF object for each function and invoke the MinGW ld
**      already in the project toolchain to link against the prebuilt runtime lib.
**   The skeleton targets (A) but keeps the COFF emitter so (B) is a drop-in.
*/
#ifndef LUAC_PE_WRITE_H
#define LUAC_PE_WRITE_H

#include "../codegen/codegen.h"

typedef enum { LC_OUT_EXE, LC_OUT_DLL } LcOutputKind;

typedef struct LcLinkOptions {
  LcOutputKind kind;
  const char  *out_path;
  uint64_t     image_base;   /* default 0x140000000; 0 => emit .reloc        */
  bool         emit_reloc;   /* ASLR-friendly relocatable image              */
  bool         emit_debug;   /* CodeView .pdb / DWARF (optional, later)       */
  const char  *runtime_lib;  /* path to the prebuilt runtime static lib/objs */
} LcLinkOptions;

/* Resolve relocations, lay out sections, and write the final PE to disk.
** Binds LC_RELOC_HELPER targets against the runtime library symbol table. */
bool lc_write_pe(const LcCodeModule *cm, const LcLinkOptions *opt,
                 char *err, size_t errlen);

/* Strategy B helper: emit one function as a COFF object (for external ld). */
bool lc_emit_coff(const LcCompiledFunc *f, const char *out_obj);

#endif /* LUAC_PE_WRITE_H */
