#include "driver/supported_ops.h"
#include "lobject.h"
#include "lopcodes.h"
#include "lopnames.h"
#include <stdio.h>
#include <string.h>

static int OpSupported( int op ) {
    switch ( op ) {
        /* epsilon set */
        case OP_VARARGPREP:
        case OP_GETTABUP:
        case OP_LOADK:
        case OP_CALL:
        case OP_RETURN:
        case OP_RETURN0:
        case OP_RETURN1:
        /* Plan 1: loads */
        case OP_MOVE:
        case OP_LOADI:
        case OP_LOADF:
        case OP_LOADKX:
        case OP_LOADFALSE:
        case OP_LFALSESKIP:
        case OP_LOADTRUE:
        case OP_LOADNIL:
        /* Plan 1: arithmetic */
        case OP_ADD:  case OP_SUB:  case OP_MUL:  case OP_DIV:
        case OP_MOD:  case OP_IDIV: case OP_POW:
        case OP_ADDK: case OP_SUBK: case OP_MULK: case OP_DIVK:
        case OP_MODK: case OP_IDIVK: case OP_POWK:
        case OP_ADDI:
        /* Plan 1: bitwise */
        case OP_BAND: case OP_BOR:  case OP_BXOR: case OP_SHL: case OP_SHR:
        case OP_BANDK: case OP_BORK: case OP_BXORK:
        case OP_SHRI: case OP_SHLI:
        /* Plan 1: unary / len / concat / self */
        case OP_UNM:  case OP_BNOT: case OP_NOT:  case OP_LEN: case OP_CONCAT:
        case OP_SELF:
        /* Plan 1: metamethod-bin markers + extraarg (codegen no-ops them) */
        case OP_MMBIN: case OP_MMBINI: case OP_MMBINK:
        case OP_EXTRAARG:
        /* Plan 1: control flow */
        case OP_JMP:
        case OP_EQ:   case OP_LT:   case OP_LE:
        case OP_EQK:  case OP_EQI:
        case OP_LTI:  case OP_LEI:  case OP_GTI:  case OP_GEI:
        case OP_TEST: case OP_TESTSET:
        case OP_FORPREP: case OP_FORLOOP:
            return 1;
        default:
            return 0;
    }
}

static int Scan( Proto *P, char *Err, size_t ErrLen ) {
    int i;
    for ( i = 0; i < P->sizecode; i++ ) {
        int op = GET_OPCODE( P->code[i] );
        if ( !OpSupported( op ) ) {
            const char *name = ( op >= 0 && opnames[op] != NULL ) ? opnames[op] : NULL;
            if ( name ) {
                snprintf( Err, ErrLen,
                    "error: opcode OP_%s (opcode %d) is not yet supported by the "
                    "LuaC backend (this program uses a language feature beyond the "
                    "current milestone)",
                    name, op );
            } else {
                snprintf( Err, ErrLen,
                    "error: opcode %d is not yet supported by the LuaC backend "
                    "(this program uses a language feature beyond the current milestone)",
                    op );
            }
            return 0;
        }
    }
    { int j; for ( j = 0; j < P->sizep; j++ ) if ( !Scan( P->p[j], Err, ErrLen ) ) return 0; }
    return 1;
}

int Lc_CheckSupportedOps( Proto *P, char *Err, size_t ErrLen ) {
    if ( Err && ErrLen ) Err[0] = 0;
    return Scan( P, Err, ErrLen );
}
