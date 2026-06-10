/*!
 * @brief
 *  Per-function register allocator. Statically assigns up to 5 Lua
 *  registers to callee-saved x64 GPRs based on use count.
 */

#ifndef LUAVM_JIT_REGALLOC_H
#define LUAVM_JIT_REGALLOC_H

#include "jit/emit_x64.h"

#include "lua.h"
#include "lobject.h"

/* Maximum number of Lua registers in a single Proto. Lua's MAXSTACK is
   typically 255; this matches. */
#define REGALLOC_MAX_LUA_REGS 256

/* Number of cache slots. Five callee-saved x64 GPRs that we don't already
   use for L (RBX) or the register base (RDI). */
#define REGALLOC_NUM_CACHE_REGS 5

/*!
 * @brief
 *  Per-Lua-register assignment. CacheReg == X64_RAX (an invalid choice;
 *  rax is volatile) means "not cached, lives in memory only".
 */
typedef struct _REGALLOC_T {
    /* For each Lua reg i, the x64 reg that mirrors it (or X64_RAX = "none"). */
    X64_GPR_T   CacheReg[ REGALLOC_MAX_LUA_REGS ];
    /* Reverse map: for each cache slot 0..4, the Lua reg it mirrors
       (or -1 for "this slot is unused"). */
    int         CacheSlotLuaReg[ REGALLOC_NUM_CACHE_REGS ];
    /* The 5 cache x64 regs in slot order — fixed: R12, R13, R14, R15, RSI. */
    X64_GPR_T   CachePool[ REGALLOC_NUM_CACHE_REGS ];
    /* Number of Lua regs we actually cached (0..5). */
    int         NumCached;
} REGALLOC_T, *PREGALLOC_T;

/*!
 * @brief
 *  Analyse P's bytecode (use counts per Lua register) and assign cache
 *  slots. Initialises CacheReg, CacheSlotLuaReg, NumCached.
 *
 * @return
 *  1 on success, 0 on internal error (e.g. maxstacksize > MAX_LUA_REGS).
 */
int RegAlloc_Analyse( PREGALLOC_T R, Proto *P );

/*!
 * @brief
 *  Returns 1 if Lua register LuaReg has an assigned x64 cache reg.
 *  When true, *OutXReg is set to the cache reg.
 */
int RegAlloc_IsCached( PREGALLOC_T R, int LuaReg, X64_GPR_T *OutXReg );

#endif /* LUAVM_JIT_REGALLOC_H */
