/*!
 * @brief
 *  JIT entry point: compile a Proto* into x64 machine code (or return NULL
 *  if the Proto contains opcodes we don't yet handle).
 *  Caches results per Proto*; the cache is process-wide for v1 and never
 *  evicted (deferred to GC integration in Plan 2f).
 */

#ifndef LUAVM_JIT_DISPATCH_H
#define LUAVM_JIT_DISPATCH_H

#include "lua.h"
#include "lobject.h"

typedef int ( *JIT_FUNC_T )( lua_State *L );

/*!
 * @brief
 *  Return a callable function pointer for P, or NULL if any opcode in P's
 *  bytecode array is unsupported by the current JIT.
 *  Cached after first call.
 */
JIT_FUNC_T Jit_Compile( lua_State *L, Proto *P );

/* Register an externally-generated native entry for Proto P in the dispatch
 * cache, exactly as Jit_Compile would after codegen. Used by AOT startup
 * (ProtoInit) so the existing Rt_Call -> Jit_LookupCached path invokes the
 * AOT body with no JIT present. Returns 1 on success, 0 if the cache is full
 * or P is already registered. */
int Jit_RegisterCompiled( Proto *P, JIT_FUNC_T Entry );

/*!
 * @brief
 *  Look up the cached entry for P without compiling (returns NULL if not
 *  yet seen or unsupported).
 */
JIT_FUNC_T Jit_LookupCached( Proto *P );

/*!
 * @brief
 *  Set of opcodes the current JIT can compile. Exposed for tests/diagnostics.
 *  Returns 1 if Opcode is in the supported set.
 */
int Jit_IsOpcodeSupported( int Opcode );

/* Forward declaration to avoid pulling veh.h into dispatch.h. */
typedef struct _JIT_FRAME_T JIT_FRAME_T, *PJIT_FRAME_T;

/*!
 * @brief
 *  Wrap a JIT body call in a setjmp boundary so VEH-recovered faults
 *  longjmp here, reset L->top, and raise a Lua error.
 *
 *  Returns the number of Lua results placed on the stack by Fn, or
 *  does not return (raises a Lua error) on fault recovery.
 */
int Jit_TrampolineEntry( lua_State *L, int ( *Fn )( lua_State * ) );

/*!
 * @brief
 *  Map a faulting RIP inside a JIT region back to the Lua source line that
 *  produced it. On success returns 1 and fills *OutSource (interned string,
 *  do not free) and *OutLine. On failure (RIP not in any cached region or
 *  no debug info) returns 0 and leaves outputs untouched.
 */
int Jit_LookupSourceLine( void *Rip, const char **OutSource, int *OutLine );

/*!
 * @brief
 *  For tests: look up the byte address inside the cached JIT slab that
 *  corresponds to opcode index Pc in Proto P. Returns NULL if P is not
 *  cached, Pc is out of range, or that Pc was not emitted.
 */
void *Jit_DebugGetPcAddress( Proto *P, int Pc );

#endif /* LUAVM_JIT_DISPATCH_H */
