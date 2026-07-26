/* test_lc_ir_verify.c -- the IR verifier accepts real IR and rejects malformed IR.
 *
 * lc_module_verify used to `return true` unconditionally while
 * LcPassConfig.verify_each was declared and set by the driver -- a safety control
 * that only appeared active. Implementing it without a test would reproduce the
 * same defect in a new costume: a verifier nothing exercises is indistinguishable
 * from one that always passes.
 *
 * So this builds a REAL module by lifting a program that covers every checked
 * shape, asserts it verifies clean, and then breaks one invariant at a time --
 * each malformation must be rejected, and with a message.
 */
#include "test_harness.h"
#include "lua.h"
#include "lauxlib.h"
#include "lstate.h"
#include "lobject.h"
#include "ir/ir.h"
#include "ir/lift.h"
#include "opt/passes.h"   /* lc_optimize + LcPassConfig.verify_each */
#include "lopcodes.h"   /* OP_* : the test names the Lua opcodes it looks for */

#include <string.h>
#include <stdlib.h>

/* A program that exercises the operand classes the verifier range-checks:
 * a global call (GETTABUP + CALL), a constant (LOADK), a numeric for
 * (FORPREP/FORLOOP with resolved targets), a nested closure capturing a local
 * (CLOSURE + upvalue indexes + GETUPVAL), and constant-key table access
 * (NEWTABLE/SETFIELD/GETFIELD). */
static const char *PROGRAM =
    "local t = {}\n"
    "t.x = 1\n"
    "local acc = t.x\n"
    "for i = 1, 10 do acc = acc + i end\n"
    "local function bump(n) acc = acc + n return acc end\n"
    "print(bump(2), acc, \"done\")\n";

static LcInst *first_inst( LcFunc *f ) {
    uint32_t bi;
    for ( bi = 0; bi < f->nblocks; bi++ )
        if ( f->blocks[bi]->first ) return f->blocks[bi]->first;
    return NULL;
}

static LcInst *find_bc_op( LcFunc *f, int bc_op ) {
    uint32_t bi;
    LcInst *in;
    for ( bi = 0; bi < f->nblocks; bi++ )
        for ( in = f->blocks[bi]->first; in; in = in->next )
            if ( in->bc_op == bc_op ) return in;
    return NULL;
}

int main( void ) {
    lua_State *L = luaL_newstate();
    Proto *P;
    LcModule *m;
    LcFunc *f;
    char err[256];

    TEST_BEGIN( "lc_ir_verify" );

    CHECK( luaL_loadstring( L, PROGRAM ) == LUA_OK );
    P = ( Proto * )clLvalue( s2v( L->top.p - 1 ) )->p;
    CHECK_NOT_NULL( P );

    m = lc_module_new();
    CHECK_NOT_NULL( m );
    f = lc_func_new( m, P );
    CHECK_NOT_NULL( f );
    m->entry = f;
    lc_lift_func( f );
    CHECK( f->nblocks > 0 );

    /* ---- the positive case: real, freshly lifted IR verifies clean ----
       This is the half that keeps the verifier honest in the other direction:
       an over-strict check would fail here on correct input. */
    err[0] = 'x';
    CHECK_MSG( lc_module_verify( m, err, sizeof err ), err );
    CHECK( err[0] == '\0' );   /* success must clear the buffer */

    /* ---- each malformation must be REJECTED, with a message ---- */

    /* a NULL entry: the module would be optimized and never emitted */
    {
        LcFunc *saved = m->entry;
        m->entry = NULL;
        CHECK( !lc_module_verify( m, err, sizeof err ) );
        CHECK( err[0] != '\0' );
        m->entry = saved;
        CHECK( lc_module_verify( m, err, sizeof err ) );
    }

    /* an entry that is not in funcs[]: same consequence, harder to spot */
    {
        LcFunc *saved = m->entry;
        LcFunc  orphan;
        memset( &orphan, 0, sizeof orphan );
        orphan.source = P;
        orphan.arena  = saved->arena;
        m->entry = &orphan;
        CHECK( !lc_module_verify( m, err, sizeof err ) );
        m->entry = saved;
    }

    /* bc_pc outside the source Proto: codegen indexes PcOff[bc_pc] with it */
    {
        LcInst *in = first_inst( f );
        int saved;
        CHECK_NOT_NULL( in );
        if ( in ) {
            saved = in->bc_pc;
            in->bc_pc = P->sizecode;          /* one past the end */
            CHECK( !lc_module_verify( m, err, sizeof err ) );
            in->bc_pc = -1;
            CHECK( !lc_module_verify( m, err, sizeof err ) );
            in->bc_pc = saved;
            CHECK( lc_module_verify( m, err, sizeof err ) );
        }
    }

    /* two instructions claiming one pc: a branch to it lands on whichever the
       walk saw last, which is not necessarily the one lift intended */
    {
        LcInst *a = first_inst( f );
        if ( a && a->next ) {
            int saved = a->next->bc_pc;
            a->next->bc_pc = a->bc_pc;
            CHECK( !lc_module_verify( m, err, sizeof err ) );
            a->next->bc_pc = saved;
            CHECK( lc_module_verify( m, err, sizeof err ) );
        }
    }

    /* broken next/prev linkage: the optimizer edits with ->prev, codegen walks
       ->next, so a half-updated splice silently drops instructions */
    {
        LcInst *a = first_inst( f );
        if ( a && a->next ) {
            LcInst *saved = a->next->prev;
            a->next->prev = NULL;
            CHECK( !lc_module_verify( m, err, sizeof err ) );
            a->next->prev = saved;
            CHECK( lc_module_verify( m, err, sizeof err ) );
        }
    }

    /* a node from another arena: lc_module_free walks ONE arena's chunks, so
       this is a use-after-free the moment the other module is released */
    {
        LcBlock *blk = f->blocks[0];
        LcArena *saved = blk->arena;
        blk->arena = ( LcArena * )( void * )&err;   /* any other address */
        CHECK( !lc_module_verify( m, err, sizeof err ) );
        blk->arena = saved;
        CHECK( lc_module_verify( m, err, sizeof err ) );
    }

    /* a half-empty instruction list */
    {
        LcBlock *blk = f->blocks[0];
        LcInst *saved = blk->last;
        blk->last = NULL;
        CHECK( !lc_module_verify( m, err, sizeof err ) );
        blk->last = saved;
        CHECK( lc_module_verify( m, err, sizeof err ) );
    }

    /* an out-of-range branch target: lift resolves these into ->c, and a target
       no instruction occupies jumps into the middle of an emitted sequence */
    {
        LcInst *br = find_bc_op( f, OP_FORLOOP );
        if ( !br ) br = find_bc_op( f, OP_FORPREP );
        if ( !br ) br = find_bc_op( f, OP_JMP );
        CHECK_NOT_NULL( br );
        if ( br ) {
            int saved = br->c;
            br->c = P->sizecode + 5;
            CHECK( !lc_module_verify( m, err, sizeof err ) );
            br->c = saved;
            CHECK( lc_module_verify( m, err, sizeof err ) );
        }
    }

    /* a register operand past the frame: reads adjacent stack memory at run time,
       which is the class the OP_SELF k-bit miscompile belonged to */
    {
        LcInst *in = find_bc_op( f, OP_GETFIELD );
        if ( !in ) in = find_bc_op( f, OP_MOVE );
        if ( in ) {
            int saved = in->a;
            in->a = P->maxstacksize;          /* one past the frame */
            CHECK( !lc_module_verify( m, err, sizeof err ) );
            in->a = saved;
            CHECK( lc_module_verify( m, err, sizeof err ) );
        }
    }

    /* a constant index past the pool */
    {
        LcInst *in = find_bc_op( f, OP_LOADK );
        if ( in ) {
            int saved = in->b;
            in->b = P->sizek;
            CHECK( !lc_module_verify( m, err, sizeof err ) );
            in->b = saved;
            CHECK( lc_module_verify( m, err, sizeof err ) );
        }
    }

    /* a CFG edge in memory form: nothing downstream reads preds/succs, so a
       populated edge means an analysis wrote state that is silently ignored */
    {
        LcBlock *blk = f->blocks[0];
        uint16_t saved = blk->nsuccs;
        blk->nsuccs = 1;
        CHECK( !lc_module_verify( m, err, sizeof err ) );
        blk->nsuccs = saved;
        CHECK( lc_module_verify( m, err, sizeof err ) );
    }

    /* a call-graph edge out of range: lc_module_free frees callees[i] per func */
    {
        uint32_t *edges = ( uint32_t * )calloc( 1, sizeof( uint32_t ) );
        uint32_t *ncall = ( uint32_t * )calloc( m->nfuncs, sizeof( uint32_t ) );
        uint32_t **rows = ( uint32_t ** )calloc( m->nfuncs, sizeof( uint32_t * ) );
        if ( edges && ncall && rows ) {
            edges[0] = m->nfuncs + 3;
            rows[0]  = edges;
            ncall[0] = 1;
            m->callees  = rows;
            m->ncallees = ncall;
            CHECK( !lc_module_verify( m, err, sizeof err ) );
            m->callees  = NULL;
            m->ncallees = NULL;
            CHECK( lc_module_verify( m, err, sizeof err ) );
        }
        free( edges ); free( ncall ); free( rows );
    }

    /* a half-built call graph (one array set, the other not) */
    {
        uint32_t *ncall = ( uint32_t * )calloc( m->nfuncs, sizeof( uint32_t ) );
        m->ncallees = ncall;
        CHECK( !lc_module_verify( m, err, sizeof err ) );
        m->ncallees = NULL;
        free( ncall );
        CHECK( lc_module_verify( m, err, sizeof err ) );
    }

    /* NULL module and a module with no functions */
    CHECK( !lc_module_verify( NULL, err, sizeof err ) );
    CHECK( err[0] != '\0' );
    {
        uint32_t saved = m->nfuncs;
        m->nfuncs = 0;
        CHECK( !lc_module_verify( m, err, sizeof err ) );
        m->nfuncs = saved;
        CHECK( lc_module_verify( m, err, sizeof err ) );
    }

    /* ---- the WIRING, not just the checks ----
       Implementing the verifier is only half the defect: verify_each was declared
       and set by the driver while lc_optimize never called it. So assert the
       behaviour that proves it is connected -- a malformed module must make
       lc_optimize FAIL when verify_each is set, and must be tolerated when it is
       not (the flag has to actually gate something). */
    {
        LcPassConfig cfg;
        LcInst *in = first_inst( f );
        int saved;
        CHECK_NOT_NULL( in );
        if ( in ) {
            saved = in->bc_pc;
            in->bc_pc = P->sizecode + 7;      /* malformed */

            memset( &cfg, 0, sizeof cfg );
            cfg.opt_level   = 1;
            cfg.verify_each = true;
            CHECK_MSG( lc_optimize( m, &cfg ) == false,
                       "lc_optimize accepted malformed IR with verify_each set: "
                       "the verifier is implemented but not wired in" );

            memset( &cfg, 0, sizeof cfg );
            cfg.opt_level   = 1;
            cfg.verify_each = false;
            CHECK_MSG( lc_optimize( m, &cfg ) == true,
                       "verify_each=false still rejected the module: the flag "
                       "does not gate verification" );

            in->bc_pc = saved;
            CHECK( lc_module_verify( m, err, sizeof err ) );
        }
    }

    lc_module_free( m );
    lua_close( L );
    TEST_END();
}
