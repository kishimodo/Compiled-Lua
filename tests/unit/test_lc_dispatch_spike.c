/* test_lc_dispatch_spike.c -- LuaC AOT dispatch-registration spike.
 *
 * GOAL
 *   Prove that an externally-supplied native function, registered into v1's
 *   existing JIT dispatch side-cache via Jit_RegisterCompiled, is invoked by
 *   the *normal Lua call path* with NO JIT compilation involved. This is the
 *   foundation of the AOT dispatch model: AOT-compiled function bodies are
 *   registered at program startup (ProtoInit) and then dispatched through the
 *   same path JIT'd bodies would use.
 *
 * ============================================================================
 * GENUINE DISPATCH-TRIGGER CONDITIONS  (consumed by later AOT-startup tasks)
 * ============================================================================
 * Investigating the real transition (src/jit/runtime.c Rt_Call ~L75-184,
 * lua-5.4/src/lvm.c luaV_execute L1185-1222) shows there are TWO ways a cached
 * entry gets invoked, and a unit test that hand-builds a closure + calls it
 * through luaD_call / luaD_callnoyield / luaV_execute hits the SECOND one:
 *
 *   1. JIT->JIT fast path (Rt_Call, runtime.c):
 *        Only fires when the CALLER is itself JIT'd code that lowered an
 *        OP_CALL to Rt_Call. It does Jit_LookupCached(callee->p) directly and,
 *        if non-NULL, builds the callee CallInfo inline and calls the entry.
 *        Not reachable from a bare unit test (no JIT'd caller frame exists).
 *
 *   2. Interpreter / luaD re-entry path (luaV_execute, lvm.c) -- THIS is what a
 *      luaD_call / luaD_callnoyield / lua_pcall / C->Lua callback funnels into:
 *        luaD_callnoyield(L, func, nres)
 *          -> luaD_precall: for a Lua closure, sets up the callee CallInfo
 *             (func/top/savedpc/nresults) and calls luaV_execute(L, ci).
 *          -> luaV_execute checks:
 *                 if (clua_dispatch_hook != NULL && L->hookmask == 0) {
 *                     jitted = clua_dispatch_hook(L, cl->p);   // <-- cache lookup
 *                     if (jitted != NULL) {
 *                         nres = clua_invoke_hook(L, jitted); // <-- runs body
 *                         luaD_poscall(L, ci, nres);
 *                         return;
 *                     }
 *                 }
 *                 luaVM_Interpret(L, ci);  // fallback: bytecode interpreter
 *
 * Therefore, for a REGISTERED entry to be invoked, ALL of these must hold:
 *   (A) clua_dispatch_hook must be set to a function that consults the
 *       cache for cl->p and returns its JIT_FUNC_T (Jit_LookupCached). If
 *       the hook is NULL, the call ALWAYS runs the bytecode interpreter --
 *       the registered entry is never consulted. (The AOT runtime sets this
 *       hook at startup in aot_entry.c.)
 *   (B) L->hookmask == 0 (no debug hook active). A debug hook forces the
 *       hook-aware bytecode interpreter; the AOT/JIT body honors no hooks.
 *   (C) The Proto* used as the cache key must be the SAME pointer stored in the
 *       callee closure's `p` field (cache is keyed by Proto*). The AOT startup
 *       must register the very Proto objects its closures reference.
 *   (D) The callee must be a Lua closure (ttisLclosure) so luaD_precall routes
 *       it through luaV_execute (C closures / callable cdata take other paths).
 *
 * The invoke hook (clua_invoke_hook) defaults to a direct Fn(L) call; the
 * real runtime overrides it with Jit_TrampolineEntry for VEH fault recovery.
 * Either works for dispatch; the body still runs.
 *
 * This test reproduces conditions (A)-(D) with the smallest possible setup:
 * a 1-opcode vararg main Proto whose registered "native body" is a C function
 * that flips a flag, then calls it via luaD_callnoyield and asserts the flag.
 * It also asserts the NEGATIVE control (hook NULL => interpreter runs, our
 * registered body does NOT) so the spike fails for the right reason if the
 * dispatch wiring ever regresses.
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
 * setclLvalue2s() macro below expands to in an assert-enabled core build. */
#include "lgc.h"

#include "jit/dispatch.h"

/* The "AOT body" stand-in: a native C function registered as P's entry. It
 * returns the number of Lua results it placed on the stack (0 here -- it is a
 * RETURN0 body), exactly like a real AOT-compiled / JIT'd body. */
static int g_BodyRan = 0;
static int SpikeBody( lua_State *L ) {
    (void)L;
    g_BodyRan = 1;
    return 0;   /* zero results, mirroring OP_RETURN0 */
}

/* Dispatch hook the runtime installs at startup: consult the cache (NO codegen)
 * and return the registered entry, or NULL. This is the (A) condition above.
 * Lookup-only: no code generation of any kind can happen -- the whole point
 * of the spike. */
static void *LookupHook( lua_State *L, void *Proto ) {
    (void)L;
    return ( void * )Jit_LookupCached( ( struct Proto * )Proto );
}

/* Build a minimal vararg main Proto with a single OP_RETURN0, register
 * SpikeBody as its entry, wrap it in a closure, push it, and return the
 * stack slot holding the closure (ready for luaD_callnoyield). */
static Proto *BuildSpikeProto( lua_State *L ) {
    Proto *P = luaF_newproto( L );
    P->numparams    = 0;
    P->is_vararg    = 1;
    P->maxstacksize = 2;
    P->sizecode     = 1;
    P->code         = luaM_newvector( L, 1, Instruction );
    /* OP_RETURN0: A B C k. The B field (here 1) encodes (nparams+1)=1 for a
     * vararg function's return; SpikeBody ignores it since it never executes
     * the opcode -- the opcode array only exists so P->sizecode == 1 and the
     * cache/PcCount bookkeeping is well-formed. */
    P->code[0]      = CREATE_ABCk( OP_RETURN0, 0, 1, 0, 0 );
    return P;
}

int main( void ) {
    TEST_BEGIN( "lc_dispatch_spike" );

    lua_State *L = luaL_newstate();
    CHECK_NOT_NULL( L );

    Proto *P = BuildSpikeProto( L );
    CHECK_NOT_NULL( P );
    CHECK_NOT_NULL( P->code );

    /* Register the external native entry into the dispatch cache. */
    CHECK_EQ_INT( Jit_RegisterCompiled( P, SpikeBody ), 1 );
    /* Idempotent: registering the same Proto again succeeds without a 2nd slot. */
    CHECK_EQ_INT( Jit_RegisterCompiled( P, SpikeBody ), 1 );
    /* The cache now hands back exactly our entry (condition (C)). */
    CHECK( Jit_LookupCached( P ) == SpikeBody );
    /* Rejects bad input. */
    CHECK_EQ_INT( Jit_RegisterCompiled( NULL, SpikeBody ), 0 );
    CHECK_EQ_INT( Jit_RegisterCompiled( P, NULL ), 0 );

    /* Build a closure over P (condition (D): a Lua closure). */
    LClosure *Cl = luaF_newLclosure( L, 0 );
    CHECK_NOT_NULL( Cl );
    Cl->p = P;

    /* -----------------------------------------------------------------------
     * NEGATIVE CONTROL: with NO compile hook installed, luaV_execute falls
     * straight through to the bytecode interpreter (luaVM_Interpret). Our
     * registered entry is NEVER consulted. We push the closure, call it, and
     * assert the body did NOT run. (The 1-op RETURN0 Proto runs cleanly under
     * the interpreter and returns no values.) This proves the spike's PASS
     * below is caused by the dispatch wiring, not by some artificial path.
     * --------------------------------------------------------------------- */
    clua_dispatch_hook = NULL;          /* condition (A) deliberately unmet */
    g_BodyRan = 0;
    luaL_checkstack( L, 4, "spike push" );
    setclLvalue2s( L, L->top.p, Cl );
    L->top.p++;
    luaD_callnoyield( L, L->top.p - 1, 0 );
    CHECK_EQ_INT( g_BodyRan, 0 );           /* interpreter ran, NOT our entry */
    lua_settop( L, 0 );

    /* -----------------------------------------------------------------------
     * POSITIVE PATH: install the cache-consulting hook (condition (A)); the
     * normal call path now routes through luaV_execute -> hook -> registered
     * entry, with NO JIT compilation. Assert the native body ran.
     * --------------------------------------------------------------------- */
    clua_dispatch_hook = LookupHook;    /* hookmask is already 0 -> (B) holds */
    g_BodyRan = 0;
    luaL_checkstack( L, 4, "spike push" );
    setclLvalue2s( L, L->top.p, Cl );
    L->top.p++;
    luaD_callnoyield( L, L->top.p - 1, 0 );
    CHECK_EQ_INT( g_BodyRan, 1 );           /* the registered AOT body ran */
    lua_settop( L, 0 );

    clua_dispatch_hook = NULL;          /* leave global state clean */
    lua_close( L );
    TEST_END();
}
