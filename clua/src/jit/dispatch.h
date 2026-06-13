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

/* As Jit_RegisterCompiled, but also records the function-id (the protoblob
 * record index, stable across lua_States) so a worker thread can resolve a
 * function shipped to it by id. ProtoInit uses this; FuncId < 0 means unknown
 * (the plain Jit_RegisterCompiled path). */
int Jit_RegisterCompiledId( Proto *P, JIT_FUNC_T Entry, int FuncId );

/*!
 * @brief
 *  Look up the cached entry for P (returns NULL if not registered).
 */
JIT_FUNC_T Jit_LookupCached( Proto *P );

/* function-id <-> Proto, within the CURRENT thread's cache (the global cache on
 * the main thread, the worker's own cache on a worker thread). Jit_ProtoFuncId
 * returns -1 if P is not registered; Jit_ResolveFuncId returns NULL if no entry
 * carries that id. The id is the protoblob index, identical across states. */
int    Jit_ProtoFuncId( Proto *P );
Proto *Jit_ResolveFuncId( int FuncId );

/* Per-thread dispatch-cache isolation for native OS-thread workers.
 *
 * The cache is process-global by default (one shared table, populated once by
 * the main thread at startup). A worker OS thread builds its OWN Proto set in
 * its OWN lua_State, so it installs a private thread-local cache for the span of
 * its life: Jit_WorkerCacheBegin() at bootstrap, Jit_WorkerCacheEnd() before it
 * exits. While a worker cache is installed, register/lookup on that thread hit
 * it instead of the global table -- no locks (each thread touches only its own
 * cache), no overflow (freed on worker exit), and ZERO cost on the main thread
 * until the first worker ever spawns.
 *
 * Jit_InitWorkerTls() allocates the TLS slot; call it once on the main thread at
 * startup before any worker can spawn. */
void  Jit_InitWorkerTls( void );
void *Jit_WorkerCacheBegin( void );   /* returns the cache, or NULL on failure */
void  Jit_WorkerCacheEnd( void );

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
