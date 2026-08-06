/*
** lc_cache.h -- per-function persistent compilation cache.
**
** Rationale: codegen for a single function is deterministic in its inputs
** (LcInst stream + source Proto + LcCgCtx + compiler version). On a rebuild,
** functions whose inputs are byte-identical to a previous build can skip the
** emitter entirely and load their machine code + relocation table from disk.
**
** Cache directory: %LOCALAPPDATA%\clua\cache (or $XDG_CACHE_HOME/clua when
** LOCALAPPDATA is absent). Overridable via LcCgCtx.cache_dir (--cache-dir=<p>).
**
** Cache key: a 128-bit FNV-1a hash over
**   - CLUA_VERSION_STRING (a compiler upgrade invalidates every entry)
**   - target triple string ("x86_64-pc-windows-msvc")
**   - LcCgCtx serialization (opt_level -- the only field today that affects
**     emitted bytes; any future field added here must be included)
**   - the function's ordinal `i` within the module (the emitted `luac_fn_%u`
**     symbol name and inter-function REL32 relocs both bake this in, so a
**     function that moves slots must NOT alias an older cache entry)
**   - the function's own module_name (a required module's main chunk is
**     tagged with its require-name -- affects nothing in the bytes today,
**     but included for forward safety)
**   - the LcFunc's IR: op/sub/flags/nargs/bc_pc/bc_op/a/b/c/ret_close/known/
**     res_entry_int/res_entry_flt/call_ret_ti/call_callee for every LcInst,
**     plus the args' SSA ids
**   - the source Proto's raw bytecode, constant pool (tag + payload), and
**     numparams/maxstacksize/is_vararg/sizeupvalues
**
** Correctness invariant: byte-identity of the emitted PE MUST hold whether a
** function was compiled fresh or restored from cache. That is why the key
** includes the compiler version (upgrade invalidates), opt_level (affects
** which fastpaths are emitted), and every field of LcInst/Proto that codegen
** reads. If a future codegen change starts reading a field not listed above,
** it MUST be added to the hash inputs -- otherwise a stale cache entry will
** miscompile silently.
**
** Format of a cache entry file <hex>.co:
**   magic       "CLCO"                 4 bytes
**   version     1                      4 bytes LE
**   code_len                           4 bytes LE
**   code                              code_len bytes
**   nrelocs                            4 bytes LE
**   relocs      nrelocs * (kind:4 offset:4 addend:4 sym_len:4 sym_bytes)
**   unwind_len                         4 bytes LE
**   unwind                            unwind_len bytes
**
** The reloc serialization is length-prefixed (not a raw struct dump) because
** LcReloc contains a fixed 64-byte symbol buffer whose padding bytes are not
** required to match across runs; length-prefixing the actual name string
** removes that source of nondeterminism.
*/
#ifndef LUAC_CODEGEN_LC_CACHE_H
#define LUAC_CODEGEN_LC_CACHE_H

#include <stddef.h>
#include <stdint.h>

#include "codegen.h"

/* 128-bit hash rendered as 32 hex chars + NUL. */
#define LC_CACHE_KEY_HEXLEN 33

/* Cache size cap: 100 MB. When write is enabled and the cache dir exceeds
   this after a successful build, the oldest files by mtime are deleted until
   the directory fits. Runs once at the tail of lc_codegen. */
#define LC_CACHE_MAX_BYTES ( 100u * 1024u * 1024u )

/* Resolve the cache directory. Precedence:
     1. explicit override (`--cache-dir=<path>`); passed as `override_dir`
     2. $XDG_CACHE_HOME/clua                   (POSIX-style Windows setups)
     3. %LOCALAPPDATA%\clua\cache              (the default on Windows)
   Auto-creates the directory (best-effort). Returns 1 on success + writes
   OutSize-safe path into OutBuf; returns 0 when no location can be derived
   (in which case caching is silently disabled). */
int LcCache_ResolveDir( const char *override_dir, char *OutBuf, size_t OutSize );

/* Compute the cache key for a single function. Deterministic in inputs, no
   RNG or timing sources. Writes 32 hex chars + NUL to KeyOut (>= 33 bytes).
   Returns 1 on success, 0 on failure (KeyOut is left undefined). */
struct LcModule;
int LcCache_ComputeKey( const struct LcModule *m, uint32_t i,
                        const LcCgCtx *cg, char *KeyOut );

/* Look up a cached compiled function. On hit, populates cf with heap-owned
   code/relocs/unwind buffers (caller frees via lc_codemodule_free) and sets
   cf->name to "luac_fn_<i>". Returns 1 on hit, 0 on miss or any error. */
int LcCache_TryLoad( const char *dir, const char *key, uint32_t i,
                     LcCompiledFunc *cf );

/* Write a compiled function to the cache. Returns 1 on success, 0 on any
   error (a failing write is non-fatal to the build -- callers should ignore
   the return value except for diagnostics). Uses a stage+rename pattern so a
   concurrent build of the same key does not observe a torn file. */
int LcCache_Store( const char *dir, const char *key,
                   const LcCompiledFunc *cf );

/* Enforce the 100 MB soft cap on the cache directory. Deletes oldest files
   (by mtime) until the total drops below LC_CACHE_MAX_BYTES. Best-effort;
   errors are silently ignored. Called at the end of a successful codegen
   run when write is enabled. */
void LcCache_Evict( const char *dir );

#endif /* LUAC_CODEGEN_LC_CACHE_H */
