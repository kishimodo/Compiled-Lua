#include "jit/regalloc.h"

#include "lopcodes.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Bookkeeping for use counts during analysis. */
typedef struct {
    int LuaReg;
    int UseCount;
} REG_USE_T;

/* Conservatively bump use count for every register-position in every opcode
   that reads/writes Lua registers. Doesn't distinguish read vs write — we
   just want a heuristic for "which regs are hot". */
static void BumpUse( REG_USE_T *Uses, int LuaReg ) {
    if ( LuaReg < 0 || LuaReg >= REGALLOC_MAX_LUA_REGS ) return;
    Uses[ LuaReg ].UseCount++;
}

/*!
 * @brief
 *  Conservatively count register references in one instruction. May
 *  over-count (e.g. for OP_LOADI's sBx which isn't a register), but
 *  the count is just a popularity metric — over-counting is harmless.
 */
static void AnalyseOpcode( Instruction Ins, REG_USE_T *Uses ) {
    int Op = GET_OPCODE( Ins );
    BumpUse( Uses, GETARG_A( Ins ) );
    switch ( Op ) {
        case OP_LOADI: case OP_LOADF: case OP_LOADK: case OP_LOADKX:
        case OP_LOADTRUE: case OP_LOADFALSE: case OP_LFALSESKIP:
        case OP_LOADNIL:
            /* Only A is a register operand. */
            break;
        default:
            /* Count B, C as register references (some are constants — OK). */
            BumpUse( Uses, GETARG_B( Ins ) );
            BumpUse( Uses, GETARG_C( Ins ) );
            break;
    }
}

static int CompareByUseDesc( const void *A, const void *B ) {
    const REG_USE_T *Ua = ( const REG_USE_T * )A;
    const REG_USE_T *Ub = ( const REG_USE_T * )B;
    if ( Ub->UseCount != Ua->UseCount ) return Ub->UseCount - Ua->UseCount;
    return Ua->LuaReg - Ub->LuaReg;  /* stable tiebreak */
}

int RegAlloc_Analyse( PREGALLOC_T R, Proto *P ) {
    REG_USE_T Uses[ REGALLOC_MAX_LUA_REGS ] = { 0 };
    int       I = { 0 };
    int       NumLuaRegs = P->maxstacksize;

    if ( NumLuaRegs > REGALLOC_MAX_LUA_REGS ) {
        fprintf( stderr, "[-] regalloc: Proto has %d Lua regs (max %d)\n",
                 NumLuaRegs, REGALLOC_MAX_LUA_REGS );
        return 0;
    }

    /* The 5 callee-saved x64 GPRs we use as cache slots, in slot order. */
    R->CachePool[ 0 ] = X64_R12;
    R->CachePool[ 1 ] = X64_R13;
    R->CachePool[ 2 ] = X64_R14;
    R->CachePool[ 3 ] = X64_R15;
    R->CachePool[ 4 ] = X64_RSI;

    /* Default: every Lua reg lives in memory only (X64_RAX as sentinel). */
    for ( I = 0; I < REGALLOC_MAX_LUA_REGS; I++ ) {
        R->CacheReg[ I ] = X64_RAX;
    }
    for ( I = 0; I < REGALLOC_NUM_CACHE_REGS; I++ ) {
        R->CacheSlotLuaReg[ I ] = -1;
    }

    /* Initialise use counts. */
    for ( I = 0; I < NumLuaRegs; I++ ) {
        Uses[ I ].LuaReg   = I;
        Uses[ I ].UseCount = 0;
    }

    /* Analyse bytecode. */
    for ( I = 0; I < P->sizecode; I++ ) {
        AnalyseOpcode( P->code[ I ], Uses );
    }

    /* Sort by descending use count. */
    qsort( Uses, ( size_t )NumLuaRegs, sizeof( REG_USE_T ), CompareByUseDesc );

    /* Assign the top N to cache slots. */
    int NumToCache = ( NumLuaRegs < REGALLOC_NUM_CACHE_REGS )
                      ? NumLuaRegs : REGALLOC_NUM_CACHE_REGS;
    /* Don't cache regs with zero uses. */
    while ( NumToCache > 0 && Uses[ NumToCache - 1 ].UseCount == 0 ) NumToCache--;

    for ( I = 0; I < NumToCache; I++ ) {
        int       LuaReg = Uses[ I ].LuaReg;
        X64_GPR_T XReg   = R->CachePool[ I ];
        R->CacheReg[ LuaReg ]     = XReg;
        R->CacheSlotLuaReg[ I ]   = LuaReg;
    }
    R->NumCached = NumToCache;
    return 1;
}

int RegAlloc_IsCached( PREGALLOC_T R, int LuaReg, X64_GPR_T *OutXReg ) {
    if ( LuaReg < 0 || LuaReg >= REGALLOC_MAX_LUA_REGS ) return 0;
    if ( R->CacheReg[ LuaReg ] == X64_RAX ) return 0;  /* sentinel "no cache" */
    if ( OutXReg != NULL ) {
        *OutXReg = R->CacheReg[ LuaReg ];
    }
    return 1;
}
