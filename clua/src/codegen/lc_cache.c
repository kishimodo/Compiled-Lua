/*
** lc_cache.c -- per-function persistent compilation cache.
**
** Read the header for the invariant. Implementation notes:
**
**   - Hash: 128-bit FNV-1a. Chosen over SHA-256 because (a) collision
**     resistance is not required (an accidental collision would produce
**     wrong code -- but we already assert every input that affects codegen
**     is fed into the hash, and 128 bits of FNV-1a gives ~2^-64 collision
**     probability across all realistic cache populations), and (b) FNV
**     needs no external crypto and its cost is negligible compared to a
**     codegen run. If a later change adds attacker-controlled inputs to
**     the key, upgrade to SHA-256 (the entry format's version field lets
**     old entries be silently rejected on the algorithm change).
**
**   - Determinism: the hash reads only stable, semantic content. Pointers
**     are dereferenced but never used as inputs directly; SSA-value args
**     are keyed by their dense `id`, which is deterministic per function.
**
**   - Concurrency: LcCache_TryLoad / LcCache_Store are called from the
**     per-function codegen body, which the parallel worker pool drives
**     across N threads. Both use per-call stack buffers, no globals, and
**     the store uses a stage-and-rename pattern so a concurrent build of
**     the same key never sees a torn file. Two builds racing to write the
**     SAME key will each publish their own version -- MoveFileEx with
**     REPLACE_EXISTING serializes at the filesystem level.
**
**   - Failure policy: any cache read failure is a MISS (fresh codegen
**     runs), any cache write failure is silently ignored (the build still
**     succeeds; caching is opportunistic). Correctness never depends on
**     the cache; only build time does.
*/
#include "codegen/lc_cache.h"
#include "codegen/codegen.h"
#include "codegen/lc_codebuf.h"
#include "ir/ir.h"
#include "common/version.h"

#include "lobject.h"
#include "lstate.h"      /* gco2ts, needed by tsvalue() in hash_tvalue */

#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#ifdef _WIN32
#include <windows.h>
#include <direct.h>  /* _mkdir */
#include <process.h> /* _getpid */
#include <io.h>
#endif

/* Target triple: baked in per the header contract. If CLua ever cross-
   compiles to a second target, this must become a real per-build value
   plumbed through LcCgCtx. */
#define LC_CACHE_TARGET_TRIPLE "x86_64-pc-windows-msvc"

/* ------------------------------------------------------------------ */
/* 128-bit FNV-1a                                                     */
/*                                                                    */
/* Two 64-bit FNV-1a hashes in parallel, seeded differently, so the   */
/* combined 128-bit output is not just a single 64-bit hash twice.    */
/* (True FNV-1a-128 uses a 128-bit multiplier that is inconvenient    */
/* in C99; the two-seed construction has the same output width and    */
/* is fine for cache-key purposes -- no adversary chooses inputs.)    */
/* ------------------------------------------------------------------ */
typedef struct {
    uint64_t h0;
    uint64_t h1;
} LcHash128;

#define LC_FNV64_OFFSET_0 0xcbf29ce484222325ULL
#define LC_FNV64_OFFSET_1 0x9ae16a3b2f90404fULL   /* CityHash seed; benign */
#define LC_FNV64_PRIME    0x100000001b3ULL

static void hash_init( LcHash128 *H ) {
    H->h0 = LC_FNV64_OFFSET_0;
    H->h1 = LC_FNV64_OFFSET_1;
}

static void hash_bytes( LcHash128 *H, const void *p, size_t n ) {
    const uint8_t *b = ( const uint8_t * )p;
    size_t i;
    for ( i = 0; i < n; i++ ) {
        H->h0 = ( H->h0 ^ b[ i ] ) * LC_FNV64_PRIME;
        H->h1 = ( H->h1 ^ b[ i ] ) * LC_FNV64_PRIME;
    }
}

static void hash_u32( LcHash128 *H, uint32_t v ) {
    /* Little-endian serialisation so cross-endianness would be reproducible
       if CLua ever ran on a big-endian host (it does not today, but the
       cost is one memcpy per field and it removes a footgun). */
    uint8_t buf[ 4 ];
    buf[ 0 ] = ( uint8_t )( v         & 0xff );
    buf[ 1 ] = ( uint8_t )( ( v >> 8  ) & 0xff );
    buf[ 2 ] = ( uint8_t )( ( v >> 16 ) & 0xff );
    buf[ 3 ] = ( uint8_t )( ( v >> 24 ) & 0xff );
    hash_bytes( H, buf, 4 );
}

static void hash_u64( LcHash128 *H, uint64_t v ) {
    uint8_t buf[ 8 ];
    int i;
    for ( i = 0; i < 8; i++ ) buf[ i ] = ( uint8_t )( ( v >> ( i * 8 ) ) & 0xff );
    hash_bytes( H, buf, 8 );
}

static void hash_str( LcHash128 *H, const char *s ) {
    /* Length-prefix so hash("ab" + "c") != hash("a" + "bc"). */
    uint32_t n = ( uint32_t )( s ? strlen( s ) : 0 );
    hash_u32( H, n );
    if ( n > 0 ) hash_bytes( H, s, n );
}

static void hash_finalize_hex( const LcHash128 *H, char *out /* >=33 */ ) {
    static const char hex[] = "0123456789abcdef";
    uint8_t bytes[ 16 ];
    int i;
    for ( i = 0; i < 8; i++ ) bytes[ i ]     = ( uint8_t )( ( H->h0 >> ( i * 8 ) ) & 0xff );
    for ( i = 0; i < 8; i++ ) bytes[ i + 8 ] = ( uint8_t )( ( H->h1 >> ( i * 8 ) ) & 0xff );
    for ( i = 0; i < 16; i++ ) {
        out[ i * 2     ] = hex[ ( bytes[ i ] >> 4 ) & 0xf ];
        out[ i * 2 + 1 ] = hex[   bytes[ i ]        & 0xf ];
    }
    out[ 32 ] = '\0';
}

/* ------------------------------------------------------------------ */
/* Proto / LcInst content serialisation into the hash                 */
/* ------------------------------------------------------------------ */

/* Hash one TValue constant. Only kinds the front-end actually places in a
   Proto's k[] appear here (nil, bool, int, flt, string); anything else is
   an internal invariant break in the front-end (assert-worthy in a debug
   build, treated as an opaque tag byte here). */
static void hash_tvalue( LcHash128 *H, const TValue *k ) {
    int tt = rawtt( k );
    hash_u32( H, ( uint32_t )tt );
    if ( tt == LUA_VNUMINT ) {
        /* signed 64-bit reinterpret; two's complement is the C99 layout. */
        uint64_t u;
        lua_Integer i = ivalue( k );
        memcpy( &u, &i, sizeof( u ) );
        hash_u64( H, u );
    } else if ( tt == LUA_VNUMFLT ) {
        uint64_t u;
        lua_Number n = fltvalue( k );
        memcpy( &u, &n, sizeof( u ) );
        hash_u64( H, u );
    } else if ( ttisstring( k ) ) {
        TString *s = tsvalue( k );
        size_t n = tsslen( s );
        hash_u32( H, ( uint32_t )n );
        if ( n > 0 ) hash_bytes( H, getstr( s ), n );
    }
    /* nil / bool: the tag already distinguished them. */
}

/* Feed the source Proto's codegen-visible content into the hash. Codegen
   reads: sizecode + code[], sizek + k[], numparams, maxstacksize, is_vararg,
   sizeupvalues (for closure capture arity). Everything else on Proto is
   debug info that does not reach the emitter. */
static void hash_source_proto( LcHash128 *H, const Proto *p ) {
    int i;
    if ( p == NULL ) { hash_u32( H, 0xffffffffu ); return; }
    hash_u32( H, ( uint32_t )p->numparams );
    hash_u32( H, ( uint32_t )p->is_vararg );
    hash_u32( H, ( uint32_t )p->maxstacksize );
    hash_u32( H, ( uint32_t )p->sizeupvalues );
    hash_u32( H, ( uint32_t )p->sizecode );
    if ( p->sizecode > 0 && p->code != NULL ) {
        hash_bytes( H, p->code, ( size_t )p->sizecode * sizeof( Instruction ) );
    }
    hash_u32( H, ( uint32_t )p->sizek );
    for ( i = 0; i < p->sizek; i++ ) hash_tvalue( H, &p->k[ i ] );
    /* Upvalue descriptors carry closure-capture semantics that codegen must
       agree with; hash just the (instack, idx) pair per upvalue (kind /
       name are debug-only). */
    for ( i = 0; i < p->sizeupvalues; i++ ) {
        hash_u32( H, ( uint32_t )p->upvalues[ i ].instack );
        hash_u32( H, ( uint32_t )p->upvalues[ i ].idx );
    }
}

/* Feed one LcInst into the hash. Order of fields is stable so a future
   struct-field reordering does not change cache keys (that would be a
   correctness break; this function is the contract). */
static void hash_inst( LcHash128 *H, const LcInst *in ) {
    uint16_t k;
    hash_u32( H, ( uint32_t )in->op );
    hash_u32( H, ( uint32_t )in->sub );
    hash_u32( H, in->flags );
    hash_u32( H, ( uint32_t )in->nargs );
    hash_u32( H, ( uint32_t )in->bc_pc );
    hash_u32( H, ( uint32_t )in->bc_op );
    hash_u32( H, ( uint32_t )in->a );
    hash_u32( H, ( uint32_t )in->b );
    hash_u32( H, ( uint32_t )in->c );
    hash_u32( H, ( uint32_t )in->ret_close );
    hash_u32( H, ( uint32_t )in->known );
    hash_u64( H, in->res_entry_int );
    hash_u64( H, in->res_entry_flt );
    hash_u32( H, ( uint32_t )in->call_ret_ti );
    hash_u32( H, ( uint32_t )in->call_callee );
    /* Args are LcValue*; the only stable identity is `id`. A NULL arg gets
       a sentinel so a shorter args list does not alias a longer one whose
       tail happens to be zeroed. */
    for ( k = 0; k < in->nargs; k++ ) {
        LcValue *v = in->args ? in->args[ k ] : NULL;
        hash_u32( H, v ? v->id : 0xffffffffu );
    }
}

int LcCache_ComputeKey( const LcModule *m, uint32_t i,
                        const LcCgCtx *cg, char *KeyOut ) {
    LcHash128 H;
    LcFunc   *f;
    uint32_t  bi;

    if ( m == NULL || cg == NULL || KeyOut == NULL ) return 0;
    if ( i >= m->nfuncs || m->funcs == NULL ) return 0;
    f = m->funcs[ i ];
    if ( f == NULL ) return 0;

    hash_init( &H );
    /* Header: everything that would change the semantics of the emitter
       across builds. A compiler upgrade, a target retarget, an opt-level
       change, or a slot swap MUST rekey. */
    hash_str ( &H, CLUA_VERSION_STRING );
    hash_str ( &H, LC_CACHE_TARGET_TRIPLE );
    hash_u32 ( &H, ( uint32_t )cg->opt_level );
    /* -g / --debug changes what LcCompiledFunc carries (linfo). Include it in
       the key so a -g build never reads a non-debug cache entry (and vice
       versa) and produces a binary missing the .clualn section. */
    hash_u32 ( &H, ( uint32_t )( cg->emit_line_info ? 1 : 0 ) );
    hash_u32 ( &H, i );

    /* Function-level metadata that codegen reads or bakes into names. */
    hash_str ( &H, f->module_name );
    hash_u32 ( &H, ( uint32_t )f->nargs );
    hash_u32 ( &H, ( uint32_t )f->is_vararg );
    hash_u32 ( &H, ( uint32_t )f->is_ssa );
    hash_u32 ( &H, ( uint32_t )f->ret_type.kind );
    hash_u32 ( &H, f->effect_summary );
    hash_u32 ( &H, ( uint32_t )f->escapes );
    hash_u32 ( &H, ( uint32_t )f->dead );

    /* Source Proto content -- codegen reads instructions and constants
       directly (not just via LcInst). */
    hash_source_proto( &H, f->source );

    /* Instructions, in block RPO order (the same order the emitter walks). */
    hash_u32( &H, f->nblocks );
    for ( bi = 0; bi < f->nblocks; bi++ ) {
        LcBlock *b = f->blocks[ bi ];
        LcInst  *in;
        hash_u32( &H, b ? b->id : 0xffffffffu );
        for ( in = ( b ? b->first : NULL ); in; in = in->next ) hash_inst( &H, in );
        /* Instruction-list terminator so instruction count is not conflatable
           with the neighbouring block's contents. */
        hash_u32( &H, 0xdeadbeefu );
    }

    hash_finalize_hex( &H, KeyOut );
    return 1;
}

/* ------------------------------------------------------------------ */
/* Directory resolution + creation                                    */
/* ------------------------------------------------------------------ */

static int mkdir_p( const char *dir ) {
#ifdef _WIN32
    /* CreateDirectoryA fails with ALREADY_EXISTS which we ignore; any other
       failure is left for the caller to notice via the subsequent open. */
    if ( CreateDirectoryA( dir, NULL ) != 0 ) return 1;
    if ( GetLastError( ) == ERROR_ALREADY_EXISTS ) return 1;
    return 0;
#else
    if ( mkdir( dir, 0700 ) == 0 ) return 1;
    if ( errno == EEXIST ) return 1;
    return 0;
#endif
}

/* Recursive mkdir: create the parent chain of `dir` first (best-effort).
   Only handles the small set of shapes we produce (LOCALAPPDATA/clua/cache,
   XDG_CACHE_HOME/clua). */
static void mkdir_chain( const char *dir ) {
    char buf[ 1024 ];
    size_t n = strlen( dir );
    size_t i;
    if ( n == 0 || n >= sizeof( buf ) ) return;
    memcpy( buf, dir, n + 1 );
    for ( i = 1; i < n; i++ ) {
        if ( buf[ i ] == '/' || buf[ i ] == '\\' ) {
            char sep = buf[ i ];
            buf[ i ] = '\0';
            mkdir_p( buf );
            buf[ i ] = sep;
        }
    }
    mkdir_p( buf );
}

int LcCache_ResolveDir( const char *override_dir, char *OutBuf, size_t OutSize ) {
    const char *xdg;
    const char *local;
    int written = 0;

    if ( OutBuf == NULL || OutSize < 2 ) return 0;

    if ( override_dir != NULL && override_dir[ 0 ] != '\0' ) {
        if ( ( size_t )snprintf( OutBuf, OutSize, "%s", override_dir ) >= OutSize ) return 0;
        written = 1;
    }
    if ( !written ) {
        xdg = getenv( "XDG_CACHE_HOME" );
        if ( xdg != NULL && xdg[ 0 ] != '\0' ) {
            if ( ( size_t )snprintf( OutBuf, OutSize, "%s/clua", xdg ) >= OutSize ) return 0;
            written = 1;
        }
    }
#ifdef _WIN32
    if ( !written ) {
        local = getenv( "LOCALAPPDATA" );
        if ( local != NULL && local[ 0 ] != '\0' ) {
            if ( ( size_t )snprintf( OutBuf, OutSize, "%s\\clua\\cache", local ) >= OutSize ) return 0;
            written = 1;
        }
    }
#else
    if ( !written ) {
        local = getenv( "HOME" );
        if ( local != NULL && local[ 0 ] != '\0' ) {
            if ( ( size_t )snprintf( OutBuf, OutSize, "%s/.cache/clua", local ) >= OutSize ) return 0;
            written = 1;
        }
    }
#endif
    if ( !written ) return 0;
    mkdir_chain( OutBuf );
    return 1;
}

/* ------------------------------------------------------------------ */
/* Entry format helpers                                               */
/* ------------------------------------------------------------------ */

#define LC_CACHE_MAGIC   "CLCO"
#define LC_CACHE_VERSION 1u

static int write_u32( FILE *f, uint32_t v ) {
    uint8_t buf[ 4 ];
    buf[ 0 ] = ( uint8_t )( v         & 0xff );
    buf[ 1 ] = ( uint8_t )( ( v >> 8  ) & 0xff );
    buf[ 2 ] = ( uint8_t )( ( v >> 16 ) & 0xff );
    buf[ 3 ] = ( uint8_t )( ( v >> 24 ) & 0xff );
    return fwrite( buf, 1, 4, f ) == 4;
}

static int read_u32( FILE *f, uint32_t *out ) {
    uint8_t buf[ 4 ];
    if ( fread( buf, 1, 4, f ) != 4 ) return 0;
    *out = ( ( uint32_t )buf[ 0 ]        )
         | ( ( uint32_t )buf[ 1 ] <<  8  )
         | ( ( uint32_t )buf[ 2 ] << 16  )
         | ( ( uint32_t )buf[ 3 ] << 24  );
    return 1;
}

/* Cap on any single length field so a corrupted cache file can't force us
   into a multi-gigabyte malloc. Any legitimate function's emitted code +
   relocs is orders of magnitude under this. */
#define LC_CACHE_MAX_LEN ( 64u * 1024u * 1024u )

static void entry_path( const char *dir, const char *key,
                        char *OutBuf, size_t OutSize ) {
    snprintf( OutBuf, OutSize, "%s%s%s.co", dir,
#ifdef _WIN32
              "\\",
#else
              "/",
#endif
              key );
}

int LcCache_TryLoad( const char *dir, const char *key, uint32_t i,
                     LcCompiledFunc *cf ) {
    char     path[ 1024 ];
    FILE    *f = NULL;
    char     magic[ 4 ];
    uint32_t version = 0;
    uint32_t code_len = 0;
    uint32_t nrelocs = 0;
    uint32_t unwind_len = 0;
    uint8_t *code = NULL;
    LcReloc *relocs = NULL;
    uint8_t *unwind = NULL;
    uint32_t r;
    int      rc = 0;

    if ( dir == NULL || key == NULL || cf == NULL ) return 0;
    entry_path( dir, key, path, sizeof( path ) );

    f = fopen( path, "rb" );
    if ( f == NULL ) return 0;

    if ( fread( magic, 1, 4, f ) != 4 ) goto out;
    if ( memcmp( magic, LC_CACHE_MAGIC, 4 ) != 0 ) goto out;
    if ( !read_u32( f, &version ) || version != LC_CACHE_VERSION ) goto out;

    if ( !read_u32( f, &code_len ) || code_len > LC_CACHE_MAX_LEN ) goto out;
    if ( code_len > 0 ) {
        code = ( uint8_t * )malloc( code_len );
        if ( code == NULL ) goto out;
        if ( fread( code, 1, code_len, f ) != code_len ) goto out;
    }

    if ( !read_u32( f, &nrelocs ) || nrelocs > LC_CACHE_MAX_LEN ) goto out;
    if ( nrelocs > 0 ) {
        relocs = ( LcReloc * )calloc( nrelocs, sizeof( LcReloc ) );
        if ( relocs == NULL ) goto out;
        for ( r = 0; r < nrelocs; r++ ) {
            uint32_t kind, off, sym_len;
            int32_t  addend;
            uint32_t addend_u;
            if ( !read_u32( f, &kind ) ) goto out;
            if ( !read_u32( f, &off ) )  goto out;
            if ( !read_u32( f, &addend_u ) ) goto out;
            memcpy( &addend, &addend_u, sizeof( addend ) );
            if ( !read_u32( f, &sym_len ) ) goto out;
            if ( sym_len >= sizeof( relocs[ r ].symbol ) ) goto out;
            if ( sym_len > 0 && fread( relocs[ r ].symbol, 1, sym_len, f ) != sym_len ) goto out;
            relocs[ r ].symbol[ sym_len ] = '\0';
            relocs[ r ].kind   = ( LcRelocKind )kind;
            relocs[ r ].offset = off;
            relocs[ r ].addend = addend;
        }
    }

    if ( !read_u32( f, &unwind_len ) || unwind_len > LC_CACHE_MAX_LEN ) goto out;
    if ( unwind_len > 0 ) {
        unwind = ( uint8_t * )malloc( unwind_len );
        if ( unwind == NULL ) goto out;
        if ( fread( unwind, 1, unwind_len, f ) != unwind_len ) goto out;
    }

    /* Success: publish and take ownership. */
    cf->code       = code;   code = NULL;
    cf->code_len   = code_len;
    cf->relocs     = relocs; relocs = NULL;
    cf->nrelocs    = nrelocs;
    cf->unwind     = unwind; unwind = NULL;
    cf->unwind_len = unwind_len;
    snprintf( cf->name, sizeof( cf->name ), "luac_fn_%u", ( unsigned )i );
    rc = 1;
out:
    if ( f ) fclose( f );
    free( code );
    free( relocs );
    free( unwind );
    return rc;
}

int LcCache_Store( const char *dir, const char *key,
                   const LcCompiledFunc *cf ) {
    char     final_path[ 1024 ];
    char     stage_path[ 1088 ];
    FILE    *f = NULL;
    uint32_t r;
    int      ok = 0;

    if ( dir == NULL || key == NULL || cf == NULL ) return 0;
    entry_path( dir, key, final_path, sizeof( final_path ) );
    /* Stage in the same directory so the rename is same-volume. Add pid so
       two concurrent builds racing on the same key each get their own stage
       file; the last MoveFileEx wins. */
    snprintf( stage_path, sizeof( stage_path ), "%s.%d.tmp", final_path,
#ifdef _WIN32
              ( int )_getpid( )
#else
              ( int )getpid( )
#endif
            );

    f = fopen( stage_path, "wb" );
    if ( f == NULL ) return 0;

    if ( fwrite( LC_CACHE_MAGIC, 1, 4, f ) != 4 ) goto out;
    if ( !write_u32( f, LC_CACHE_VERSION ) ) goto out;
    if ( !write_u32( f, ( uint32_t )cf->code_len ) ) goto out;
    if ( cf->code_len > 0 &&
         fwrite( cf->code, 1, cf->code_len, f ) != cf->code_len ) goto out;

    if ( !write_u32( f, ( uint32_t )cf->nrelocs ) ) goto out;
    for ( r = 0; r < cf->nrelocs; r++ ) {
        const LcReloc *rl = &cf->relocs[ r ];
        /* Hand-rolled strnlen: the symbol field is fixed-size and always
           NUL-terminated in practice (LcCodeBuf_AddReloc calls strncpy with
           len-1). Written out so MinGW/MSVC that don't ship strnlen still
           compile cleanly. */
        uint32_t sym_len = 0;
        while ( sym_len < ( uint32_t )sizeof( rl->symbol ) &&
                rl->symbol[ sym_len ] != '\0' ) sym_len++;
        uint32_t addend_u;
        memcpy( &addend_u, &rl->addend, sizeof( addend_u ) );
        if ( !write_u32( f, ( uint32_t )rl->kind ) ) goto out;
        if ( !write_u32( f, rl->offset ) ) goto out;
        if ( !write_u32( f, addend_u ) ) goto out;
        if ( !write_u32( f, sym_len ) ) goto out;
        if ( sym_len > 0 && fwrite( rl->symbol, 1, sym_len, f ) != sym_len ) goto out;
    }

    if ( !write_u32( f, ( uint32_t )cf->unwind_len ) ) goto out;
    if ( cf->unwind_len > 0 &&
         fwrite( cf->unwind, 1, cf->unwind_len, f ) != cf->unwind_len ) goto out;

    fflush( f );
    ok = 1;
out:
    if ( f ) fclose( f );
    if ( !ok ) {
        remove( stage_path );
        return 0;
    }
#ifdef _WIN32
    /* MOVEFILE_REPLACE_EXISTING makes concurrent writers to the same key
       serialise cleanly (the last write wins; readers either see the OLD
       finished file or the NEW finished file, never a partial one). */
    if ( !MoveFileExA( stage_path, final_path, MOVEFILE_REPLACE_EXISTING ) ) {
        remove( stage_path );
        return 0;
    }
#else
    if ( rename( stage_path, final_path ) != 0 ) {
        remove( stage_path );
        return 0;
    }
#endif
    return 1;
}

/* ------------------------------------------------------------------ */
/* Eviction                                                           */
/* ------------------------------------------------------------------ */

#ifdef _WIN32
typedef struct {
    char        name[ 260 ];
    uint64_t    size;
    FILETIME    mtime;
} LcCacheEntry;

/* qsort: OLDEST first. FILETIME is a 64-bit tick count; compare as unsigned. */
static int cmp_by_mtime( const void *a, const void *b ) {
    const LcCacheEntry *ea = ( const LcCacheEntry * )a;
    const LcCacheEntry *eb = ( const LcCacheEntry * )b;
    ULARGE_INTEGER ua, ub;
    ua.LowPart = ea->mtime.dwLowDateTime;  ua.HighPart = ea->mtime.dwHighDateTime;
    ub.LowPart = eb->mtime.dwLowDateTime;  ub.HighPart = eb->mtime.dwHighDateTime;
    if ( ua.QuadPart < ub.QuadPart ) return -1;
    if ( ua.QuadPart > ub.QuadPart ) return  1;
    return 0;
}

void LcCache_Evict( const char *dir ) {
    WIN32_FIND_DATAA fd;
    HANDLE           h;
    char             pattern[ 1024 ];
    LcCacheEntry    *entries = NULL;
    size_t           cap = 0, count = 0;
    uint64_t         total = 0;
    size_t           i;
    char             path[ 1024 ];

    if ( dir == NULL || dir[ 0 ] == '\0' ) return;
    if ( ( size_t )snprintf( pattern, sizeof( pattern ), "%s\\*.co", dir ) >= sizeof( pattern ) ) return;

    h = FindFirstFileA( pattern, &fd );
    if ( h == INVALID_HANDLE_VALUE ) return;

    do {
        LcCacheEntry *ne;
        uint64_t sz;
        if ( fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY ) continue;
        if ( count == cap ) {
            size_t nc = cap ? cap * 2 : 64;
            ne = ( LcCacheEntry * )realloc( entries, nc * sizeof( LcCacheEntry ) );
            if ( ne == NULL ) break;
            entries = ne;
            cap = nc;
        }
        snprintf( entries[ count ].name, sizeof( entries[ count ].name ),
                  "%s", fd.cFileName );
        sz = ( ( uint64_t )fd.nFileSizeHigh << 32 ) | fd.nFileSizeLow;
        entries[ count ].size  = sz;
        entries[ count ].mtime = fd.ftLastWriteTime;
        total += sz;
        count++;
    } while ( FindNextFileA( h, &fd ) );
    FindClose( h );

    if ( total <= LC_CACHE_MAX_BYTES || count == 0 ) { free( entries ); return; }

    qsort( entries, count, sizeof( LcCacheEntry ), cmp_by_mtime );
    for ( i = 0; i < count && total > LC_CACHE_MAX_BYTES; i++ ) {
        snprintf( path, sizeof( path ), "%s\\%s", dir, entries[ i ].name );
        if ( remove( path ) == 0 ) total -= entries[ i ].size;
    }
    free( entries );
}
#else
void LcCache_Evict( const char *dir ) {
    /* No POSIX host is exercised today; leave as a no-op. If a cross-build
       target adds one, replicate the Win32 shape with dirent + stat. */
    ( void )dir;
}
#endif
