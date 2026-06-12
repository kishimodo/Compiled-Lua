/*!
 * @brief
 *  Fiber-based Lua coroutines. Each coroutine runs on its own Windows fiber
 *  with its own lua_State (a sibling thread of the parent's lua_State,
 *  sharing the global state). yield/resume become SwitchToFiber, which
 *  preserves the native stack across context switches -- so JIT-compiled
 *  code that calls coroutine.yield works transparently.
 *
 *  Standard Lua's coroutine library uses setjmp/longjmp inside the
 *  interpreter loop. We don't have that loop -- our JIT replaces
 *  luaV_execute -- so we replace the coroutine library wholesale.
 *
 *  Multi-threading: each OS thread has its own "current coroutine" pointer
 *  via FlsAlloc/FlsGetValue. Coroutines created on thread A can only be
 *  resumed from thread A (matches Lua's reference semantics; cross-thread
 *  resume would corrupt the fiber chain).
 *
 *  Stack size: coroutine.create(fn) uses the default fiber stack (Windows
 *  default 1 MiB). coroutine.create(fn, { stack = N }) overrides.
 *
 *  Nested coroutines work naturally: each resume pushes the previous
 *  current coroutine to "normal" state and switches to the new one's
 *  fiber. yield switches back to the IMMEDIATE caller fiber (which may
 *  itself be a coroutine, in which case its status flips back to running).
 *
 *  API parity with Lua 5.4's coroutine library:
 *    coroutine.create(fn [, opts])
 *    coroutine.resume(co, ...)
 *    coroutine.yield(...)
 *    coroutine.status(co)
 *    coroutine.running()      -> coroutine, isMain
 *    coroutine.wrap(fn)
 *    coroutine.isyieldable([co])
 *    coroutine.close(co)
 */

#ifndef LUAVM_RUNTIME_CORO_H
#define LUAVM_RUNTIME_CORO_H

#include "lua.h"

/*!
 * @brief
 *  Install the fiber-based coroutine library, replacing the stock one that
 *  luaL_openlibs registered. Must be called after luaL_openlibs.
 */
void Coro_OpenLib( lua_State *L );

/*!
 * @brief
 *  Process-wide one-time init. Allocates the FLS slot used to track
 *  "current coroutine" per-thread. Safe to call multiple times.
 */
void Coro_InitProcess( void );

/*!
 * @brief
 *  Convert the calling OS thread to a fiber if it isn't one already.
 *  Idempotent. Each OS thread that uses coroutines must call this.
 */
void Coro_InitThreadAsFiber( void );

#endif /* LUAVM_RUNTIME_CORO_H */
