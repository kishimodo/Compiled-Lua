/*
** bytecode.c -- diagnostic dump of the front-end's raw Lua 5.4 bytecode.
**
** Modeled on `luac -l`: for every reachable Proto (entry first, then nested
** p[] recursively), print a header giving source/lines/register count, then
** one line per pc with the opcode name and its operands. When an operand is
** an RK slot or an ABx constant index, the referenced K[] value is quoted at
** the end of the line as a comment.
**
** Uses vendored lua-5.4 headers only for the opcode enum, the operand
** accessors, and the Proto layout (`Proto`, `TValue`, `TString`). The
** opcode name table is a private copy so we do not depend on being linked
** against luaP_opnames (there is no such symbol in the tree; upstream
** ships it as a static array in lopnames.h and each translation unit that
** wants names includes the header for its own copy). That is what this file
** does too.
*/
#include "dump/emit.h"

#include "lua.h"
#include "lobject.h"
#include "lstate.h"        /* gco2ts, used by tsvalue() in the constant printer */
#include "lopcodes.h"
#include "lopnames.h"      /* static const char *const opnames[]; from lua-5.4 */

#include <stdio.h>
#include <string.h>

/* --- constant printer: mirrors luac's `PrintConstant` well enough for a
** diagnostic dump. Prints strings quoted, escapes control bytes to \NNN. */
static void PrintString( FILE *out, const TString *s ) {
    const char *p = getstr( s );
    size_t n = tsslen( s );
    size_t i;
    fputc( '"', out );
    for ( i = 0; i < n; i++ ) {
        unsigned char c = ( unsigned char )p[ i ];
        switch ( c ) {
        case '"':  fputs( "\\\"", out ); break;
        case '\\': fputs( "\\\\", out ); break;
        case '\n': fputs( "\\n",  out ); break;
        case '\r': fputs( "\\r",  out ); break;
        case '\t': fputs( "\\t",  out ); break;
        case '\0': fputs( "\\0",  out ); break;
        default:
            if ( c < 32 || c == 127 ) fprintf( out, "\\%u", ( unsigned )c );
            else                       fputc( ( int )c, out );
        }
    }
    fputc( '"', out );
}

static void PrintConstant( FILE *out, const TValue *k ) {
    switch ( ttypetag( k ) ) {
    case LUA_VNIL:      fputs( "nil",    out ); break;
    case LUA_VFALSE:    fputs( "false",  out ); break;
    case LUA_VTRUE:     fputs( "true",   out ); break;
    case LUA_VNUMINT:   fprintf( out, "%lld", ( long long )ivalue( k ) ); break;
    case LUA_VNUMFLT:   fprintf( out, "%.14g", ( double )fltvalue( k ) ); break;
    case LUA_VSHRSTR:
    case LUA_VLNGSTR:   PrintString( out, tsvalue( k ) ); break;
    default:            fprintf( out, "?tt=%d", ( int )ttypetag( k ) );
    }
}

/* --- one Proto ---------------------------------------------------------- */

static void DumpHeader( FILE *out, const Proto *p, int idx, int depth ) {
    const char *src = ( p->source != NULL ) ? getstr( p->source ) : "?";
    if ( depth == 0 ) {
        fprintf( out,
            "-- function[%d] %s:%d-%d %d params %d slots %d upvals %d consts %d funcs\n",
            idx, src, p->linedefined, p->lastlinedefined,
            ( int )p->numparams, ( int )p->maxstacksize,
            p->sizeupvalues, p->sizek, p->sizep );
    } else {
        fprintf( out,
            "-- inner[%d] (depth %d) %s:%d-%d %d params %d slots %d upvals %d consts %d funcs\n",
            idx, depth, src, p->linedefined, p->lastlinedefined,
            ( int )p->numparams, ( int )p->maxstacksize,
            p->sizeupvalues, p->sizek, p->sizep );
    }
}

/* Print the operand section of one line, format depending on the opcode's
** OpMode. `iABC` prints A/B/C (with the k flag when set), `iABx` prints
** A/Bx, etc. Constant lookups sit at the end as a `; K[..] = <val>` note. */
static void DumpInst( FILE *out, const Proto *p, int pc ) {
    Instruction i = p->code[ pc ];
    OpCode      op = GET_OPCODE( i );
    const char *name = ( op < ( OpCode )NUM_OPCODES ) ? opnames[ op ] : "OP_?";
    enum OpMode mode = ( op < ( OpCode )NUM_OPCODES )
                        ? getOpMode( op ) : iABC;
    int line = ( p->lineinfo != NULL && pc < p->sizelineinfo )
                 ? ( int )p->lineinfo[ pc ] : 0;
    int a = GETARG_A( i );

    fprintf( out, "  %4d [%4d] OP_%-10s", pc + 1, line, name );

    switch ( mode ) {
    case iABC: {
        int b  = getarg( i, POS_B, SIZE_B );
        int c  = getarg( i, POS_C, SIZE_C );
        int k  = ( int )( ( i >> POS_k ) & 1u );
        fprintf( out, " A=%d B=%d C=%d k=%d", a, b, c, k );
        /* comment: any K[] reference this op is known to make. */
        switch ( op ) {
        case OP_LOADK: /* B is Bx; handled below via iABx path (unused) */
            break;
        case OP_GETFIELD: case OP_SETFIELD:
        case OP_GETTABUP: case OP_SETTABUP:
            if ( c < p->sizek ) {
                fputs( " ; K[C] = ", out );
                PrintConstant( out, &p->k[ c ] );
            }
            break;
        case OP_ADDK: case OP_SUBK: case OP_MULK: case OP_MODK:
        case OP_POWK: case OP_DIVK: case OP_IDIVK:
        case OP_BANDK: case OP_BORK: case OP_BXORK:
            if ( c < p->sizek ) {
                fputs( " ; K[C] = ", out );
                PrintConstant( out, &p->k[ c ] );
            }
            break;
        case OP_EQK:
            if ( b < p->sizek ) {
                fputs( " ; K[B] = ", out );
                PrintConstant( out, &p->k[ b ] );
            }
            break;
        default: break;
        }
        break;
    }
    case iABx: {
        int bx = GETARG_Bx( i );
        fprintf( out, " A=%d Bx=%d", a, bx );
        if ( op == OP_LOADK && bx < p->sizek ) {
            fputs( " ; K[Bx] = ", out );
            PrintConstant( out, &p->k[ bx ] );
        }
        if ( op == OP_CLOSURE && bx < p->sizep ) {
            fprintf( out, " ; proto[%d]", bx );
        }
        break;
    }
    case iAsBx: {
        int sbx = GETARG_sBx( i );
        fprintf( out, " A=%d sBx=%d", a, sbx );
        break;
    }
    case iAx: {
        int ax = GETARG_Ax( i );
        fprintf( out, " Ax=%d", ax );
        break;
    }
    case isJ: {
        int sj = GETARG_sJ( i );
        fprintf( out, " sJ=%d ; -> pc %d", sj, pc + 1 + sj + 1 );
        break;
    }
    default:
        fprintf( out, " ; unhandled OpMode" );
        break;
    }
    fputc( '\n', out );
}

/* Depth-first walk mirroring driver/main.c CollectReachable: entry first,
** then p[] children recursively. `next_index` is a running counter so each
** printed header carries a stable index. */
static int WalkProto( FILE *out, Proto *p, int depth, int *next_index ) {
    int idx = ( *next_index )++;
    int pc, i;

    DumpHeader( out, p, idx, depth );
    for ( pc = 0; pc < p->sizecode; pc++ ) {
        DumpInst( out, p, pc );
    }
    for ( i = 0; i < p->sizep; i++ ) {
        if ( p->p[ i ] != NULL ) {
            fputc( '\n', out );
            if ( !WalkProto( out, p->p[ i ], depth + 1, next_index ) ) return 0;
        }
    }
    return 1;
}

int Lc_DumpBytecode( FILE *out, Proto *root ) {
    int next = 0;
    if ( out == NULL || root == NULL ) return 0;
    fputs( "; bytecode dump (Lua 5.4)\n", out );
    return WalkProto( out, root, 0, &next );
}
