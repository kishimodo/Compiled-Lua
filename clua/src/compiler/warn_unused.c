/* warn_unused.c -- see warn_unused.h.
 *
 * Uses Proto's DebugInfo (locvars[] + code[]) to flag "written but never read"
 * local variables. The scanner only inspects, never mutates -- codegen is
 * unaffected. Every unused local still gets assigned; the warning is purely
 * advisory.
 *
 * Slot lifetime model
 * -------------------
 * `LocVar.startpc..endpc` gives the pc range where a slot IS a named local
 * (Lua's own ldebug varinfo semantics). Reads/writes to the same register
 * outside that range belong to a DIFFERENT variable that reused the slot --
 * the scanner ignores those, which is why nested loops re-using r0 don't
 * false-positive on each other.
 *
 * A single register may host several LocVars over disjoint pc ranges; each is
 * scored independently. Two LocVars sharing a slot at the SAME pc would be a
 * bytecode invariant violation (the Lua compiler emits at most one per slot
 * per pc), so we don't guard against it.
 *
 * Upvalue capture as a read
 * -------------------------
 * When an outer local ends up in an inner closure's upvalue list, the outer
 * function contains an OP_CLOSURE at some pc. The inner proto's
 * `upvalues[j].instack == 1` means "captured from the enclosing function's
 * register `upvalues[j].idx`". At the OP_CLOSURE pc that register IS the
 * local slot we're scoring, so we count that as a read of the slot. Without
 * this rule
 *     local x = 1
 *     local function inner() return x end
 * would warn on `x` -- it's never read by an OP_MOVE/arith in the outer body,
 * only captured. Which is the archetypal false positive to avoid.
 */
#include "compiler/warn_unused.h"
#include "compiler/diag_pretty.h"

#include "lua.h"
#include "lobject.h"
#include "lopcodes.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* ---- category name registry --------------------------------------------
 * One entry per LcWarnCategory. LCWARN_CAT_COUNT gates the array's length; a
 * missing entry becomes a link-time array-bounds error rather than a runtime
 * "" surprise. */
static const char *const kCatNames[ LCWARN_CAT_COUNT ] = {
    /* LCWARN_CAT_UNUSED */ "unused",
};

const char *LcWarn_CategoryName( int cat_id ) {
    if ( cat_id < 0 || cat_id >= LCWARN_CAT_COUNT ) return "";
    return kCatNames[ cat_id ];
}

int LcWarn_CategoryFromName( const char *name ) {
    int i;
    if ( name == NULL ) return -1;
    for ( i = 0; i < LCWARN_CAT_COUNT; i++ ) {
        if ( strcmp( kCatNames[ i ], name ) == 0 ) return i;
    }
    return -1;
}

/* Apply a category id (on/off) to the flags block. Keeps the "which bool"
 * mapping in ONE place so adding a category tomorrow means editing here plus
 * kCatNames[] and LcWarnFlags. */
static void SetCategory( LcWarnFlags *W, int cat_id, bool enable ) {
    switch ( cat_id ) {
        case LCWARN_CAT_UNUSED: W->unused = enable; return;
        default: return;
    }
}

/* Enable EVERY category (used by -Wall). Same one-place-per-category rule as
 * SetCategory above. */
static void EnableAll( LcWarnFlags *W ) {
    W->unused = true;
}

int LcWarn_ParseFlag( LcWarnFlags *W, const char *tok ) {
    if ( W == NULL || tok == NULL ) return 0;
    if ( strcmp( tok, "all" ) == 0 ) {
        EnableAll( W );
        return 1;
    }
    if ( strcmp( tok, "error" ) == 0 ) {
        W->werror_all = true;
        return 1;
    }
    if ( strncmp( tok, "error=", 6 ) == 0 ) {
        int id = LcWarn_CategoryFromName( tok + 6 );
        if ( id < 0 ) {
            fprintf( stderr, "clua: warning: unknown -Werror category '%s'\n",
                     tok + 6 );
            return 0;
        }
        W->werror_bits |= LCWARN_BIT( id );
        return 1;
    }
    if ( strncmp( tok, "no-", 3 ) == 0 ) {
        int id = LcWarn_CategoryFromName( tok + 3 );
        if ( id < 0 ) {
            fprintf( stderr, "clua: warning: unknown -Wno- category '%s'\n",
                     tok + 3 );
            return 0;
        }
        SetCategory( W, id, false );
        return 1;
    }
    {
        int id = LcWarn_CategoryFromName( tok );
        if ( id < 0 ) {
            fprintf( stderr, "clua: warning: unknown -W category '%s'\n", tok );
            return 0;
        }
        SetCategory( W, id, true );
    }
    return 1;
}

/* ---- Proto scanning -----------------------------------------------------
 * Per-slot READ/WRITTEN booleans over the LocVar's live pc range. `read`
 * shortcircuits the scan as soon as any op consumes the slot as a source
 * operand -- we don't need to count reads, just prove ONE exists.
 *
 * The "written" bit is set only when the slot is the target of an op that
 * actually assigns a value (OP_MOVE, OP_LOAD*, OP_GETUPVAL, arithmetic,
 * OP_NEWTABLE, ...). Ops that mention slot A but don't produce a value TO it
 * (OP_JMP, OP_TEST, OP_TESTSET-as-consumer, OP_CLOSE, OP_TBC, comparison ops)
 * don't count -- treating them as writes would make every `local x = tbl; if
 * x then ... end` silently unused. If the local is never even written we
 * cannot say it's "written but never read"; skip it too.
 *
 * Ranges use half-open [startpc, endpc): Lua's compiler stores endpc as the
 * first pc where the variable is DEAD (see the LocVar comment). Comparing
 * with `<` matches ldebug's own varinfo walker. */

/* Return 1 if opcode `op` writes to register A (produces a value into it). */
static int OpcodeWritesA( OpCode op ) {
    switch ( op ) {
        case OP_MOVE:
        case OP_LOADI:
        case OP_LOADF:
        case OP_LOADK:
        case OP_LOADKX:
        case OP_LOADFALSE:
        case OP_LFALSESKIP:
        case OP_LOADTRUE:
        case OP_LOADNIL:      /* R[A]..R[A+B] := nil -- handled specially */
        case OP_GETUPVAL:
        case OP_GETTABUP:
        case OP_GETTABLE:
        case OP_GETI:
        case OP_GETFIELD:
        case OP_NEWTABLE:
        case OP_SELF:         /* also writes A+1, handled specially      */
        case OP_ADDI:
        case OP_ADDK: case OP_SUBK: case OP_MULK: case OP_MODK:
        case OP_POWK: case OP_DIVK: case OP_IDIVK:
        case OP_BANDK: case OP_BORK: case OP_BXORK:
        case OP_SHRI: case OP_SHLI:
        case OP_ADD: case OP_SUB: case OP_MUL: case OP_MOD:
        case OP_POW: case OP_DIV: case OP_IDIV:
        case OP_BAND: case OP_BOR: case OP_BXOR:
        case OP_SHL: case OP_SHR:
        case OP_UNM: case OP_BNOT: case OP_NOT: case OP_LEN:
        case OP_CONCAT:
        case OP_CLOSURE:
        case OP_VARARG:
            return 1;
        default:
            return 0;
    }
}

/* Return 1 if opcode `op` reads register operands as B and/or C. The scan
 * uses this to decide whether "slot == B" or "slot == C" counts as a read. */
static void OpcodeReadBC( OpCode op, int *reads_B, int *reads_C ) {
    *reads_B = 0; *reads_C = 0;
    switch ( op ) {
        /* iABC: R[B] source; C may be K or R -- err on the side of "read"
         * only when C is actually a register operand. Most B/C-reg ops read
         * both B and C, arithmetic *K forms read only B. */
        case OP_MOVE:
        case OP_UNM: case OP_BNOT: case OP_NOT: case OP_LEN:
            *reads_B = 1; return;

        case OP_GETUPVAL:              /* B = upvalue slot, not a register    */
        case OP_LOADK: case OP_LOADKX:
        case OP_LOADI: case OP_LOADF:
        case OP_LOADFALSE: case OP_LFALSESKIP: case OP_LOADTRUE:
        case OP_LOADNIL:
        case OP_NEWTABLE:              /* B is log2 hash size, C array size    */
        case OP_CLOSURE:               /* Bx is proto idx                      */
        case OP_VARARG: case OP_VARARGPREP:
        case OP_JMP: case OP_EXTRAARG:
            return;

        /* GETI: R[A] := R[B][C]   -- B is a register read.                  */
        case OP_GETI:
            *reads_B = 1; return;

        /* GETFIELD, GETTABUP: R[A] := R[B][K[C]]. B for GETFIELD is a reg;
         * B for GETTABUP is an UPVALUE index, so don't treat that as a slot. */
        case OP_GETFIELD:
            *reads_B = 1; return;
        case OP_GETTABUP:
            return;

        case OP_GETTABLE:              /* R[A] := R[B][R[C]]                  */
            *reads_B = 1; *reads_C = 1; return;

        /* SET*: A is the TABLE register (read), B is key, C is value.        */
        case OP_SETTABUP:              /* A = upvalue idx, not register       */
            return;
        case OP_SETTABLE:              /* R[A][R[B]] := RK(C)                 */
        case OP_SETI:                  /* R[A][B] := RK(C)                    */
        case OP_SETFIELD:              /* R[A][K[B]] := RK(C)                 */
            /* A is a register read here. We can't mark A read from this
             * helper because we only return B/C flags -- see the special-
             * case block in the main loop. */
            return;

        case OP_SELF:                  /* R[A]=R[B][K[C]]; R[A+1]=R[B]        */
            *reads_B = 1; return;

        /* Immediate/K arith: B is register, C is constant or immediate.      */
        case OP_ADDI:
        case OP_ADDK: case OP_SUBK: case OP_MULK: case OP_MODK:
        case OP_POWK: case OP_DIVK: case OP_IDIVK:
        case OP_BANDK: case OP_BORK: case OP_BXORK:
        case OP_SHRI: case OP_SHLI:
            *reads_B = 1; return;

        /* Reg-reg arith and bitwise.                                          */
        case OP_ADD: case OP_SUB: case OP_MUL: case OP_MOD:
        case OP_POW: case OP_DIV: case OP_IDIV:
        case OP_BAND: case OP_BOR: case OP_BXOR:
        case OP_SHL: case OP_SHR:
            *reads_B = 1; *reads_C = 1; return;

        case OP_MMBIN:
            *reads_B = 1; return;      /* metamethod dispatch reads B         */
        case OP_MMBINI: case OP_MMBINK:
            return;                    /* sB / K[B]                           */

        case OP_CONCAT:                /* R[A] := R[A]..R[A+1]..R[A+B-1]     */
            return;                    /* handled via A-range read below      */

        /* Control-flow / comparisons -- handled in the main loop via specific
         * A/B reads (they don't fit the "reads B, reads C" pattern here).   */
        case OP_EQ: case OP_LT: case OP_LE:
            *reads_B = 1; return;      /* A is also read; special-cased below */
        case OP_EQK:
        case OP_EQI: case OP_LTI: case OP_LEI: case OP_GTI: case OP_GEI:
            return;                    /* only A is a register                */

        case OP_TEST:                  /* A is read                            */
            return;
        case OP_TESTSET:               /* R[A] := R[B] if cond                 */
            *reads_B = 1; return;

        case OP_CALL:                  /* R[A]..R[A+B-1] read                  */
        case OP_TAILCALL:
        case OP_RETURN: case OP_RETURN1:
        case OP_SETLIST:               /* R[A]..R[A+B] read                    */
            return;                    /* handled via A-range read below      */

        case OP_RETURN0:
            return;

        case OP_FORLOOP: case OP_FORPREP:
        case OP_TFORPREP: case OP_TFORCALL: case OP_TFORLOOP:
            return;                    /* control operates on A slot range     */

        case OP_CLOSE: case OP_TBC:
            return;                    /* not a read                           */

        default:
            return;
    }
}

/* Special-case ops that read A as a register (setters, comparisons, tests).
 * Range reads (R[A]..R[A+k-1] for CALL/RETURN/CONCAT/FOR*) are handled by
 * OpcodeAReadCount below; this helper only lists ops where the single register
 * A is a source operand. OP_SELF and OP_CLOSE / OP_TBC are deliberately absent:
 * SELF writes A (and A+1) but does not read A; CLOSE / TBC name A only as the
 * target of a scope-boundary marker, not as a value read. */
static int OpcodeReadsA( OpCode op ) {
    switch ( op ) {
        case OP_SETTABLE: case OP_SETI: case OP_SETFIELD:
        case OP_EQ: case OP_LT: case OP_LE:
        case OP_EQK: case OP_EQI:
        case OP_LTI: case OP_LEI: case OP_GTI: case OP_GEI:
        case OP_TEST: case OP_TESTSET:
        case OP_MMBIN: case OP_MMBINI: case OP_MMBINK:  /* call MM over R[A] */
        case OP_SETUPVAL:                               /* UpValue[B] := R[A] */
            return 1;
        default:
            return 0;
    }
}

/* Extract the "read range" for ops whose operands are R[A]..R[A+k-1] rather
 * than a single A. Returns the count k (0 if the op doesn't have one). Only
 * A is the base; the actual set of read slots is [A, A + count). */
static int OpcodeAReadCount( OpCode op, Instruction ins ) {
    int B = GETARG_B( ins );
    switch ( op ) {
        case OP_CALL:      /* R[A]..R[A+B-1] read (B==0 => up to top)         */
        case OP_TAILCALL:
            return ( B > 0 ) ? B : 1;
        case OP_RETURN:    /* R[A]..R[A+B-2] read (B==0 => up to top)         */
            return ( B > 0 ) ? B - 1 : 1;
        case OP_RETURN1:   /* R[A] read                                        */
            return 1;
        case OP_SETLIST:   /* R[A]..R[A+B] read                                */
            return ( B > 0 ) ? B + 1 : 1;
        case OP_CONCAT:    /* R[A]..R[A+B-1] read                              */
            return ( B > 0 ) ? B : 1;
        case OP_TFORCALL:  /* R[A]..R[A+3] read                                */
            return 4;
        case OP_TFORLOOP:  /* R[A+2] read, R[A] written                        */
            return 3;
        case OP_FORLOOP: case OP_FORPREP:
            return 4;      /* R[A]..R[A+3] loop state                          */
        default:
            return 0;
    }
}

/* Also flag OP_LOADNIL A..A+B as a write to the slot range. */
static int OpcodeAWriteCount( OpCode op, Instruction ins ) {
    switch ( op ) {
        case OP_LOADNIL:   return GETARG_B( ins ) + 1;
        case OP_SELF:      return 2;   /* A and A+1                            */
        case OP_VARARG: {
            int C = GETARG_C( ins );
            return ( C > 0 ) ? C - 1 : 1;
        }
        default:           return 0;
    }
}

/* Line for pc, mirroring luaG_getfuncline: pick the greatest abslineinfo
 * anchor <= pc (or fall back to P->linedefined), then walk lineinfo deltas
 * forward. ABSLINEINFO sentinel positions are the anchor pcs themselves and
 * the walker starts one past the anchor, so we never add the sentinel value.
 * Returns P->linedefined when no debug info is present. */
static int LineAtPc( const Proto *P, int pc ) {
    int base_line = P->linedefined;
    int base_pc   = -1;
    int cur_line;
    int i;
    if ( P->abslineinfo != NULL && P->sizeabslineinfo > 0 ) {
        for ( i = 0; i < P->sizeabslineinfo; i++ ) {
            if ( P->abslineinfo[ i ].pc <= pc &&
                 P->abslineinfo[ i ].pc > base_pc ) {
                base_pc   = P->abslineinfo[ i ].pc;
                base_line = P->abslineinfo[ i ].line;
            }
        }
    }
    cur_line = base_line;
    if ( P->lineinfo == NULL ) return cur_line;
    /* Walk from just after the anchor (or from pc 0 if no anchor was <= pc).
     * lineinfo entries are signed 1-byte deltas; -0x80 (ABSLINEINFO) is only
     * seen at anchor pcs, which the walker skips over. */
    for ( i = base_pc + 1; i <= pc && i < P->sizelineinfo; i++ ) {
        ls_byte d = P->lineinfo[ i ];
        if ( ( int )d == -128 /* ABSLINEINFO */ ) continue;
        cur_line += ( int )d;
    }
    return cur_line;
}

/* Slurp a text file into a heap buffer. Free with free(). NULL on any I/O
 * error (the diagnostic still prints -- the snippet + caret rows are just
 * omitted). Kept local so we don't pull in diag.c's Diag_SlurpFile signature. */
static char *SlurpText( const char *path, size_t *out_len ) {
    FILE  *f;
    long   n;
    char  *buf;
    size_t got;
    if ( path == NULL ) return NULL;
    f = fopen( path, "rb" );
    if ( f == NULL ) return NULL;
    if ( fseek( f, 0, SEEK_END ) != 0 ) { fclose( f ); return NULL; }
    n = ftell( f );
    if ( n < 0 ) { fclose( f ); return NULL; }
    rewind( f );
    buf = ( char * )malloc( ( size_t )n + 1 );
    if ( buf == NULL ) { fclose( f ); return NULL; }
    got = fread( buf, 1, ( size_t )n, f );
    fclose( f );
    if ( got != ( size_t )n ) { free( buf ); return NULL; }
    buf[ n ] = '\0';
    if ( out_len ) *out_len = ( size_t )n;
    return buf;
}

/* Copy 1-based `line` of `text` into `out` (no newline). Returns the
 * copied length, or -1 if the line is out of range. */
static int GetSourceLine( const char *text, int line, char *out, size_t out_size ) {
    int         cur = 1;
    const char *p   = text;
    size_t      i   = 0;
    if ( text == NULL || line < 1 ) return -1;
    while ( cur < line && *p != '\0' ) {
        if ( *p == '\n' ) cur++;
        p++;
    }
    if ( cur != line ) return -1;
    while ( p[ i ] != '\0' && p[ i ] != '\n' && i + 1 < out_size ) {
        out[ i ] = ( p[ i ] == '\r' ) ? ' ' : p[ i ];
        i++;
    }
    out[ i ] = '\0';
    return ( int )i;
}

/* Locate the local's name inside the source line so the caret points at the
 * declaration, not column 1. Returns 1-based column, or 1 when the name isn't
 * on that line (typical for multi-line `local x =\n  <expr>`). */
static int FindNameColumn( const char *line, const char *name ) {
    size_t nlen;
    const char *p;
    if ( line == NULL || name == NULL ) return 1;
    nlen = strlen( name );
    if ( nlen == 0 ) return 1;
    for ( p = line; *p != '\0'; p++ ) {
        if ( strncmp( p, name, nlen ) == 0 ) {
            /* Word-boundary check: don't match `xy` inside `xyz`.            */
            char prev = ( p == line ) ? ' ' : p[ -1 ];
            char next = p[ nlen ];
            int  prev_id = ( prev == '_' ||
                             ( prev >= 'a' && prev <= 'z' ) ||
                             ( prev >= 'A' && prev <= 'Z' ) ||
                             ( prev >= '0' && prev <= '9' ) );
            int  next_id = ( next == '_' ||
                             ( next >= 'a' && next <= 'z' ) ||
                             ( next >= 'A' && next <= 'Z' ) ||
                             ( next >= '0' && next <= '9' ) );
            if ( !prev_id && !next_id ) {
                return ( int )( p - line ) + 1;
            }
        }
    }
    return 1;
}

/* Score one Proto. Nested protos recurse at the end. Cached `source_text` is
 * shared across the whole tree because every nested Proto came from the same
 * source file (Lua's compiler assigns Proto->source uniformly within a file). */
static void ScanProto( const Proto *P, const char *source_path,
                       const char *source_text,
                       bool werror, int *fatal_out ) {
    int i, pc;
    if ( P == NULL || P->locvars == NULL || P->sizelocvars <= 0 ) goto recurse;
    if ( P->code == NULL || P->sizecode <= 0 )                    goto recurse;

    for ( i = 0; i < P->sizelocvars; i++ ) {
        const LocVar *lv = &P->locvars[ i ];
        const char   *name;
        int           slot = i;            /* NOT the register; see below     */
        int           read = 0, written = 0;
        int           startpc, endpc;

        /* locvars[] is indexed by DECLARATION order, not by register.
         * At any given pc the ACTIVE locvars (those with startpc<=pc<endpc)
         * are the ones occupying registers 0..n-1 in the order they appear
         * in locvars[]. So the register for locvars[i] at pc is not i in
         * general; it is the count of active locvars strictly before this
         * one. Compute it once at startpc, then reuse for the whole range. */
        if ( lv->varname == NULL ) continue;
        name = getstr( lv->varname );
        if ( name == NULL || name[ 0 ] == '\0' ) continue;
        if ( name[ 0 ] == '_' ) continue;   /* intentional-unused convention   */
        /* Skip compiler-synthesized locals whose name starts with '(' --
         * for-loop state ((for state), (for control), (for generator)),
         * to-be-closed markers, etc. */
        if ( name[ 0 ] == '(' ) continue;

        /* Determine the register: count LocVars whose live range contains
         * lv->startpc AND that are declared BEFORE lv in the locvars list. */
        {
            int j;
            slot = 0;
            for ( j = 0; j < i; j++ ) {
                const LocVar *o = &P->locvars[ j ];
                if ( o->startpc <= lv->startpc && lv->startpc < o->endpc ) {
                    slot++;
                }
            }
        }

        startpc = lv->startpc;
        endpc   = lv->endpc;
        if ( endpc > P->sizecode ) endpc = P->sizecode;
        if ( startpc < 0 ) startpc = 0;

        /* Special case: for loop variables (`for i = 1,10 do ... end`) live
         * BEFORE their startpc in the OP_FORPREP setup. The Lua compiler
         * emits FORPREP at startpc-1 with A being the base register of the
         * loop state, and the visible loop variable is written by FORLOOP
         * at every iteration. Rather than encode all that, we treat locals
         * whose declaring op is OP_FORPREP/OP_TFORPREP as always-used --
         * they're the induction variable, definitionally read.
         *
         * Detect: the instruction at startpc-1 (if valid) is FORLOOP/FORPREP
         * or a TFOR variant; skip. */
        if ( startpc >= 1 ) {
            OpCode prev = GET_OPCODE( P->code[ startpc - 1 ] );
            if ( prev == OP_FORPREP || prev == OP_FORLOOP ||
                 prev == OP_TFORPREP || prev == OP_TFORCALL ||
                 prev == OP_TFORLOOP ) {
                continue;
            }
        }

        /* Peek at the initializer. Lua's parser sets LocVar.startpc to the pc
         * AFTER the initializing instruction (registerlocalvar in lparser.c
         * runs after luaK emits the store into the slot). Without this peek
         * the very first write -- `local x = 42` -- is one pc BEFORE our scan
         * window and we'd never see it, silently missing the whole point of
         * "written but never read".
         *
         * For a `local a, b, c = 1, 2, 3` group every var shares the same
         * startpc (adjustlocalvars activates them together AFTER all stores),
         * so a single startpc-1 peek would only catch the LAST store. We walk
         * backwards a bounded window, stopping at the first slot-write we
         * find or at a control-flow / call boundary that would mean an
         * earlier statement. `stop_at` is our floor: never step past pc 0,
         * never past the previous LocVar's endpc on the same slot, never
         * past a suspiciously old pc (a `local` group of 32+ vars is
         * pathological; a walk of that depth would just add noise). */
        {
            int stop_at = 0;
            int back;
            int limit_lo;
            int j;
            /* Never cross a previous LocVar with the same register. */
            for ( j = 0; j < P->sizelocvars; j++ ) {
                const LocVar *o = &P->locvars[ j ];
                int           o_slot;
                int           k;
                if ( o == lv ) continue;
                if ( o->endpc > lv->startpc ) continue;  /* not before us     */
                /* Compute o's register the same way we compute slot for lv.  */
                o_slot = 0;
                for ( k = 0; k < P->sizelocvars; k++ ) {
                    const LocVar *q = &P->locvars[ k ];
                    if ( q == o ) break;
                    if ( q->startpc <= o->startpc &&
                         o->startpc < q->endpc ) {
                        o_slot++;
                    }
                }
                if ( o_slot == slot && o->endpc > stop_at ) stop_at = o->endpc;
            }
            limit_lo = stop_at;
            if ( startpc - limit_lo > 32 ) limit_lo = startpc - 32;
            for ( back = startpc - 1; back >= limit_lo; back-- ) {
                Instruction ins = P->code[ back ];
                OpCode      op  = GET_OPCODE( ins );
                int         A   = GETARG_A( ins );
                int         wcount;
                if ( OpcodeWritesA( op ) && A == slot ) { written = 1; break; }
                wcount = OpcodeAWriteCount( op, ins );
                if ( wcount > 0 && slot >= A && slot < A + wcount ) {
                    written = 1; break;
                }
            }
        }

        for ( pc = startpc; pc < endpc; pc++ ) {
            Instruction ins = P->code[ pc ];
            OpCode      op  = GET_OPCODE( ins );
            int         A   = GETARG_A( ins );
            int         B   = GETARG_B( ins );
            int         C   = GETARG_C( ins );
            int         readB = 0, readC = 0;
            int         acount, wcount;

            /* Writes -- single A slot. */
            if ( OpcodeWritesA( op ) && A == slot ) {
                written = 1;
            }
            /* Writes -- A..A+count-1 (LOADNIL / VARARG / SELF). */
            wcount = OpcodeAWriteCount( op, ins );
            if ( wcount > 0 && slot >= A && slot < A + wcount ) {
                written = 1;
            }
            /* Reads -- B / C register operands. */
            OpcodeReadBC( op, &readB, &readC );
            if ( readB && B == slot ) { read = 1; break; }
            if ( readC && C == slot ) { read = 1; break; }
            /* Reads -- single A slot (setters, tests, comparisons). */
            if ( OpcodeReadsA( op ) && A == slot ) { read = 1; break; }
            /* Reads -- A..A+count-1 (call / return / concat / for-family). */
            acount = OpcodeAReadCount( op, ins );
            if ( acount > 0 && slot >= A && slot < A + acount ) {
                read = 1; break;
            }
        }

        /* Capture-as-upvalue counts as a read. Walk every nested proto's
         * upvalues[]; each `instack=1` entry captures upvalues[j].idx from
         * this Proto's register at the corresponding OP_CLOSURE pc. If
         * that pc is inside our slot's range and idx matches, mark read. */
        if ( !read ) {
            int k;
            for ( k = 0; k < P->sizecode && !read; k++ ) {
                Instruction ins = P->code[ k ];
                OpCode      op  = GET_OPCODE( ins );
                int         Bx;
                const Proto *sub;
                int         j;
                if ( op != OP_CLOSURE ) continue;
                if ( k < startpc || k >= endpc ) continue;
                Bx = GETARG_Bx( ins );
                if ( Bx < 0 || Bx >= P->sizep )     continue;
                sub = P->p[ Bx ];
                if ( sub == NULL || sub->upvalues == NULL ) continue;
                for ( j = 0; j < sub->sizeupvalues; j++ ) {
                    if ( sub->upvalues[ j ].instack &&
                         sub->upvalues[ j ].idx == slot ) {
                        read = 1;
                        break;
                    }
                }
            }
        }

        if ( written && !read ) {
            char line_buf[ 1024 ] = { 0 };
            char msg[ 256 ];
            int  line = LineAtPc( P, startpc );
            int  have_line = 0;
            int  col       = 1;
            if ( source_text != NULL ) {
                int len = GetSourceLine( source_text, line, line_buf,
                                         sizeof( line_buf ) );
                have_line = ( len >= 0 );
                if ( have_line ) col = FindNameColumn( line_buf, name );
            }
            snprintf( msg, sizeof( msg ),
                      "local '%s' is written but never read", name );
            LcDiag_PrintError( stderr,
                               source_path, line, col,
                               "warning[Wunused]",
                               msg,
                               have_line ? line_buf : NULL );
            if ( werror && fatal_out != NULL ) ( *fatal_out )++;
        }
    }

recurse:
    if ( P == NULL ) return;
    for ( i = 0; i < P->sizep; i++ ) {
        ScanProto( P->p[ i ], source_path, source_text, werror, fatal_out );
    }
}

void LcWarn_ScanUnused( const Proto *P, const char *source_path,
                        bool werror, int *fatal_out ) {
    char  *text = NULL;
    size_t tlen = 0;
    if ( P == NULL ) return;
    text = SlurpText( source_path, &tlen );
    ScanProto( P, source_path, text, werror, fatal_out );
    free( text );
}
