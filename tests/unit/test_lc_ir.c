#include "test_harness.h"
#include "ir/ir.h"

int main( void ) {
    LcModule *m;
    LcFunc *f;
    LcBlock *blk;
    LcInst *i1, *i2;

    TEST_BEGIN( "lc_ir" );

    m = lc_module_new();
    CHECK( m != NULL );

    f = lc_func_new( m, NULL );          /* NULL Proto ok: builders don't deref source in M0 */
    CHECK( f != NULL );
    CHECK( m->nfuncs == 1 && m->funcs[0] == f );
    CHECK( f->is_ssa == 0 );

    blk = lc_block_new( f );
    CHECK( blk != NULL && f->nblocks == 1 );

    i1 = lc_emit_bc( blk, LC_OP_GLOBAL_GET, 1, 0, 2, 0 );
    i2 = lc_emit_bc( blk, LC_OP_RETURN, 0, 1, 0, 1 );
    CHECK( i1 != NULL && i2 != NULL );
    CHECK( blk->first == i1 && blk->last == i2 );
    CHECK( i1->next == i2 && i2->prev == i1 );
    CHECK( i1->a == 1 && i1->c == 2 && i1->bc_pc == 0 );
    CHECK( i2->op == LC_OP_RETURN );

    lc_module_free( m );

    TEST_END();
}
