#include "driver/closed_world.h"
#include "lobject.h"
#include "lopcodes.h"
#include "lstring.h"
#include <string.h>
#include <stdio.h>

static int IsName( const TValue *K, const char *Name ) {
    return ttisstring( K ) && strcmp( getstr( tsvalue( K ) ), Name ) == 0;
}

/* Was register `Reg` loaded by a LOADK of a string, and if so which one?
** Searches backwards from `From` to the most recent instruction that writes Reg.
** Returns the constant index, or -1 when the writer is not a string LOADK. */
static int ConstStringWriterOf( Proto *P, int From, int Reg ) {
    int k;
    for ( k = From - 1; k >= 0; k-- ) {
        Instruction ki = P->code[k];
        OpCode      ko = GET_OPCODE( ki );
        if ( ko == OP_LOADK && GETARG_A( ki ) == Reg ) {
            int bx = GETARG_Bx( ki );
            if ( bx >= 0 && bx < P->sizek && ttisstring( &P->k[bx] ) ) return bx;
            return -1;
        }
        if ( testAMode( ko ) && GETARG_A( ki ) == Reg ) return -1;  /* other writer */
    }
    return -1;
}

static int ScanProto( Proto *P, char *Err, size_t ErrLen ) {
    int i;
    /* Which registers currently hold _ENV.
    **
    ** THIS IS WHY IT MATTERS: the checks below used to look only at OP_GETTABUP,
    ** but lcode stops emitting GETTABUP once a chunk has more than 255 constants
    ** -- the name's constant index no longer fits in the C field -- and spills the
    ** access to
    **
    **     GETUPVAL  A, _ENV
    **     LOADK     B, "load"
    **     GETTABLE  A, A, B
    **
    ** instead. So in ANY chunk with more than 255 constants the closed world was
    ** not enforced at all. Measured before this fix: a 300-constant file
    ** containing `load("return 1")` compiled with exit 0 and then silently
    ** evaluated to nil at run time, and one containing a dynamic require compiled
    ** and then failed at run time with a list of filesystem paths -- in a binary
    ** that has no filesystem module loading. Both are far worse than the compile
    ** error the user should have got.
    **
    ** Tracking is deliberately biased toward OVER-detection, which is the safe
    ** direction for a ban: a register is marked as holding _ENV on GETUPVAL and
    ** cleared only on a definite write (testAMode), so an unclear case keeps the
    ** mark and produces a compile error rather than a hole. The false-positive
    ** risk is bounded because a rejection additionally requires the key to be a
    ** LOADK of one of the banned names. */
    unsigned char env_reg[ 256 ];
    memset( env_reg, 0, sizeof( env_reg ) );

    for ( i = 0; i < P->sizecode; i++ ) {
        Instruction op = P->code[i];
        int oc = GET_OPCODE( op );

        /* The spilled forms of a global read: _ENV in a register, indexed by a
        ** constant name either in another register (GETTABLE) or inline
        ** (GETFIELD). */
        if ( oc == OP_GETTABLE || oc == OP_GETFIELD ) {
            int tab = GETARG_B( op );
            int kidx = -1;
            if ( tab >= 0 && tab < 256 && env_reg[tab] ) {
                if ( oc == OP_GETFIELD ) {
                    kidx = GETARG_C( op );
                } else {
                    kidx = ConstStringWriterOf( P, i, GETARG_C( op ) );
                }
            }
            if ( kidx >= 0 && kidx < P->sizek && ttisstring( &P->k[kidx] ) ) {
                const TValue *K = &P->k[kidx];
                const char *banned[] = { "load", "loadstring", "dofile", NULL };
                int b;
                for ( b = 0; banned[b]; b++ ) {
                    if ( IsName( K, banned[b] ) ) {
                        snprintf( Err, ErrLen, "error: %s() is not permitted in an "
                                  "AOT-compiled program (closed world)", banned[b] );
                        return 0;
                    }
                }
                if ( IsName( K, "require" ) ) {
                    /* The module name lands in the first argument slot, the
                    ** register just above the one holding require itself. Search
                    ** FORWARD from here for whatever writes it -- searching
                    ** backwards from the end of the function finds the last writer
                    ** of that register anywhere, which rejected a legitimate
                    ** `require "json"` in a padded chunk. */
                    int argreg = GETARG_A( op ) + 1;
                    int j, ok = 0;
                    for ( j = i + 1; j < P->sizecode; j++ ) {
                        Instruction ji = P->code[j];
                        OpCode      jo = GET_OPCODE( ji );
                        if ( testAMode( jo ) && GETARG_A( ji ) == argreg ) {
                            if ( jo == OP_LOADK ) {
                                int bx = GETARG_Bx( ji );
                                ok = ( bx >= 0 && bx < P->sizek &&
                                       ttisstring( &P->k[bx] ) );
                            }
                            break;                 /* first writer decides */
                        }
                        if ( jo == OP_CALL ) break; /* called with no argument set up */
                    }
                    if ( !ok ) {
                        snprintf( Err, ErrLen, "error: dynamic require(<non-constant>) is not "
                                  "resolvable in an AOT-compiled program (closed world)" );
                        return 0;
                    }
                }
            }
        }

        if ( oc == OP_GETTABUP ) {
            const TValue *K = &P->k[ GETARG_C( op ) ];
            const char *banned[] = { "load", "loadstring", "dofile", NULL };
            int b;
            for ( b = 0; banned[b]; b++ ) {
                if ( IsName( K, banned[b] ) ) {
                    snprintf( Err, ErrLen, "error: %s() is not permitted in an "
                              "AOT-compiled program (closed world)", banned[b] );
                    return 0;
                }
            }
            if ( IsName( K, "require" ) ) {
                if ( i + 1 >= P->sizecode || GET_OPCODE( P->code[i + 1] ) != OP_LOADK ) {
                    snprintf( Err, ErrLen, "error: dynamic require(<non-constant>) is not "
                              "resolvable in an AOT-compiled program (closed world)" );
                    return 0;
                }
            }
        }

        /* Update the _ENV register set AFTER the checks above, never before.
        ** GETTABLE reuses its table register as the destination -- the spill emits
        ** `GETTABLE 1 1 2`, i.e. A == B -- so clearing env_reg[A] first would
        ** erase the very fact the check depends on, and the first version of this
        ** code did exactly that and detected nothing. */
        if ( oc == OP_GETUPVAL ) {
            int a = GETARG_A( op ), b = GETARG_B( op );
            if ( a >= 0 && a < 256 ) {
                env_reg[a] = ( b >= 0 && b < P->sizeupvalues &&
                               P->upvalues[b].name != NULL &&
                               strcmp( getstr( P->upvalues[b].name ), "_ENV" ) == 0 )
                             ? 1 : 0;
            }
        } else if ( testAMode( (OpCode)oc ) ) {
            int a = GETARG_A( op );
            if ( a >= 0 && a < 256 ) env_reg[a] = 0;   /* definitely overwritten */
        }
        if ( ( oc == OP_GETFIELD || oc == OP_GETTABUP ) && IsName( &P->k[ GETARG_C( op ) ], "dump" ) ) {
            snprintf( Err, ErrLen, "error: string.dump is not permitted in an "
                      "AOT-compiled program (closed world)" );
            return 0;
        }
        /* The spilled form of `.dump`. Checked over ANY table, not just _ENV,
        ** because string.dump indexes the `string` table -- which is itself
        ** reached through _ENV, so by this point the receiver is an ordinary
        ** register. That mirrors the GETFIELD check above, which also ignores the
        ** table operand, and it is why the small-chunk case was already covered. */
        if ( oc == OP_GETTABLE ) {
            int kidx = ConstStringWriterOf( P, i, GETARG_C( op ) );
            if ( kidx >= 0 && IsName( &P->k[kidx], "dump" ) ) {
                snprintf( Err, ErrLen, "error: string.dump is not permitted in an "
                          "AOT-compiled program (closed world)" );
                return 0;
            }
        }
    }
    { int j; for ( j = 0; j < P->sizep; j++ ) if ( !ScanProto( P->p[j], Err, ErrLen ) ) return 0; }
    return 1;
}

int Lc_CheckClosedWorld( Proto *P, char *Err, size_t ErrLen ) {
    if ( Err && ErrLen ) Err[0] = 0;
    return ScanProto( P, Err, ErrLen );
}
