#include "jit/runtime.h"
#include "jit/dispatch.h"

#include "lua.h"
#include "lauxlib.h"
#include "lgc.h"
#include "lobject.h"
#include "lstate.h"
#include "lvm.h"
#include "ldo.h"
#include "ltable.h"
#include "ldebug.h"
#include "lfunc.h"
#include "ltm.h"
#include "lopcodes.h"  /* GETARG_sB/C/k — decode the trailing MMBINI in Rt_ShiftI */

#include "ffi/cdata.h"
#include "ffi/ffi_call.h"

#include <stdio.h>

int Rt_AddSlow( lua_State *L, int A, int B, int C ) {
    /* Defer to upstream's arith handler. luaO_arith handles metamethods,
       float promotion, and errors. */
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPADD, s2v( Base + B ), s2v( Base + C ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_SubSlow( lua_State *L, int A, int B, int C ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPSUB, s2v( Base + B ), s2v( Base + C ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_MulSlow( lua_State *L, int A, int B, int C ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPMUL, s2v( Base + B ), s2v( Base + C ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_Call( lua_State *L, int A, int NArgs, int NResults ) {
    StkId Base = L->ci->func.p + 1;
    StkId Func = Base + A;

    /* Adjust L->top to point past the last argument so luaD_call knows the
       arg count. NArgs == -1 means "use all values up to L->top" (from
       Lua's B=0 convention) — we just leave L->top alone in that case. */
    if ( NArgs >= 0 ) {
        L->top.p = Func + 1 + NArgs;
    }

    /* If the callee is a Lua closure with a JIT-compilable Proto, set up
       its CallInfo and direct-call the JIT entry. Otherwise fall back to
       luaD_call (handles C closures, callable metatables, non-JIT'able
       Lua functions). */
    if ( ttisLclosure( s2v( Func ) ) ) {
        LClosure   *Cl     = clLvalue( s2v( Func ) );
        /* Only take the fast JIT->JIT entry when the callee is ALREADY compiled.
           If it is not, fall through to luaD_call (the upstream path that pcall
           uses): that compiles + runs it via luaV_execute and caches it, so the
           NEXT call takes the fast path. Compiling INLINE here (the old
           Jit_Compile call) ran the codegen WHILE the JIT'd caller's frame was
           live; the first direct JIT->JIT call to a function that itself calls
           a not-yet-compiled function (e.g. diff.unified -> diff.lines) had its
           frame corrupted mid-execution and crashed with "attempt to index a
           function value". Routing the cold call through luaD_call removes the
           nested-compile-during-execution hazard entirely. */
        JIT_FUNC_T  Jitted = Jit_LookupCached( Cl->p );
        /* hookmask != 0: a debug hook is active; take the slow luaD_call path so
           the callee runs in the hook-aware interpreter (the JIT honors no hooks). */
        if ( Jitted != NULL && L->hookmask == 0 ) {
            /* Set up CallInfo for the callee. REUSE an existing CI from
               L->ci->next if available (upstream's `next_ci` macro);
               only call luaE_extendCI when the chain has no spare. The
               previous implementation always extended -- every Lua-to-Lua
               call leaked 64 bytes (sizeof(CallInfo)) because the linked
               list grew forever. CI memory is reclaimed by luaE_shrinkCI
               from the GC, but only when the list size exceeds nciextra. */
            CallInfo *Ci = ( L->ci->next != NULL ) ? L->ci->next
                                                   : luaE_extendCI( L );
            Ci->func.p         = Func;
            Ci->top.p          = Func + 1 + Cl->p->maxstacksize;
            Ci->u.l.savedpc    = Cl->p->code;
            Ci->u.l.trap       = 0;
            Ci->u.l.nextraargs = 0;
            Ci->callstatus     = 0;
            Ci->nresults       = ( short )NResults;
            L->ci = Ci;
            /* Ensure stack room for the callee's registers. This can grow (and
               thus RELOCATE) the Lua stack; correctstack fixes Ci->func.p but
               NOT our C local `Func`, so re-derive it from the (corrected)
               CallInfo afterwards. Without this, the nil-pad loop and the
               L->top assignment below write through a dangling pointer into the
               freed old stack buffer when the callee frame doesn't fit. */
            lua_checkstack( L, Cl->p->maxstacksize + 5 );
            Func = Ci->func.p;
            /* Nil-pad missing fixed arguments. Mirrors upstream
               luaD_precall's `for (; narg < nfixparams; narg++)
               setnilvalue(s2v(L->top.p++));` loop. Without this, a
               callee whose declared parameter wasn't passed by the
               caller sees whatever stale TValue happened to be at
               that stack slot from a previous call -- e.g. a leftover
               function, which then surfaces as "cannot convert
               function to ctype" when the callee passes the missing
               param to a C call. */
            {
                int NArgsActual = ( int )( L->top.p - Func - 1 );
                int NFixParams  = Cl->p->numparams;
                int I;
                for ( I = NArgsActual; I < NFixParams; I++ ) {
                    setnilvalue( s2v( Func + 1 + I ) );
                }
                if ( NArgsActual < NFixParams ) {
                    L->top.p = Func + 1 + NFixParams;
                }
            }
            /* For vararg functions: leave L->top.p at Func+1+NArgs so
               OP_VARARGPREP can count actual args from L->top.p.
               For non-vararg functions: set it to Ci->top.p so that
               all register slots are within the stack's live range. */
            if ( !Cl->p->is_vararg ) {
                L->top.p = Ci->top.p;
            }
            Jitted( L );

            /* Rt_PrepReturn left results at Ci->func.p (it un-relocates for
               vararg callees first). Re-derive the destination from the
               CALLER's (current) func.p + 1 + A -- the local `Func`
               computed at entry is stale if Jitted triggered a stack
               realloc, since correctstack updates ci->func.p for all
               CallInfos but not our C local. */
            StkId NewFunc = Ci->previous->func.p + 1 + A;
            int   N       = ( int )( L->top.p - Ci->func.p );
            if ( Ci->func.p != NewFunc ) {
                int I;
                for ( I = 0; I < N; I++ ) {
                    setobjs2s( L, NewFunc + I, Ci->func.p + I );
                }
                L->top.p = NewFunc + N;
            }

            /* If the caller asked for a fixed result count (NResults >= 0)
               and the callee produced fewer, nil-pad up to NResults so
               `local f, err = call()` doesn't surface a stale arg value
               for `err`. NResults == -1 (MULTRET) keeps the actual count. */
            if ( NResults >= 0 ) {
                int Have = ( int )( L->top.p - NewFunc );
                while ( Have < NResults ) {
                    setnilvalue( s2v( NewFunc + Have ) );
                    Have++;
                }
                L->top.p = NewFunc + NResults;
            }

            /* Restore caller's CallInfo. */
            L->ci = Ci->previous;
            /* Re-establish the between-instructions invariant L->top.p ==
               ci->top.p after a fixed-result call (the interpreter does this
               in OP_CALL). Leaving top at the results position let a following
               re-entrant metamethod -- string-coerced arithmetic, __newindex,
               etc. -- push its TM + operands over live registers. MULTRET
               (NResults < 0) keeps the real result count for the caller. */
            if ( NResults >= 0 ) L->top.p = L->ci->top.p;
            return 0;
        }
    }

    /* Fast path: callable cdata (typically an FFI CT_FUNC from ffi.C
       lookup). Skip luaD_call → luaT_callTM → __call → Cdata_Call.
       Call Ffi_GenericCall directly. */
    if ( ttisfulluserdata( s2v( Func ) ) ) {
        /* the callee Func = L->ci->func.p + 1 + A, so its 1-based stack index
           relative to the current call frame is A + 1. */
        int      FuncStackIdx = A + 1;
        PCData_T Check        = FfiGetCData( L, FuncStackIdx );
        if ( Check != NULL && Check->Type->Kind == CT_FUNC && Check->Ptr != NULL ) {
            /* args are at FuncStackIdx+1 .. FuncStackIdx+NArgs */
            int   NRes = Ffi_GenericCall( L, Check, FuncStackIdx + 1 );
            /* Ffi_GenericCall pushed NRes results at L->top - NRes.
               Move them to Func..Func+NRes-1 to match OP_CALL's contract
               (results replace the callee slot). */
            StkId Src  = L->top.p - NRes;
            int   I    = { 0 };
            for ( I = 0; I < NRes; I++ ) {
                setobjs2s( L, Func + I, Src + I );
            }
            L->top.p = Func + NRes;
            /* Nil-pad up to NResults for the same reason as the Lua-callee
               path above. */
            if ( NResults >= 0 ) {
                while ( NRes < NResults ) {
                    setnilvalue( s2v( Func + NRes ) );
                    NRes++;
                }
                L->top.p = Func + NResults;
            }
            /* Same invariant restore as the Lua-callee path above. */
            if ( NResults >= 0 ) L->top.p = L->ci->top.p;
            return 0;
        }
    }

    /* Fallback: upstream call machinery. */
    luaD_call( L, Func, NResults );
    /* luaD_poscall leaves top at the results; restore the frame ceiling for
       fixed-result calls so a following re-entrant metamethod has scratch
       space above the live registers. */
    if ( NResults >= 0 ) L->top.p = L->ci->top.p;
    return 0;
}

int Rt_PrepReturn( lua_State *L, int A, int N, int NParams1 ) {
    /* Compute Src BEFORE adjusting ci->func.p. R[A] sits at the post-
       VARARGPREP base; subtracting from ci->func.p doesn't move R[A]. */
    StkId Src = L->ci->func.p + 1 + A;
    if ( N < 0 ) {
        N = ( int )( L->top.p - Src );
    }
    /* For vararg functions: OP_VARARGPREP relocated ci->func.p forward by
       (nextraargs + nparams + 1). OP_RETURN's C arg encodes (nparams + 1)
       for vararg functions and 0 otherwise. Reverse the relocation so
       results land at the caller's expected slot (mirrors upstream
       lvm.c OP_RETURN: `ci->func.p -= ci->u.l.nextraargs + nparams1`).
       Skipping this leaks the original function value at its
       pre-VARARGPREP position, which the caller then sees as a stray
       extra return value. */
    if ( NParams1 != 0 ) {
        L->ci->func.p -= L->ci->u.l.nextraargs + NParams1;
    }
    StkId Dst = L->ci->func.p;
    if ( N == 0 ) {
        L->top.p = Dst;
    } else {
        int I = { 0 };
        for ( I = 0; I < N; I++ ) {
            setobjs2s( L, Dst + I, Src + I );
        }
        L->top.p = Dst + N;
    }
    return N;
}

int Rt_GetTabUp( lua_State *L, int A, int B, int C ) {
    LClosure     *Cl   = clLvalue( s2v( L->ci->func.p ) );
    TValue       *Upval = Cl->upvals[ B ]->v.p;
    TValue       *Key  = &Cl->p->k[ C ];
    const TValue *Slot = { 0 };
    StkId         Ra   = L->ci->func.p + 1 + A;

    /* sync L->top so luaT_callTMres pushes above the live register window */
    L->top.p = L->ci->top.p;
    /* key is always a short string constant in OP_GETTABUP */
    TString *KeyStr = tsvalue( Key );
    if ( luaV_fastget( L, Upval, KeyStr, Slot, luaH_getshortstr ) ) {
        setobj2s( L, Ra, Slot );
    } else {
        luaV_finishget( L, Upval, Key, Ra, Slot );
    }
    return 0;
}

int Rt_GetUpval( lua_State *L, int A, int B ) {
    LClosure *Cl = clLvalue( s2v( L->ci->func.p ) );
    StkId     Ra = L->ci->func.p + 1 + A;
    setobj2s( L, Ra, Cl->upvals[ B ]->v.p );
    return 0;
}

int Rt_SetUpval( lua_State *L, int A, int B ) {
    LClosure *Cl = clLvalue( s2v( L->ci->func.p ) );
    StkId     Ra = L->ci->func.p + 1 + A;
    UpVal    *Uv = Cl->upvals[ B ];
    setobj( L, Uv->v.p, s2v( Ra ) );
    luaC_barrier( L, Uv, s2v( Ra ) );
    return 0;
}

int Rt_EqSlow( lua_State *L, int A, int B ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* give an order metamethod scratch space above live regs */
    return luaV_equalobj( L, s2v( Base + A ), s2v( Base + B ) );
}

int Rt_LtSlow( lua_State *L, int A, int B ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* give an order metamethod scratch space above live regs */
    return luaV_lessthan( L, s2v( Base + A ), s2v( Base + B ) );
}

int Rt_LeSlow( lua_State *L, int A, int B ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* give an order metamethod scratch space above live regs */
    return luaV_lessequal( L, s2v( Base + A ), s2v( Base + B ) );
}

int Rt_EqISlow( lua_State *L, int A, int sB ) {
    StkId  Base = L->ci->func.p + 1;
    TValue Imm;
    setivalue( &Imm, ( lua_Integer )sB );
    L->top.p = L->ci->top.p;   /* give an order metamethod scratch space above live regs */
    return luaV_equalobj( L, s2v( Base + A ), &Imm );
}

int Rt_LtISlow( lua_State *L, int A, int sB ) {
    StkId  Base = L->ci->func.p + 1;
    TValue Imm;
    setivalue( &Imm, ( lua_Integer )sB );
    L->top.p = L->ci->top.p;   /* give an order metamethod scratch space above live regs */
    return luaV_lessthan( L, s2v( Base + A ), &Imm );
}

int Rt_LeISlow( lua_State *L, int A, int sB ) {
    StkId  Base = L->ci->func.p + 1;
    TValue Imm;
    setivalue( &Imm, ( lua_Integer )sB );
    L->top.p = L->ci->top.p;   /* give an order metamethod scratch space above live regs */
    return luaV_lessequal( L, s2v( Base + A ), &Imm );
}

/* GTI/GEI: R[A] > sB and R[A] >= sB. Implemented as the operand-SWAPPED
   less-than / less-equal (sB < R[A], sB <= R[A]) -- NOT the negated forms
   !(R[A] <= sB) / !(R[A] < sB), which are wrong for NaN: every NaN comparison
   is false, so negating flips it to a spurious true. This mirrors how Lua
   lowers a register `a > b` to OP_LT with the operands swapped. */
int Rt_GtISlow( lua_State *L, int A, int sB ) {
    StkId  Base = L->ci->func.p + 1;
    TValue Imm;
    setivalue( &Imm, ( lua_Integer )sB );
    L->top.p = L->ci->top.p;   /* order-metamethod scratch space above live regs */
    return luaV_lessthan( L, &Imm, s2v( Base + A ) );
}

int Rt_GeISlow( lua_State *L, int A, int sB ) {
    StkId  Base = L->ci->func.p + 1;
    TValue Imm;
    setivalue( &Imm, ( lua_Integer )sB );
    L->top.p = L->ci->top.p;   /* order-metamethod scratch space above live regs */
    return luaV_lessequal( L, &Imm, s2v( Base + A ) );
}

int Rt_EqKSlow( lua_State *L, int A, int B ) {
    StkId   Base = L->ci->func.p + 1;
    TValue *Key  = &clLvalue( s2v( L->ci->func.p ) )->p->k[ B ];
    /* Use raw equality for basic types (the common case). Exception: full
       userdata (FFI cdata) may implement __eq against nil or other constants
       via metamethod -- LuaJIT compat requires null-pointer cdata == nil. */
    if ( ttisfulluserdata( s2v( Base + A ) ) )
        return luaV_equalobj( L, s2v( Base + A ), Key );
    return luaV_rawequalobj( s2v( Base + A ), Key );
}

/* ForPrep returns 1 if the loop should be SKIPPED (zero-iteration case).
   Otherwise (loop will execute at least once) it leaves R[A+3] set to the
   initial value of the loop variable and returns 0. Matches upstream
   luaV_forprep's integer + float handling. */
/* Coerce a for-loop operand to lua_Number (float fast path, else integer/string
   via luaV_tonumber_) -- mirrors the core `tonumber` macro, which is LUA_CORE-
   only and so unavailable here. */
static int ForNum( const TValue *O, lua_Number *N ) {
    if ( ttisfloat( O ) ) { *N = fltvalue( O ); return 1; }
    return luaV_tonumber_( O, N );
}

int Rt_ForPrep( lua_State *L, int A ) {
    StkId  Base  = L->ci->func.p + 1;
    StkId  Ra    = Base + A;
    TValue *Init  = s2v( Ra );
    TValue *Limit = s2v( Ra + 1 );
    TValue *Step  = s2v( Ra + 2 );

    /* Integer-only fast path. Both init and step must be integers for the
       integer flow; the limit can be coerced. We follow upstream's general
       structure but cover only the int subcase. Float loops fall through to
       luaV_forprep-equivalent: not implemented in 2c — raise an error. */
    if ( ttisinteger( Init ) && ttisinteger( Step ) ) {
        lua_Integer InitI  = ivalue( Init );
        lua_Integer StepI  = ivalue( Step );
        lua_Integer LimitI = { 0 };

        if ( StepI == 0 ) {
            luaG_runerror( L, "'for' step is zero" );
            return 1;
        }
        if ( ttisinteger( Limit ) ) {
            LimitI = ivalue( Limit );
        } else if ( !luaV_tointeger( Limit, &LimitI,
                                     ( StepI < 0 ? F2Iceil : F2Ifloor ) ) ) {
            /* Limit not coercible to an integer (float out of int64 range, NaN,
               or a non-number) -- mirror lvm.c forlimit() EXACTLY: a too-large
               positive limit with a positive step TRUNCATES to LUA_MAXINTEGER
               and the loop RUNS (`for i = 1, math.huge` must iterate); only a
               limit on the wrong side of the step direction skips. (The old
               code unconditionally skipped -- and clamped in the inverted
               direction -- so every integer loop with an out-of-int64-range
               float limit silently ran zero iterations.) luaV_tointeger also
               coerces string limits, as upstream does. */
            lua_Number FLim;
            if ( !ForNum( Limit, &FLim ) ) {
                luaG_forerror( L, Limit, "limit" );  /* not a number: error */
                return 1;
            }
            if ( luai_numlt( 0, FLim ) ) {     /* positive: above any integer */
                if ( StepI < 0 ) return 1;     /* counting down -> zero trips */
                LimitI = LUA_MAXINTEGER;       /* truncate */
            } else {                           /* negative (or NaN): below any */
                if ( StepI > 0 ) return 1;     /* counting up -> zero trips */
                LimitI = LUA_MININTEGER;       /* truncate */
            }
        }

        /* Zero-iteration check: (StepI > 0 && InitI > LimitI) ||
                                  (StepI < 0 && InitI < LimitI). */
        if ( ( StepI > 0 && InitI > LimitI ) || ( StepI < 0 && InitI < LimitI ) ) {
            return 1;  /* skip the loop */
        }

        /* Compute the unsigned trip COUNT (number of iterations after the
           first) and stash it in R[A+1] in place of the limit -- exactly as
           upstream forprep does. A naive `i <= limit` comparison in FORLOOP
           infinite-loops when i overflows past the limit and wraps (e.g.
           `for i = math.maxinteger - 2, math.maxinteger`). */
        lua_Unsigned Count;
        if ( StepI > 0 ) {
            Count = ( lua_Unsigned )LimitI - ( lua_Unsigned )InitI;
            if ( StepI != 1 ) { Count /= ( lua_Unsigned )StepI; }
        } else {
            Count = ( lua_Unsigned )InitI - ( lua_Unsigned )LimitI;
            /* '-(StepI + 1)' avoids negating LUA_MININTEGER */
            Count /= ( lua_Unsigned )( -( StepI + 1 ) ) + 1u;
        }
        setivalue( s2v( Ra + 1 ), ( lua_Integer )Count );  /* count replaces limit */
        setivalue( s2v( Ra ), InitI );                     /* internal index (R[A]) */
        setivalue( s2v( Ra + 3 ), InitI );                 /* control variable */
        return 0;  /* run the body */
    }

    /* Float (or string-coercible) loop -- mirror upstream forprep's float
       subcase. Coerce all three operands to lua_Number; store limit/step as
       floats in R[A+1]/R[A+2] (so Rt_ForLoop's `ttisinteger(R[A+1])` check
       routes to the float path), the internal index in R[A], and the control
       variable in R[A+3]. */
    {
        lua_Number InitN, LimitN, StepN;
        if ( !ForNum( Limit, &LimitN ) )
            luaG_forerror( L, Limit, "limit" );
        if ( !ForNum( Step, &StepN ) )
            luaG_forerror( L, Step, "step" );
        if ( !ForNum( Init, &InitN ) )
            luaG_forerror( L, Init, "initial value" );
        if ( StepN == 0 ) {
            luaG_runerror( L, "'for' step is zero" );
            return 1;
        }
        if ( StepN > 0 ? ( LimitN < InitN ) : ( InitN < LimitN ) ) {
            return 1;  /* zero iterations -- skip the body */
        }
        setfltvalue( s2v( Ra + 1 ), LimitN );  /* float limit */
        setfltvalue( s2v( Ra + 2 ), StepN );   /* float step */
        setfltvalue( s2v( Ra ), InitN );       /* internal index */
        setfltvalue( s2v( Ra + 3 ), InitN );   /* control variable */
        return 0;  /* run the body */
    }
}

int Rt_ForLoop( lua_State *L, int A ) {
    StkId  Base = L->ci->func.p + 1;
    StkId  Ra   = Base + A;
    /* R[A+1] = remaining trip count (set by Rt_ForPrep), R[A+2] = step,
       R[A+3] = control variable. Decrement the count and advance the control
       variable -- count-based termination (like upstream forloop) so it can't
       infinite-loop on integer overflow at the limit. */
    if ( ttisinteger( s2v( Ra + 1 ) ) ) {
        lua_Unsigned Count = ( lua_Unsigned )ivalue( s2v( Ra + 1 ) );
        if ( Count > 0 ) {
            lua_Integer Step = ivalue( s2v( Ra + 2 ) );
            /* Advance the HIDDEN internal index in R[A], not the visible control
               variable R[A+3]: Lua 5.4 makes the loop variable a fresh local each
               iteration, so a body that reassigns it (`for i=1,n do i=i+1 end`)
               must NOT perturb the iteration. Reading R[A+3] here threaded the
               mutation back in (e.g. `for i=1,4 do t[#t+1]=i; i=i+100 end` gave
               1,102,203,304 under the JIT vs 1,2,3,4 in the interpreter). Mirrors
               lvm.c OP_FORLOOP and the float path below. */
            lua_Integer Idx  = ivalue( s2v( Ra ) );
            lua_Integer Next = ( lua_Integer )( ( lua_Unsigned )Idx + ( lua_Unsigned )Step );
            setivalue( s2v( Ra + 1 ), ( lua_Integer )( Count - 1 ) );
            setivalue( s2v( Ra ), Next );        /* internal index */
            setivalue( s2v( Ra + 3 ), Next );    /* control variable */
            return 1;  /* continue */
        }
    } else if ( ttisfloat( s2v( Ra + 1 ) ) ) {
        /* float loop (set up by Rt_ForPrep's float subcase): advance the
           internal index in R[A] by the step, compare against the limit, and
           mirror it into the control variable R[A+3] -- like floatforloop(). */
        lua_Number Step  = fltvalue( s2v( Ra + 2 ) );
        lua_Number Limit = fltvalue( s2v( Ra + 1 ) );
        lua_Number Idx   = fltvalue( s2v( Ra ) ) + Step;
        if ( Step > 0 ? ( Idx <= Limit ) : ( Limit <= Idx ) ) {
            chgfltvalue( s2v( Ra ), Idx );      /* internal index */
            setfltvalue( s2v( Ra + 3 ), Idx );  /* control variable */
            return 1;  /* continue */
        }
    }
    return 0;  /* loop done */
}

int Rt_NewTable( lua_State *L, int A, int B, int C ) {
    StkId  Base = L->ci->func.p + 1;
    /* Match upstream lvm.c OP_NEWTABLE: bump L->top.p past R[A] BEFORE
       allocating, in case the allocator triggers an emergency GC. Without
       this, a sweep during luaH_new / luaH_resize / luaC_checkGC sees the
       slot as "above top" and treats the new table as unreachable, clears
       the slot to nil, and the next opcode fails with "attempt to index a
       nil value". The slot already holds a valid TValue (luaD_precall
       initialises every register to nil), so widening top is safe. */
    if ( L->top.p < Base + A + 1 ) L->top.p = Base + A + 1;
    Table *T    = luaH_new( L );
    sethvalue2s( L, Base + A, T );
    if ( B > 0 || C > 0 ) {
        luaH_resize( L, T, ( unsigned int )C, ( unsigned int )B );
    }
    luaC_checkGC( L );
    return 0;
}

int Rt_GetI( lua_State *L, int A, int B, int C ) {
    StkId         Base = L->ci->func.p + 1;
    const TValue *Slot = { 0 };
    /* sync L->top so luaT_callTMres pushes above the live register window */
    L->top.p = L->ci->top.p;
    if ( luaV_fastgeti( L, s2v( Base + B ), C, Slot ) ) {
        setobj2s( L, Base + A, Slot );
    } else {
        TValue Key;
        setivalue( &Key, ( lua_Integer )C );
        luaV_finishget( L, s2v( Base + B ), &Key, Base + A, Slot );
    }
    return 0;
}

int Rt_GetField( lua_State *L, int A, int B, int C ) {
    StkId         Base = L->ci->func.p + 1;
    TValue       *Key  = &clLvalue( s2v( L->ci->func.p ) )->p->k[ C ];
    const TValue *Slot = { 0 };
    /* sync L->top so luaT_callTMres pushes above the live register window */
    L->top.p = L->ci->top.p;
    /* key is always a short string constant in OP_GETFIELD */
    if ( luaV_fastget( L, s2v( Base + B ), tsvalue( Key ), Slot, luaH_getshortstr ) ) {
        setobj2s( L, Base + A, Slot );
    } else {
        luaV_finishget( L, s2v( Base + B ), Key, Base + A, Slot );
    }
    return 0;
}

int Rt_GetTable( lua_State *L, int A, int B, int C ) {
    StkId         Base = L->ci->func.p + 1;
    TValue       *Key  = s2v( Base + C );
    const TValue *Slot = { 0 };
    lua_Unsigned   N   = { 0 };
    /* sync L->top so luaT_callTMres pushes above the live register window */
    L->top.p = L->ci->top.p;
    if ( ttisinteger( Key )
         ? ( cast_void( N = ivalue( Key ) ), luaV_fastgeti( L, s2v( Base + B ), N, Slot ) )
         : luaV_fastget( L, s2v( Base + B ), Key, Slot, luaH_get ) ) {
        setobj2s( L, Base + A, Slot );
    } else {
        luaV_finishget( L, s2v( Base + B ), Key, Base + A, Slot );
    }
    return 0;
}

/* decode the Ck-encoded C and K fields used by all setter helpers */
static void DecodeCk( int Ck, int *OutC, int *OutK ) {
    if ( Ck < 0 ) { *OutC = -Ck - 1; *OutK = 1; }
    else          { *OutC =  Ck;      *OutK = 0; }
}

int Rt_SetI( lua_State *L, int A, int B, int Ck ) {
    int           C    = { 0 };
    int           K    = { 0 };
    StkId         Base = L->ci->func.p + 1;
    const TValue *Slot = { 0 };
    DecodeCk( Ck, &C, &K );
    TValue *Val = K ? &clLvalue( s2v( L->ci->func.p ) )->p->k[ C ] : s2v( Base + C );
    /* sync L->top so luaT_callTM pushes above the live register window */
    L->top.p = L->ci->top.p;
    if ( luaV_fastgeti( L, s2v( Base + A ), B, Slot ) ) {
        luaV_finishfastset( L, s2v( Base + A ), Slot, Val );
    } else {
        TValue Key;
        setivalue( &Key, ( lua_Integer )B );
        luaV_finishset( L, s2v( Base + A ), &Key, Val, Slot );
    }
    return 0;
}

int Rt_SetField( lua_State *L, int A, int B, int Ck ) {
    int           C    = { 0 };
    int           K    = { 0 };
    StkId         Base = L->ci->func.p + 1;
    const TValue *Slot = { 0 };
    DecodeCk( Ck, &C, &K );
    TValue *Key = &clLvalue( s2v( L->ci->func.p ) )->p->k[ B ];
    TValue *Val = K ? &clLvalue( s2v( L->ci->func.p ) )->p->k[ C ] : s2v( Base + C );
    /* sync L->top so luaT_callTM pushes above the live register window */
    L->top.p = L->ci->top.p;
    /* key is always a short string constant in OP_SETFIELD */
    if ( luaV_fastget( L, s2v( Base + A ), tsvalue( Key ), Slot, luaH_getshortstr ) ) {
        luaV_finishfastset( L, s2v( Base + A ), Slot, Val );
    } else {
        luaV_finishset( L, s2v( Base + A ), Key, Val, Slot );
    }
    return 0;
}

int Rt_SetTable( lua_State *L, int A, int B, int Ck ) {
    int           C    = { 0 };
    int           K    = { 0 };
    StkId         Base = L->ci->func.p + 1;
    const TValue *Slot = { 0 };
    DecodeCk( Ck, &C, &K );
    TValue       *Key = s2v( Base + B );
    TValue       *Val = K ? &clLvalue( s2v( L->ci->func.p ) )->p->k[ C ] : s2v( Base + C );
    lua_Unsigned   N  = { 0 };
    /* sync L->top so luaT_callTM pushes above the live register window */
    L->top.p = L->ci->top.p;
    if ( ttisinteger( Key )
         ? ( cast_void( N = ivalue( Key ) ), luaV_fastgeti( L, s2v( Base + A ), N, Slot ) )
         : luaV_fastget( L, s2v( Base + A ), Key, Slot, luaH_get ) ) {
        luaV_finishfastset( L, s2v( Base + A ), Slot, Val );
    } else {
        luaV_finishset( L, s2v( Base + A ), Key, Val, Slot );
    }
    return 0;
}

int Rt_SetTabUp( lua_State *L, int A, int B, int Ck ) {
    int           C    = { 0 };
    int           K    = { 0 };
    LClosure     *Cl   = clLvalue( s2v( L->ci->func.p ) );
    TValue       *Upval = Cl->upvals[ A ]->v.p;
    const TValue *Slot = { 0 };
    DecodeCk( Ck, &C, &K );
    TValue *Key = &Cl->p->k[ B ];
    TValue *Val = K ? &Cl->p->k[ C ] : s2v( L->ci->func.p + 1 + C );
    /* sync L->top so luaT_callTM pushes above the live register window */
    L->top.p = L->ci->top.p;
    /* key is always a short string constant in OP_SETTABUP */
    if ( luaV_fastget( L, Upval, tsvalue( Key ), Slot, luaH_getshortstr ) ) {
        luaV_finishfastset( L, Upval, Slot, Val );
    } else {
        luaV_finishset( L, Upval, Key, Val, Slot );
    }
    return 0;
}

int Rt_SetList( lua_State *L, int A, int B, int C ) {
    StkId  Base = L->ci->func.p + 1;
    StkId  Ra   = Base + A;
    Table *T    = hvalue( s2v( Ra ) );
    int    N    = B;
    int    Last = C + N;
    int    I    = { 0 };
    if ( N == 0 ) {
        N    = ( int )( L->top.p - Ra ) - 1;
        Last = C + N;
    } else {
        /* Match upstream lvm.c OP_SETLIST: set L->top.p = ci->top.p
           "correct top in case of GC" so the resize-triggered GC sees
           T (and the values being copied in) as live roots. */
        L->top.p = L->ci->top.p;
    }
    /* ensure table is big enough for the new entries */
    if ( ( unsigned int )Last > luaH_realasize( T ) ) {
        luaH_resizearray( L, T, ( unsigned int )Last );
    }
    for ( I = 1; I <= N; I++ ) {
        TValue *Val = s2v( Ra + I );
        setobj2t( L, &T->array[ C + I - 1 ], Val );
        luaC_barrierback( L, obj2gco( T ), Val );
    }
    return 0;
}

int Rt_Len( lua_State *L, int A, int B ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaV_objlen( L, Base + A, s2v( Base + B ) );
    L->top.p = L->ci->top.p;   /* restore ceiling (a __len metamethod leaves top low) */
    return 0;
}

int Rt_Concat( lua_State *L, int A, int B ) {
    StkId Base = L->ci->func.p + 1;
    /* luaV_concat expects values on the top of the stack. */
    L->top.p = Base + A + B;
    luaV_concat( L, B );
    /* A __concat metamethod can call back into Lua and REALLOCATE the stack, so
       the `Base` captured above may now dangle -- re-derive it from the current
       CallInfo. luaV_concat leaves the result at the bottom of the operand range
       (the relocated R[A] == L->top.p - 1), so the move below is a safe self-copy
       that mirrors upstream OP_CONCAT (lvm.c leaves the result in place at ra). */
    Base = L->ci->func.p + 1;
    setobjs2s( L, Base + A, L->top.p - 1 );
    /* Restore the frame ceiling (a __concat metamethod leaves top low). */
    L->top.p = L->ci->top.p;
    return 0;
}

/* luaD_pretailcall is in ldo.h which is LUA_CORE-only; forward-declare. */
extern int luaD_pretailcall( lua_State *L, CallInfo *ci, StkId func,
                              int narg1, int delta );

/* Proper tail-call support (TCO). A self/mutual tail-call chain must not grow
   the native C stack. We mark the reused CallInfo with this status bit (bits
   0..13 are taken by Lua's CIST_*; 14 is free) so a nested Rt_TailCall running
   inside an active drive loop signals the loop via g_TailRepeat and returns,
   instead of re-entering the JIT. The marker lives on the CallInfo (per
   coroutine), so concurrent coroutines never see each other's drive state.
   g_TailRepeat is set and consumed synchronously within one fiber between a
   tail call and the function's immediate return (no yield/error in that window),
   so a plain file-scope flag is safe. */
#define CIST_JITTAILDRIVE ( 1u << 14 )
static int g_TailRepeat = 0;

/*!
 * @brief
 *  Frame-reusing tail call. Uses upstream luaD_pretailcall which:
 *    - For Lua callees: reuses our CallInfo (no new Lua frame); returns
 *      a negative value. We then dispatch to the new callee via JIT (if
 *      compilable) or upstream luaV_execute.
 *    - For C callees: completes the call and returns N (result count).
 *
 *  This reuses the Lua-side CallInfo (so the Lua frame stays flat) AND, for a
 *  top-level tail call, drives the resulting tail-call chain in a loop instead
 *  of re-entering the JIT recursively, so the native C stack stays flat too --
 *  proper tail-call optimization. See the CIST_JITTAILDRIVE note above.
 */
int Rt_TailCall( lua_State *L, int A, int NArgs ) {
    StkId Base  = L->ci->func.p + 1;
    StkId Func  = Base + A;
    int   Narg1 = ( NArgs >= 0 ) ? ( NArgs + 1 ) : 0;
    int   Delta = { 0 };

    /* delta for vararg cleanup: see upstream OP_TAILCALL handler in lvm.c. */
    LClosure *CallerCl = clLvalue( s2v( L->ci->func.p ) );
    if ( CallerCl->p->is_vararg ) {
        Delta = ( int )L->ci->u.l.nextraargs + CallerCl->p->numparams + 1;
    }

    if ( NArgs >= 0 ) {
        L->top.p = Func + Narg1;
    } else {
        Narg1 = ( int )( L->top.p - Func );
    }

    /* luaD_pretailcall can reallocate the Lua stack: a re-entrant C callee
       (require, pcall, ...) runs nested Lua code that grows the stack, and
       precallC's own checkstackGCp may move it too. That invalidates the raw
       `Func` pointer captured above. Save its stack offset now so the C-path
       result copy below recovers a *valid* pointer to the call's results --
       otherwise it reads from the freed old stack buffer and yields nil /
       garbage (e.g. `return require "x"` as a tail call returned nil). */
    /* Check BEFORE luaD_pretailcall, which reinitialises L->ci->callstatus for
       the new callee and would clear our drive marker. If this tail call is
       already running inside an enclosing drive loop (same reused CI), don't
       recurse -- signal that loop to take over the new callee, so the native
       C stack stays flat (proper TCO). */
    int Nested = ( L->ci->callstatus & CIST_JITTAILDRIVE ) != 0;

    ptrdiff_t FuncOff = savestack( L, Func );
    int N = luaD_pretailcall( L, L->ci, Func, Narg1, Delta );
    if ( N < 0 ) {
        /* Lua callee — CallInfo reused (the Lua frame stays flat). */
        if ( Nested ) {
            g_TailRepeat = 1;          /* enclosing drive loop runs the callee */
            return 0;
        }
        /* Top-level tail call: drive the reused-CI chain ITERATIVELY so a run of
           tail calls (deep self- or mutual-recursion) does not grow the native
           stack. Each subsequent tail call returns here via g_TailRepeat rather
           than re-entering the JIT. */
        int NRes = 0;
        for ( ;; ) {
            if ( L->hookmask != 0 ) {
                /* A debug hook is active -> run the callee in the hook-aware
                   interpreter (the JIT honors no hooks). */
                luaV_execute( L, L->ci );
                NRes = 0;
                break;
            }
            LClosure  *NewCl  = clLvalue( s2v( L->ci->func.p ) );
            /* Compile-if-needed here (not LookupCached): the tail-caller's frame
               is already gone -- the CI was reused -- so inline codegen is safe
               (the Rt_Call inline-compile hazard only applies when the caller
               frame is still live above). This is what the original tail path
               did; routing an uncompiled callee through luaV_execute instead
               loses its result count and breaks mutual/multi-value tail calls. */
#ifdef LUAC_AOT_RUNTIME
            /* Closed world: every reachable Proto's native body was registered
               at startup, so lookup is sufficient; NULL falls back to
               luaV_execute below exactly like a compile failure. */
            JIT_FUNC_T Jitted = Jit_LookupCached( NewCl->p );
#else
            JIT_FUNC_T Jitted = Jit_Compile( L, NewCl->p );
#endif
            if ( Jitted == NULL ) {
                /* Genuine compile failure (e.g. unsupported opcode): fall back to
                   the upstream interpreter, which runs the callee to completion. */
                luaV_execute( L, L->ci );
                NRes = 0;
                break;
            }
            L->ci->callstatus |= CIST_JITTAILDRIVE;   /* re-assert (pretailcall cleared it) */
            g_TailRepeat = 0;
            NRes = Jitted( L );
            if ( !g_TailRepeat ) { break; }           /* real return ends the chain */
            /* else: the callee tail-called; L->ci was reused for the next callee */
        }
        L->ci->callstatus &= ( unsigned short )~CIST_JITTAILDRIVE;
        g_TailRepeat = 0;
        return NRes;
    }
    /* C function path: precallC placed N results at the (relocated) Func
       slot AND restored L->ci to the caller. For a vararg caller, the
       results sit `Delta` slots higher than where the caller's CallInfo
       expects them to land — mirror upstream lvm.c OP_TAILCALL by
       reversing the VARARGPREP relocation on caller's ci.func.p and
       shifting the results down by Delta so subsequent luaD_poscall /
       Rt_Call result handling sees them at the original position. */
    if ( Delta > 0 ) {
        L->ci->func.p -= Delta;
    }
    Func = restorestack( L, FuncOff );  /* recover after any stack realloc */
    StkId Dst = L->ci->func.p;
    if ( N > 0 && Func != Dst ) {
        int I = { 0 };
        for ( I = 0; I < N; I++ ) {
            setobjs2s( L, Dst + I, Func + I );
        }
        L->top.p = Dst + N;
    } else if ( N == 0 ) {
        L->top.p = Dst;
    }
    return N;
}

int Rt_NewClosure( lua_State *L, int A, int Bx ) {
    LClosure *Outer  = clLvalue( s2v( L->ci->func.p ) );
    Proto    *ChildP = Outer->p->p[ Bx ];
    StkId     Base   = L->ci->func.p + 1;
    LClosure *NewCl  = luaF_newLclosure( L, ChildP->sizeupvalues );
    int       I      = { 0 };

    NewCl->p = ChildP;
    /* push the closure into R[A] first so the GC can see it before we start
       writing upvalues into it (upstream's pattern) */
    setclLvalue2s( L, Base + A, NewCl );
    /* bind upvalues per the upvalue descriptor table */
    for ( I = 0; I < ChildP->sizeupvalues; I++ ) {
        Upvaldesc *Desc = &ChildP->upvalues[ I ];
        if ( Desc->instack ) {
            NewCl->upvals[ I ] = luaF_findupval( L, Base + Desc->idx );
        } else {
            NewCl->upvals[ I ] = Outer->upvals[ Desc->idx ];
        }
        /* barrier between the new closure and the upvalue it captured */
        luaC_objbarrier( L, NewCl, NewCl->upvals[ I ] );
    }
    /* match upstream lvm.c OP_CLOSURE: trigger a GC step after creating
       the closure so allocation-heavy loops don't grow the heap unbounded.
       L->top.p must extend past R[A] so the new closure is treated as a
       live root -- upstream uses the checkGC(L, ra+1) macro for this. */
    if ( L->top.p < Base + A + 1 ) L->top.p = Base + A + 1;
    luaC_checkGC( L );
    return 0;
}

int Rt_Vararg( lua_State *L, int A, int NRequired ) {
    StkId Base = L->ci->func.p + 1;
    luaT_getvarargs( L, L->ci, Base + A, NRequired );
    return 0;
}

int Rt_VarargPrep( lua_State *L, int A ) {
    LClosure *Cl = clLvalue( s2v( L->ci->func.p ) );
    luaT_adjustvarargs( L, A, L->ci, Cl->p );
    /* Claim the whole register frame: raise L->top.p to the frame ceiling so
       a re-entrant metamethod (e.g. string-coerced arithmetic, whose
       luaT_callTMres pushes the TM + operands at L->top.p) gets scratch space
       ABOVE the live registers instead of clobbering them. After
       adjustvarargs L->top.p sits at the register base for a vararg frame
       (the main chunk), which let `local x = "3.5" + 0` overwrite R0 with the
       __add metamethod. Non-vararg frames already have top == ci->top.p from
       luaD_precall; this makes vararg frames match. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_NotOp( lua_State *L, int A, int B ) {
    StkId   Base = L->ci->func.p + 1;
    TValue *V    = s2v( Base + B );
    /* l_isfalse is the canonical nil-or-false test from lobject.h */
    if ( l_isfalse( V ) ) {
        setbtvalue( s2v( Base + A ) );  /* R[A] = true */
    } else {
        setbfvalue( s2v( Base + A ) );  /* R[A] = false */
    }
    return 0;
}

int Rt_UnmOp( lua_State *L, int A, int B ) {
    StkId Base = L->ci->func.p + 1;
    /* for unary ops, luaO_arith takes the value as both operands */
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPUNM, s2v( Base + B ), s2v( Base + B ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_BNotOp( lua_State *L, int A, int B ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPBNOT, s2v( Base + B ), s2v( Base + B ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_DivOp( lua_State *L, int A, int B, int C ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPDIV, s2v( Base + B ), s2v( Base + C ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_AddOp( lua_State *L, int A, int B, int C ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPADD, s2v( Base + B ), s2v( Base + C ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_SubOp( lua_State *L, int A, int B, int C ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPSUB, s2v( Base + B ), s2v( Base + C ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_MulOp( lua_State *L, int A, int B, int C ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPMUL, s2v( Base + B ), s2v( Base + C ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_ModOp( lua_State *L, int A, int B, int C ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPMOD, s2v( Base + B ), s2v( Base + C ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_IDivOp( lua_State *L, int A, int B, int C ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPIDIV, s2v( Base + B ), s2v( Base + C ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_PowOp( lua_State *L, int A, int B, int C ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPPOW, s2v( Base + B ), s2v( Base + C ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_AddKOp( lua_State *L, int A, int B, int C ) {
    StkId   Base = L->ci->func.p + 1;
    TValue *K    = &clLvalue( s2v( L->ci->func.p ) )->p->k[ C ];
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPADD, s2v( Base + B ), K, Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

/* OP_ADDI A B sC: R[A] = R[B] + sC (signed immediate). */
int Rt_AddIOp( lua_State *L, int A, int B, int sC ) {
    StkId  Base = L->ci->func.p + 1;
    TValue Imm  = { 0 };
    setivalue( &Imm, ( lua_Integer )sC );
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPADD, s2v( Base + B ), &Imm, Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_SubKOp( lua_State *L, int A, int B, int C ) {
    StkId   Base = L->ci->func.p + 1;
    TValue *K    = &clLvalue( s2v( L->ci->func.p ) )->p->k[ C ];
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPSUB, s2v( Base + B ), K, Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_MulKOp( lua_State *L, int A, int B, int C ) {
    StkId   Base = L->ci->func.p + 1;
    TValue *K    = &clLvalue( s2v( L->ci->func.p ) )->p->k[ C ];
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPMUL, s2v( Base + B ), K, Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_DivKOp( lua_State *L, int A, int B, int C ) {
    StkId   Base = L->ci->func.p + 1;
    TValue *K    = &clLvalue( s2v( L->ci->func.p ) )->p->k[ C ];
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPDIV, s2v( Base + B ), K, Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_ModKOp( lua_State *L, int A, int B, int C ) {
    StkId   Base = L->ci->func.p + 1;
    TValue *K    = &clLvalue( s2v( L->ci->func.p ) )->p->k[ C ];
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPMOD, s2v( Base + B ), K, Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_IDivKOp( lua_State *L, int A, int B, int C ) {
    StkId   Base = L->ci->func.p + 1;
    TValue *K    = &clLvalue( s2v( L->ci->func.p ) )->p->k[ C ];
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPIDIV, s2v( Base + B ), K, Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_PowKOp( lua_State *L, int A, int B, int C ) {
    StkId   Base = L->ci->func.p + 1;
    TValue *K    = &clLvalue( s2v( L->ci->func.p ) )->p->k[ C ];
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPPOW, s2v( Base + B ), K, Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_BAndOp( lua_State *L, int A, int B, int C ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPBAND, s2v( Base + B ), s2v( Base + C ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_BOrOp( lua_State *L, int A, int B, int C ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPBOR, s2v( Base + B ), s2v( Base + C ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_BXorOp( lua_State *L, int A, int B, int C ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPBXOR, s2v( Base + B ), s2v( Base + C ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_ShlOp( lua_State *L, int A, int B, int C ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPSHL, s2v( Base + B ), s2v( Base + C ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_ShrOp( lua_State *L, int A, int B, int C ) {
    StkId Base = L->ci->func.p + 1;
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPSHR, s2v( Base + B ), s2v( Base + C ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_BAndKOp( lua_State *L, int A, int B, int C ) {
    StkId   Base = L->ci->func.p + 1;
    TValue *K    = &clLvalue( s2v( L->ci->func.p ) )->p->k[ C ];
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPBAND, s2v( Base + B ), K, Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_BOrKOp( lua_State *L, int A, int B, int C ) {
    StkId   Base = L->ci->func.p + 1;
    TValue *K    = &clLvalue( s2v( L->ci->func.p ) )->p->k[ C ];
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPBOR, s2v( Base + B ), K, Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_BXorKOp( lua_State *L, int A, int B, int C ) {
    StkId   Base = L->ci->func.p + 1;
    TValue *K    = &clLvalue( s2v( L->ci->func.p ) )->p->k[ C ];
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPBXOR, s2v( Base + B ), K, Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_ShrIOp( lua_State *L, int A, int B, int sC ) {
    StkId  Base = L->ci->func.p + 1;
    TValue Imm;
    setivalue( &Imm, ( lua_Integer )sC );
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPSHR, s2v( Base + B ), &Imm, Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_ShlIOp( lua_State *L, int A, int B, int sC ) {
    /* OP_SHLI is encoded as "sC << R[B]" — the immediate is the left operand */
    StkId  Base = L->ci->func.p + 1;
    TValue Imm;
    setivalue( &Imm, ( lua_Integer )sC );
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    luaO_arith( L, LUA_OPSHL, &Imm, s2v( Base + B ), Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

/*!
 * @brief
 *  Unified slow path for OP_SHRI / OP_SHLI driven by the following OP_MMBINI.
 *
 *  Lua compiles `a << K` into `SHRI a, a, -K` (since a<<K == a>>-K for the
 *  integer fast path) but the trailing MMBINI carries the TRUE metamethod tag
 *  (`__shl`) and the corrected positive immediate. The old per-opcode helpers
 *  hardcoded LUA_OPSHR/LUA_OPSHL from the opcode, so a metatable'd `a << K`
 *  wrongly dispatched `__shr(a, -K)` instead of `__shl(a, K)`. This helper
 *  reads the MMBINI exactly like the interpreter (lvm.c OP_MMBINI):
 *    - operand register B, result register A (both passed in),
 *    - imm  = GETARG_sB(mm)  (the corrected original immediate),
 *    - tm   = GETARG_C(mm)   (TM_SHL or TM_SHR),
 *    - flip = GETARG_k(mm)   (which operand is the constant).
 *  Integer fast path mirrors luaV_shiftl; non-integer dispatches the correct
 *  metamethod via luaT_trybiniTM. SHRI/SHLI are always followed by MMBINI
 *  (lcode.c finishbinexpval), so `MmIns` is reliable.
 *
 * @param MmIns  the raw 32-bit OP_MMBINI instruction word (P->code[Pc+1]).
 */
int Rt_ShiftI( lua_State *L, int A, int B, int MmIns ) {
    StkId       Base = L->ci->func.p + 1;
    Instruction Mm   = ( Instruction )( unsigned )MmIns;
    TValue      ImmV;
    /* The MMBINI's C field holds the real metamethod event (TM_SHL/TM_SHR), sB
       the corrected immediate, k the flip. Driving luaO_arith off these gives
       the integer fast path AND the correct __shl/__shr metamethod + operand
       order for every source form (a>>K, a<<K→SHRI, K<<a). */
    int         Op   = ( GETARG_C( Mm ) == TM_SHL ) ? LUA_OPSHL : LUA_OPSHR;
    int         Flip = GETARG_k( Mm );
    setivalue( &ImmV, ( lua_Integer )GETARG_sB( Mm ) );
    L->top.p = L->ci->top.p;   /* TM/error pushes go ABOVE live regs (round-6 fix) */
    if ( !Flip )
        luaO_arith( L, Op, s2v( Base + B ), &ImmV, Base + A );  /* value <op> imm */
    else
        luaO_arith( L, Op, &ImmV, s2v( Base + B ), Base + A );  /* imm <op> value */
    /* restore the metamethod-top invariant (see the arith helpers above) */
    L->top.p = L->ci->top.p;
    return 0;
}

/*!
 *  Generic immediate/constant arith slow path, driven -- like Rt_ShiftI -- by
 *  the trailing OP_MMBINI/OP_MMBINK word, which carries the TRUE metamethod
 *  event, original operand, and operand order for every source form. The
 *  per-opcode helpers (Rt_AddIOp/Rt_AddKOp/...) derive the event and operand
 *  order from the OPCODE, which is wrong in two ways the interpreter is not:
 *    - `x - 1` compiles to ADDI x,-1 + MMBINI(TM_SUB, imm=+1): a metatable'd x
 *      must dispatch __sub(x, 1), not __add(x, -1);
 *    - `1 + x` / `2 * x` / `K & x` swap commutative operands into ADDK/MULK/
 *      BANDK x,K + MMBIN*(k=1): the metamethod must see (K, x) order.
 *  Decoding the MMBIN* word gives: event = C (TM_*, same order as LUA_OP*, so
 *  luaO_arith gets `event - TM_ADD + LUA_OPADD`), constant = sB (MMBINI
 *  immediate, already un-negated) or k[B] (MMBINK), flip = k. luaO_arith
 *  performs the raw arith for numbers/strings and dispatches the correct
 *  metamethod otherwise -- observationally identical to the interpreter's
 *  fast-op + MMBIN* pair. Every ADDI and K-variant arith op is followed by its
 *  MMBIN* word (lcode.c finishbinexpval), so `MmIns` is reliable.
 *
 * @param MmIns  the raw 32-bit OP_MMBINI/OP_MMBINK instruction word.
 */
int Rt_ArithIK( lua_State *L, int A, int B, int MmIns ) {
    StkId       Base = L->ci->func.p + 1;
    Instruction Mm   = ( Instruction )( unsigned )MmIns;
    int         Ev   = ( int )GETARG_C( Mm );          /* TM_* event */
    int         Flip = GETARG_k( Mm );
    TValue      ImmV;
    TValue     *P2;
    if ( GET_OPCODE( Mm ) == OP_MMBINK ) {
        P2 = &clLvalue( s2v( L->ci->func.p ) )->p->k[ GETARG_B( Mm ) ];
    } else {
        setivalue( &ImmV, ( lua_Integer )GETARG_sB( Mm ) );
        P2 = &ImmV;
    }

    /* RAW numeric path first -- replicating the ORIGINAL opcode's arithmetic,
       which is NOT always the MMBIN event's operation: `x - 0` compiles to
       ADDI x,0 + MMBINI(TM_SUB, imm=+0), and lvm.c's ADDI arm computes the
       ADDITION x + (-imm). Observable at x = -0.0: -0.0 + 0.0 == +0.0 but
       -0.0 - 0.0 == -0.0. The event drives ONLY the metamethod dispatch. */
    {
        TValue        RawImm;
        const TValue *R1, *R2;
        int           RawOp = Ev - TM_ADD + LUA_OPADD;
        if ( GET_OPCODE( Mm ) == OP_MMBINI && Ev == TM_SUB && !Flip ) {
            /* original op was ADDI with sC = -imm: raw path adds the negation */
            setivalue( &RawImm, -( lua_Integer )GETARG_sB( Mm ) );
            RawOp = LUA_OPADD;  R1 = s2v( Base + B );  R2 = &RawImm;
        } else if ( !Flip ) { R1 = s2v( Base + B );  R2 = P2; }
        else                { R1 = P2;               R2 = s2v( Base + B ); }
        if ( luaO_rawarith( L, RawOp, R1, R2, s2v( Base + A ) ) )
            return 0;                                /* pure numeric: done */
    }

    /* Metamethod path: scratch space ABOVE the live registers (a stale low
       top makes luaT pushes clobber the operand slots -- the round-6 bug),
       then dispatch the MMBIN event with the ORIGINAL operand and order,
       exactly like lvm.c OP_MMBINI/OP_MMBINK. luaT_trybinTM raises the
       proper typed error when there is no handler. */
    L->top.p = L->ci->top.p;
    if ( !Flip )
        luaT_trybinTM( L, s2v( Base + B ), P2, Base + A, ( TMS )Ev );
    else
        luaT_trybinTM( L, P2, s2v( Base + B ), Base + A, ( TMS )Ev );
    L->top.p = L->ci->top.p;   /* the TM leaves top at its result: restore */
    return 0;
}

/*!
 *  Unified LTI/LEI/GTI/GEI slow path, driven by the raw comparison instruction
 *  word. Two fidelity details the old per-opcode helpers missed:
 *    - the C field is lvm.c's `isf` flag: the immediate was originally a FLOAT
 *      constant (`t < 2.0` -> LTI t,2,C=1), so an __lt/__le metamethod must
 *      receive 2.0 (math.type "float"), not 2;
 *    - GTI/GEI dispatch the SWAPPED __lt/__le (imm on the left), mirroring
 *      lvm.c op_orderI's `inv` flag (already handled here via operand order).
 *
 * @param RawIns  the raw 32-bit OP_LTI/OP_LEI/OP_GTI/OP_GEI instruction word.
 */
int Rt_OrderISlow( lua_State *L, int A, int RawIns ) {
    StkId       Base = L->ci->func.p + 1;
    Instruction I    = ( Instruction )( unsigned )RawIns;
    int         Im   = GETARG_sB( I );
    TValue      Imm;
    if ( GETARG_C( I ) ) { setfltvalue( &Imm, cast_num( Im ) ); }
    else                 { setivalue( &Imm, ( lua_Integer )Im ); }
    L->top.p = L->ci->top.p;   /* order-metamethod scratch space above live regs */
    switch ( GET_OPCODE( I ) ) {
        case OP_LTI: return luaV_lessthan ( L, s2v( Base + A ), &Imm );
        case OP_LEI: return luaV_lessequal( L, s2v( Base + A ), &Imm );
        case OP_GTI: return luaV_lessthan ( L, &Imm, s2v( Base + A ) );
        case OP_GEI: return luaV_lessequal( L, &Imm, s2v( Base + A ) );
        default:     return 0;  /* unreachable: only the *I order ops call this */
    }
}

int Rt_Tbc( lua_State *L, int A ) {
    StkId Base = L->ci->func.p + 1;
    luaF_newtbcupval( L, Base + A );
    /* A metamethod (string coercion / overloaded operator) reaches Lua via
       luaT_callTMres, which leaves L->top.p at the TM result -- below the
       frame ceiling. Restore the invariant so the NEXT re-entrant op (e.g.
       the next string-coerced arg in a multi-arg call) gets scratch space
       above the live registers instead of clobbering them. */
    L->top.p = L->ci->top.p;
    return 0;
}

int Rt_Close( lua_State *L, int A ) {
    StkId Base = L->ci->func.p + 1;
    /* Mirror lvm.c OP_RETURN: raise L->top to the frame ceiling AND pass
       CLOSEKTOP, so a __close metamethod's call frame takes its scratch ABOVE
       the live registers -- including the pending return value -- instead of
       overwriting them. The two go together: with the LUA_OK status,
       prepcallclosemth -> luaD_seterrorobj resets L->top to (level + 2), right
       on top of the result registers, which undoes the raise. With CLOSEKTOP it
       keeps the raised top. Without this, `local x <close> = ...; return v`
       returned nil because the (even empty) __close call clobbered v's slot.

       But the raise must NOT persist past the close: Lower_TailCall/Lower_Return
       emit this BEFORE the multret OP_TAILCALL/OP_RETURN, which then computes its
       value count from L->top (B == 0). A generic-for loop sets the k (close)
       flag on the function's terminal tail call/return -- so `return f(...)` /
       `return ...` right after `for k in pairs(t)` would otherwise see the
       raised ceiling as extra trailing arguments (JIT-VARARG-001). The
       interpreter captures the count BEFORE closing; we instead save the logical
       top here and restore it after, which is equivalent and also survives a
       stack relocation triggered by a real __close metamethod. */
    ptrdiff_t SavedTop = savestack( L, L->top.p );
    if ( L->top.p < L->ci->top.p ) { L->top.p = L->ci->top.p; }
    luaF_close( L, Base + A, CLOSEKTOP, 0 );
    L->top.p = restorestack( L, SavedTop );
    return 0;
}

int Rt_TForPrep( lua_State *L, int A ) {
    StkId Base = L->ci->func.p + 1;
    luaF_newtbcupval( L, Base + A + 3 );
    return 0;
}

int Rt_TForCall( lua_State *L, int A, int C ) {
    StkId Base = L->ci->func.p + 1;
    StkId Ra   = Base + A;
    /* copy iter/state/control to R[A+4]/R[A+5]/R[A+6] */
    setobjs2s( L, Ra + 4, Ra );
    setobjs2s( L, Ra + 5, Ra + 1 );
    setobjs2s( L, Ra + 6, Ra + 2 );
    L->top.p = Ra + 4 + 3;
    luaD_call( L, Ra + 4, C );
    return 0;
}

int Rt_TForLoop( lua_State *L, int A ) {
    StkId Base = L->ci->func.p + 1;
    StkId Ra   = Base + A;
    if ( !ttisnil( s2v( Ra + 4 ) ) ) {
        setobjs2s( L, Ra + 2, Ra + 4 );  /* control = first result */
        return 1;  /* continue loop */
    }
    return 0;  /* loop done */
}

int Rt_Self( lua_State *L, int A, int B, int C ) {
    StkId         Base = L->ci->func.p + 1;
    TValue       *Key  = &clLvalue( s2v( L->ci->func.p ) )->p->k[ C ];
    const TValue *Slot = { 0 };
    /* setobj2s for R[A+1] = R[B] (do this FIRST so a subsequent table-get
       can't observe a stale R[A+1] if the table is the same as R[A]) */
    setobj2s( L, Base + A + 1, s2v( Base + B ) );
    /* sync L->top so luaT_callTMres pushes above the live register window */
    L->top.p = L->ci->top.p;
    /* R[A] = R[B][K[C]] -- use luaV_fastget's RETURN value, not just whether
       Slot is NULL. fastget can leave Slot pointing at an "empty" sentinel
       (LUA_VEMPTY, tt=32) when the key is absent from a real table -- we'd
       then incorrectly write that sentinel to R[A] and the call site would
       see a non-callable nil-variant. */
    /* luaH_getstr (not luaH_getshortstr): OP_SELF's method-name key may be a
       LONG string (an identifier > LUAI_MAXSHORTLEN/40 chars), unlike GETFIELD
       whose key the compiler guarantees to be short. getshortstr reads a long
       string's lazily-computed hash before it exists and scans the wrong bucket
       (currently masked only by the finishget fallback); getstr dispatches on
       the string subtype. Matches lvm.c OP_SELF. */
    if ( luaV_fastget( L, s2v( Base + B ), tsvalue( Key ), Slot,
                       luaH_getstr ) ) {
        setobj2s( L, Base + A, Slot );
    } else {
        luaV_finishget( L, s2v( Base + B ), Key, Base + A, Slot );
    }
    return 0;
}
