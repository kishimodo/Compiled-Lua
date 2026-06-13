/*!
 * @brief
 *  Native-body dispatch cache: maps a Proto* to its pre-registered AOT
 *  entry point. Process-wide, never evicted. (Historically this was the
 *  v1 JIT's compile-and-cache entry; the JIT compiler has been removed —
 *  bodies are only ever registered, never generated at run time.)
 */

#ifndef CLUA_JIT_DISPATCH_H
#define CLUA_JIT_DISPATCH_H

#include "lua.h"
#include "lobject.h"

typedef int ( *JIT_FUNC_T )( lua_State *L );

/* Register an externally-generated native entry for Proto P in the dispatch
 * cache. Used by AOT startup (ProtoInit) so the Rt_Call -> Jit_LookupCached
 * path invokes the AOT body. Returns 1 on success, 0 if the cache is full.
 * Idempotent per Proto. */
int Jit_RegisterCompiled( Proto *P, JIT_FUNC_T Entry );

/*!
 * @brief
 *  Look up the cached entry for P (returns NULL if not registered).
 */
JIT_FUNC_T Jit_LookupCached( Proto *P );

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

#endif /* CLUA_JIT_DISPATCH_H */
