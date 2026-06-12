/* test_lc_callinfo_spike.c -- LuaC AOT native-entry frame-ABI spike.
 *
 * GOAL
 *   Prove that a native function body, invoked through the *real* dispatch hook
 *   path (the same path Task 1's test_lc_dispatch_spike.c established), correctly
 *   (a) reads its first incoming argument from the calling frame and (b) returns
 *   a result -- doing so by touching the frame *directly* (StkId / TValue), NOT
 *   the Lua C API, exactly as the codegen prologue/epilogue will. This validates
 *   the calling-frame contract the AOT codegen prologue assumes, so later codegen
 *   tasks can rely on it.
 *
 * ============================================================================
 * FRAME CONTRACT  (consumed by codegen tasks 10 & 11 and the AOT entry, task 14)
 * ============================================================================
 * A native AOT body has signature `int luac_fn(lua_State *L)` and is reached via
 * luaV_execute's compile-hook (see test_lc_dispatch_spike.c for the four trigger
 * conditions). When the body runs, luaD_precall has ALREADY set up the callee's
 * CallInfo, so the body sees a normal, fully-formed Lua frame:
 *
 *   - L              : the lua_State. In codegen terms this is pinned in RBX.
 *                      (L->ci is the current/callee CallInfo.)
 *   - base           : the Lua register base = ci->func.p + 1  (one TValue past
 *                      the function slot). `ci->func` is a StkIdRel union here
 *                      (lstate.h:178); the live pointer is the `.p` member, so
 *                      base == ci->func.p + 1. In codegen terms the prologue
 *                      loads this into RDI (EmitPrologue, v1 the removed v1 JIT codegen:136
 *                      computes RDI = ci->func.p + 16 bytes == ci->func.p + 1
 *                      TValue, since sizeof(StackValue)==sizeof(TValue)==16).
 *   - register N     : lives at base + N (a StkId/StackValue*). Use s2v(base+N)
 *                      to get its TValue*. The value field is at byte +0 and the
 *                      type tag byte at +8 -- i.e. `[RDI + N*16]` (+0 value,
 *                      +8 tag) in codegen terms. Incoming arguments occupy the
 *                      low registers: arg 1 == register 0 == s2v(base + 0).
 *   - return         : the body returns an `int` == the number of results it
 *                      produced, having placed result k at register k (starting
 *                      at base + 0) and set L->top.p = base + nresults. The
 *                      standard luaD_poscall (run after the hook returns in
 *                      luaV_execute) then moves the results down into place.
 *
 * This test exercises exactly that contract: a 1-param non-vararg body reads
 * arg0 as an integer from s2v(ci->func.p + 1), writes (arg0 + 41) back into
 * register 0, sets L->top.p to one result, and returns 1. Two calls with
 * different args (1 -> 42, 100 -> 141) confirm it reads the *real* argument from
 * the frame rather than a baked-in constant.
 *
 * The Proto carries a single OP_RETURN1 as a safety net: if dispatch ever
 * regressed and the bytecode interpreter ran instead of the native body, the
 * opcode array is still well-formed (returns register 0) -- but the +41 offset
 * would be absent, so the CHECKs would catch the regression loudly.
 */
#include "test_harness.h"

#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lobject.h"
#include "lopcodes.h"
#include "lfunc.h"
#include "ldo.h"
#include "lvm.h"
/* lgc.h declares isdead(), referenced by lobject.h's checkliveness() which the
 * setclLvalue2s() macro expands to in an assert-enabled core build. */
#include "lgc.h"

#include "jit/dispatch.h"

/* The native "AOT body" stand-in. It mirrors what codegen emits: it reaches the
 * Lua register file through the *frame* (ci->func.p + 1), not the Lua C API.
 *   - reads register 0 (the first argument) as an integer,
 *   - writes (arg0 + 41) back into register 0,
 *   - sets L->top to one result,
 *   - returns the result count (1). */
static int Body( lua_State *L ) {
    CallInfo   *ci   = L->ci;
    StkId       base = ci->func.p + 1;          /* register 0 == first arg */
    lua_Integer a    = ivalue( s2v( base ) );   /* read arg0 as integer    */
    setivalue( s2v( base ), a + 41 );           /* R0 = a + 41             */
    L->top.p = base + 1;                        /* one result at R0        */
    return 1;                                   /* result count            */
}

/* Dispatch hook the runtime installs at startup: consult the cache (NO codegen)
 * for cl->p and return the registered entry, or NULL.
 * This is condition (A) from the Task 1 dispatch spike: lookup-only, no
 * code generation of any kind. */
static void *LookupHook( lua_State *L, void *Proto ) {
    (void)L;
    return ( void * )Jit_LookupCached( ( struct Proto * )Proto );
}

/* Build a minimal 1-param, NON-vararg Proto with a single OP_RETURN1 (return
 * register 0) as a safety net, and maxstacksize >= 2 (1 arg slot + headroom). */
static Proto *BuildProto( lua_State *L ) {
    Proto *P = luaF_newproto( L );
    P->numparams    = 1;
    P->is_vararg    = 0;
    P->maxstacksize = 2;
    P->sizecode     = 1;
    P->code         = luaM_newvector( L, 1, Instruction );
    /* OP_RETURN1 A: return R[A]. A=0 -> return register 0 (where the native body
     * also leaves its result). Only a fallback; the native body runs instead. */
    P->code[0]      = CREATE_ABCk( OP_RETURN1, 0, 0, 0, 0 );
    return P;
}

int main( void ) {
    TEST_BEGIN( "lc_callinfo_spike" );

    lua_State *L = luaL_newstate();
    CHECK_NOT_NULL( L );

    Proto *P = BuildProto( L );
    CHECK_NOT_NULL( P );
    CHECK_NOT_NULL( P->code );

    /* Register the native body as P's dispatch entry (condition (C)). */
    CHECK_EQ_INT( Jit_RegisterCompiled( P, Body ), 1 );
    CHECK( Jit_LookupCached( P ) == Body );

    /* Wrap P in a Lua closure (condition (D)). */
    LClosure *Cl = luaF_newLclosure( L, 0 );
    CHECK_NOT_NULL( Cl );
    Cl->p = P;

    /* Install the cache-consulting hook (condition (A)); hookmask is already 0
     * for a fresh state (condition (B)). Now a normal lua_call routes through
     * luaD_precall -> luaV_execute -> hook -> our native Body, with no JIT. */
    clua_dispatch_hook = LookupHook;

    /* --- Call 1: arg 1 -> expect 1 + 41 == 42 --------------------------------
     * Push the closure, then push integer 1 as its single argument, then call
     * with 1 arg / 1 result. */
    luaL_checkstack( L, 4, "spike push" );
    setclLvalue2s( L, L->top.p, Cl );
    L->top.p++;
    lua_pushinteger( L, 1 );
    lua_call( L, 1, 1 );                         /* 1 arg, 1 result */
    CHECK( lua_isinteger( L, -1 ) );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 42 );  /* body read arg0 from frame  */
    lua_settop( L, 0 );

    /* --- Call 2: arg 100 -> expect 100 + 41 == 141 ---------------------------
     * A different argument proves the body reads the REAL arg from the frame,
     * not a baked-in constant. */
    luaL_checkstack( L, 4, "spike push" );
    setclLvalue2s( L, L->top.p, Cl );
    L->top.p++;
    lua_pushinteger( L, 100 );
    lua_call( L, 1, 1 );
    CHECK( lua_isinteger( L, -1 ) );
    CHECK_EQ_INT( lua_tointeger( L, -1 ), 141 );
    lua_settop( L, 0 );

    clua_dispatch_hook = NULL;              /* leave global state clean */
    lua_close( L );
    TEST_END();
}
