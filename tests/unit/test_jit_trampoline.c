/* test_jit_trampoline.c -- the JIT trampoline / W^X pool.
 *
 * Verifies:
 *  1. Jit_TrampolineEntry with a normal-returning body propagates the return.
 *  2. g_CurrentJitFrame is NULL after a normal return.
 *  3. Manual setjmp/longjmp recovery via Veh_TriggerRecovery carries the
 *     fault message through the JIT_FRAME_T and returns nonzero.
 *  4. Frame stack is empty at the end.
 */
#include "test_harness.h"
#include "jit/dispatch.h"
#include "ffi/veh.h"

#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"

#include <string.h>

static int Body_Zero( lua_State *L ) {
    (void)L;
    return 0;
}

static int Body_Three( lua_State *L ) {
    (void)L;
    return 3;
}

int main( void ) {
    TEST_BEGIN("jit_trampoline");

    lua_State *L = luaL_newstate();
    CHECK_NOT_NULL( L );
    Veh_Shutdown();

    /* 1. Normal path: returns 0. */
    int Rc = Jit_TrampolineEntry( L, Body_Zero );
    CHECK_EQ_INT( Rc, 0 );
    CHECK_NULL( g_CurrentJitFrame );

    /* 2. Normal path: returns 3. */
    Rc = Jit_TrampolineEntry( L, Body_Three );
    CHECK_EQ_INT( Rc, 3 );
    CHECK_NULL( g_CurrentJitFrame );

    /* 3. Manual setjmp/longjmp recovery round-trip via a raw JIT_FRAME_T.
     *    We push a frame ourselves, call Veh_TriggerRecovery, verify:
     *     a) setjmp returned nonzero (recovery branch executed)
     *     b) FaultMessage contains our string
     *     c) frame stack restored
     */
    {
        JIT_FRAME_T Frame;
        memset( &Frame, 0, sizeof( Frame ) );
        Frame.Prev       = g_CurrentJitFrame;
        Frame.PrevLuaTop = L->top.p;
        g_CurrentJitFrame = &Frame;

        if ( setjmp( Frame.RecoveryJmp ) == 0 ) {
            Veh_TriggerRecovery( "test_fault_42" );
            /* Should not reach here */
            CHECK_MSG( 0, "Veh_TriggerRecovery should not return" );
        } else {
            /* Recovery landed here */
            CHECK_MSG( strstr( Frame.FaultMessage, "test_fault_42" ) != NULL,
                       "FaultMessage contains test_fault_42" );
        }
        g_CurrentJitFrame = Frame.Prev;
    }

    /* 4. Frame stack is clean. */
    CHECK_NULL( g_CurrentJitFrame );

    lua_close( L );
    TEST_END();
}
