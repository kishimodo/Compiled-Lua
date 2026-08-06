/*!
 * @file aot_entry_dll.c
 * @brief
 *  Entry object for CLua's `--output=dll` builds. The exe path is
 *  aot_entry.c (main() + closed-world stubs + the lookup dispatch hook);
 *  this file provides the same closed-world stubs plus a `Rt_DllMain` entry
 *  point (the DLL loader's initial call), a `Rt_ModuleInit` / `Rt_ModuleFini`
 *  pair, and the `Rt_DllExportDispatch` symbol every export trampoline the
 *  linker synthesises tail-jumps to.
 *
 *  What works end-to-end today:
 *    - `clua build foo.lua --output=dll -o foo.dll` produces a valid PE with
 *      IMAGE_FILE_DLL set, an IMAGE_EXPORT_DIRECTORY whose Name/Ordinal/RVA
 *      tables the Windows loader accepts, and each requested name available
 *      via GetProcAddress.
 *    - `Rt_DllMain` stands up the Lua state on DLL_PROCESS_ATTACH, runs the
 *      module chunk (which populates `_exports = {...}` in globals), and
 *      captures that table in the registry (g_ExportsRef) so
 *      Rt_DllExportDispatch can look it up. The state is torn down on
 *      DLL_PROCESS_DETACH.
 *    - Every exported name's AddressOfFunctions RVA points at a linker-
 *      synthesised trampoline in .text that stashes the export's ordinal in
 *      %r8d and tail-jumps to Rt_DllExportDispatch(double,double,int32_t).
 *      That helper looks up the corresponding closure via g_ExportsRef +
 *      ordinal-derived Lua array index, pushes the two double arguments,
 *      lua_pcall's it, and returns the numeric result as a double. The
 *      supported C ABI is `double fn(double, double)`, which the fixture's
 *      `add = function(a,b) return a+b end` satisfies (Lua numbers coerce
 *      cleanly from doubles).
 *
*  Supported ABI shapes today (selected per-export by an optional
 *  `_export_types = { name = "shape" }` companion table in the module; each
 *  shape maps to its own dispatcher below):
 *    - "dd_d"  double  (double, double)         Rt_DllExportDispatch
 *    - "ii_i"  int64_t (int64_t, int64_t)       Rt_DllExportDispatch_ii_i
 *    - "s_s"   const char * (const char *)      Rt_DllExportDispatch_s_s
 *  Unannotated exports default to "dd_d" -- the pre-annotation behavior.
 *  Every dispatcher's C signature takes THREE parameters -- the two visible
 *  export inputs plus the ordinal -- so the linker-generated trampoline can
 *  stay one shape (mov r8d, imm ; jmp rel32) regardless of the shape it
 *  routes to. For s_s the second parameter is a filler slot.
 *
 *  Not yet supported (deliberate scope for a later arc):
 *    - Mixed / non-uniform shapes (e.g. `double(int, const char *)`) and
 *      void-returning shapes. Adding one needs a new dispatcher below, a new
 *      case in pe_emit.c's dispatcher_symbol_for_shape, and a new
 *      --undefined root in pe_link_v2.c so gc-sections keeps it alive.
 *
 *  Compile-time: exactly one aot_entry_dll.o per DLL link. See pe_link_v2.c's
 *  toolchain resolution (aot_entry_dll_o).
 */

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lstate.h"
#include "lobject.h"
#include "lfunc.h"
#include "lgc.h"
#include "ldo.h"
#include "lvm.h"

#include "jit/dispatch.h"

#include "lzio.h"
#include "llex.h"
#include "lparser.h"
#include "lundump.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* The generated symbol every AOT program provides: reconstructs Protos and
   returns the entry proto. */
extern Proto *LuacProgram_BuildEntry( lua_State *L );

/* Lookup dispatch hook -- identical to aot_entry.c's. Both entry objects
   register this via clua_dispatch_hook so luaV_execute can route to the
   registered AOT body. Signature already declared by lvm.h (clua_dispatch_t). */
static void *AotLookupHookDll( lua_State *L, void *proto ) {
    ( void )L;
    return ( void * )Jit_LookupCached( ( Proto * )proto );
}

/* Optional stdlib anchors (weak, driver-force-undefined per library used). */
extern void Clua_OpenStrlib ( lua_State *L ) __attribute__(( weak ));
extern void Clua_OpenTablib ( lua_State *L ) __attribute__(( weak ));
extern void Clua_OpenMathlib( lua_State *L ) __attribute__(( weak ));
extern void Clua_OpenIolib  ( lua_State *L ) __attribute__(( weak ));
extern void Clua_OpenOslib  ( lua_State *L ) __attribute__(( weak ));
extern void Clua_OpenUtf8lib( lua_State *L ) __attribute__(( weak ));
extern void Clua_OpenDbglib ( lua_State *L ) __attribute__(( weak ));

/* Same subset the exe entry opens: base + package always, then each optional
   library whose anchor was linked. luaL_openlibs would drag in every
   luaopen_* even for a DLL that never uses them. */
static void Clua_OpenUsedLibsDll( lua_State *L ) {
    luaL_requiref( L, LUA_GNAME,       luaopen_base,    1 ); lua_pop( L, 1 );
    luaL_requiref( L, LUA_LOADLIBNAME, luaopen_package, 1 ); lua_pop( L, 1 );
    if ( &Clua_OpenStrlib  != NULL ) Clua_OpenStrlib ( L );
    if ( &Clua_OpenTablib  != NULL ) Clua_OpenTablib ( L );
    if ( &Clua_OpenMathlib != NULL ) Clua_OpenMathlib( L );
    if ( &Clua_OpenIolib   != NULL ) Clua_OpenIolib  ( L );
    if ( &Clua_OpenOslib   != NULL ) Clua_OpenOslib  ( L );
    if ( &Clua_OpenUtf8lib != NULL ) Clua_OpenUtf8lib( L );
    if ( &Clua_OpenDbglib  != NULL ) Clua_OpenDbglib ( L );
}

/* Reuse the closed-world stubs so this object can shadow the parser members
   the same way aot_entry.o does on the exe link line. */
#include "closed_world_stubs.c"

/* crt2.o unconditionally references `main`, which pulls runtime_entry.o
   (defines main -> RuntimeMain), which pulls runtime_init.o (defines
   RuntimeMain -> undefined Runtime_GetPackages). A DLL's real entry is
   Rt_DllMain and the whole exe boot chain is never called. Define stubs
   here so the link resolves cleanly; the code is unreachable at run time
   because Rt_DllMain is the entry symbol and gc-sections drops the whole
   chain.

   These MUST match the signatures runtime_init.c expects. See
   runtime_init.c:51-61 for REGISTERED_PACKAGE_T + Runtime_GetPackages. */
typedef struct _REGISTERED_PACKAGE_STUB {
    const char *Name;
    int       (*Loader)( lua_State *L );
} REGISTERED_PACKAGE_STUB_T;
const void *Runtime_GetPackages( size_t *OutCount ) {
    if ( OutCount ) *OutCount = 0;
    return ( const void * )0;
}

/* main() as a weak stub so the linker resolves crt2.o's reference
   without pulling in runtime_entry.o -> runtime_init.o -> ... . The
   function is never called: the DLL entry is Rt_DllMain, and
   gc-sections will drop this whole path. */
int main( int argc, char **argv ) {
    ( void )argc; ( void )argv;
    return 0;
}

/* --- module lifecycle ------------------------------------------------- */

/* Per-DLL state. Guarded by g_ModuleCs so concurrent DllMain callbacks are
   safe (unlikely but not impossible: LoadLibrary reentry). Kept file-scope
   because DllMain has no user parameter to thread through. */
static CRITICAL_SECTION g_ModuleCs;
static INIT_ONCE        g_ModuleOnce = INIT_ONCE_STATIC_INIT;
static BOOL CALLBACK ModuleInitCb( PINIT_ONCE O, PVOID P, PVOID *C ) {
    ( void )O; ( void )P; ( void )C;
    InitializeCriticalSection( &g_ModuleCs );
    return TRUE;
}

static lua_State *g_L         = NULL;   /* the DLL's Lua state              */
static int        g_ExportsRef = LUA_NOREF; /* registry ref -> _exports tbl */

/* Sorted export names, populated after the module chunk runs. Forward-
   declared here because Rt_ModuleFini frees them; definition is near
   Rt_DllExportDispatch where the dispatcher reads them. */
static const char **g_ExportNames;
static int          g_ExportCount;

/* Set the module's lua_State up: open the libs the driver linked, run the
   entry chunk (which populates the globals table, including `_exports`),
   then capture globals._exports in the registry for later trampoline
   dispatch. Returns 1 on success. */
static int Rt_ModuleInit( void ) {
    lua_State *L;
    Proto     *entry;
    LClosure  *cl;
    int        status;

    L = luaL_newstate( );
    if ( L == NULL ) return 0;

    Clua_OpenUsedLibsDll( L );
    clua_dispatch_hook = AotLookupHookDll;

    lua_gc( L, LUA_GCSTOP );
    entry = LuacProgram_BuildEntry( L );
    if ( entry == NULL ) { lua_close( L ); return 0; }

    /* Push the entry chunk closure with _ENV bound to globals, same as the
       exe path (aot_entry.c). */
    cl = luaF_newLclosure( L, entry->sizeupvalues );
    cl->p = entry;
    setclLvalue2s( L, L->top.p, cl );
    L->top.p++;
    luaF_initupvals( L, cl );
    if ( entry->sizeupvalues >= 1 ) {
        const TValue *gt =
            &hvalue( &G( L )->l_registry )->array[ LUA_RIDX_GLOBALS - 1 ];
        setobj( L, cl->upvals[ 0 ]->v.p, gt );
        luaC_barrier( L, cl->upvals[ 0 ], gt );
    }
    lua_gc( L, LUA_GCRESTART );

    /* Run the module chunk. Any error here means the DLL cannot load. */
    status = lua_pcall( L, 0, 0, 0 );
    if ( status != LUA_OK ) {
        lua_close( L );
        return 0;
    }

    /* Capture globals._exports. If the module did not set one, keep NOREF
       and every export call returns the default. */
    lua_getglobal( L, "_exports" );
    if ( lua_type( L, -1 ) == LUA_TTABLE ) {
        g_ExportsRef = luaL_ref( L, LUA_REGISTRYINDEX );
    } else {
        lua_pop( L, 1 );
    }

    g_L = L;
    return 1;
}

static void Rt_ModuleFini( void ) {
    if ( g_L != NULL ) {
        if ( g_ExportsRef != LUA_NOREF ) {
            luaL_unref( g_L, LUA_REGISTRYINDEX, g_ExportsRef );
            g_ExportsRef = LUA_NOREF;
        }
        lua_close( g_L );
        g_L = NULL;
    }
    if ( g_ExportNames != NULL ) {
        int i;
        for ( i = 0; i < g_ExportCount; i++ ) {
            /* _strdup memory owned here; cast away const only for free. */
            free( ( void * )g_ExportNames[ i ] );
        }
        free( ( void * )g_ExportNames );
        g_ExportNames = NULL;
        g_ExportCount = 0;
    }
}

/* Shared per-export dispatcher. The linker synthesises one 11-byte trampoline
   per exported name whose only work is:
     mov r8d, <ordinal>            ; 41 B8 xx xx xx xx  (6 bytes)
     jmp Rt_DllExportDispatch      ; E9 xx xx xx xx     (5 bytes)
   The Windows x64 ABI maps the trampoline's (double, double) caller inputs
   into xmm0/xmm1 directly, and Rt_DllExportDispatch's third parameter --
   int32_t -- comes in r8d, exactly where the trampoline just wrote it. That
   is why the signature order is (double,double,int32_t) rather than the more
   natural (int,double,double): no argument shuffling is needed.

   Ordinal is 0-based here (the linker sorts export_names alphabetically and
   emits one trampoline per index). The registry ref g_ExportsRef points at
   the `_exports` table; its keys are strings, not integers, so we translate
   the ordinal to a name via the same sorted order the linker used --
   g_ExportNames[] below is patched by the DLL entry each time a new export
   list is captured. For the first arc we accept only (double,double)->double
   Lua functions; any deviation returns 0.0 (Lua nil -> 0). */

/* The names table is populated in Rt_CaptureExportNames after the module
   chunk runs. aot_entry_dll.c is built once and reused for every DLL link,
   so the names cannot be hard-coded here; instead the runtime walks the
   captured `_exports` table and sorts the keys with the same comparator
   the linker used (byte-order strcmp on the C strings) so ordinal N here
   maps to the same name as AddressOfFunctions[N] in the export table. */
/* Definition (forward-declared near g_L for Rt_ModuleFini). Tentative-
   definition merge in C: the top forward-decl and this initialized definition
   collapse to one object. */
static const char **g_ExportNames = NULL;
static int          g_ExportCount = 0;

double Rt_DllExportDispatch( double a, double b, int32_t ordinal ) {
    lua_State *L;
    double     result = 0.0;
    int        status;
    const char *name;

    /* If the module never populated `_exports`, or the ordinal falls outside
       the captured range, there is nothing to call. Returning 0.0 keeps the
       function well-defined for FFI callers (LuaJIT-style ffi.cdef treats a
       double return of 0 as a valid, non-error value). */
    if ( g_L == NULL || g_ExportsRef == LUA_NOREF ||
         g_ExportNames == NULL || ordinal < 0 || ordinal >= g_ExportCount ) {
        return 0.0;
    }
    name = g_ExportNames[ ordinal ];
    if ( name == NULL ) return 0.0;

    EnterCriticalSection( &g_ModuleCs );
    L = g_L;

    /* Push _exports[name] onto the stack. If it is not callable, unwind and
       return zero -- do not raise (the C caller has no Lua error path). */
    lua_rawgeti( L, LUA_REGISTRYINDEX, g_ExportsRef );  /* [ tbl ] */
    if ( lua_type( L, -1 ) != LUA_TTABLE ) {
        lua_pop( L, 1 );
        LeaveCriticalSection( &g_ModuleCs );
        return 0.0;
    }
    lua_getfield( L, -1, name );                        /* [ tbl fn ] */
    if ( !lua_isfunction( L, -1 ) ) {
        lua_pop( L, 2 );
        LeaveCriticalSection( &g_ModuleCs );
        return 0.0;
    }
    /* Reorder to [ fn ] so pcall's stack layout is clean, then push args. */
    lua_remove( L, -2 );                                /* [ fn ] */
    lua_pushnumber( L, ( lua_Number )a );
    lua_pushnumber( L, ( lua_Number )b );
    status = lua_pcall( L, 2, 1, 0 );
    if ( status == LUA_OK ) {
        if ( lua_isnumber( L, -1 ) ) {
            result = ( double )lua_tonumber( L, -1 );
        }
        lua_pop( L, 1 );
    } else {
        /* Swallow the error; a real API would need a diagnostic channel back
           to the C caller. Pop the error message so the stack is balanced. */
        lua_pop( L, 1 );
    }
    LeaveCriticalSection( &g_ModuleCs );
    return result;
}

/* --------- additional C ABI shapes ---------------------------------------
   Every dispatcher takes THREE fixed-position parameters so the linker's
   generated trampoline is one shape for all -- 11 bytes, `mov r8d,imm ; jmp
   rel32`. The Windows x64 ABI puts arg0 in rcx (or xmm0 if float), arg1 in
   rdx (or xmm1 if float), and arg2 in r8 (or xmm2 if float); the trampoline's
   `mov r8d, <ordinal>` therefore lands the ordinal exactly where each
   dispatcher's third parameter already expects it.

     Rt_DllExportDispatch_ii_i(int64_t a, int64_t b, int32_t ordinal)
        rcx = a, rdx = b, r8d = ordinal
     Rt_DllExportDispatch_s_s(const char *s, int64_t pad, int32_t ordinal)
        rcx = s, rdx = <caller's second arg, unused>, r8d = ordinal
        The `pad` slot is declared but never read -- callers of a
        `const char *(*)(const char *)` type only pass one argument, and rdx
        is scratch to the callee in the Microsoft x64 ABI, so its content is
        undefined and safely ignored.

   All three dispatchers share the same lookup, locking and error-swallowing
   behavior as the double variant above. */

int64_t Rt_DllExportDispatch_ii_i( int64_t a, int64_t b, int32_t ordinal ) {
    lua_State  *L;
    int64_t     result = 0;
    int         status;
    const char *name;

    if ( g_L == NULL || g_ExportsRef == LUA_NOREF ||
         g_ExportNames == NULL || ordinal < 0 || ordinal >= g_ExportCount ) {
        return 0;
    }
    name = g_ExportNames[ ordinal ];
    if ( name == NULL ) return 0;

    EnterCriticalSection( &g_ModuleCs );
    L = g_L;

    lua_rawgeti( L, LUA_REGISTRYINDEX, g_ExportsRef );  /* [ tbl ] */
    if ( lua_type( L, -1 ) != LUA_TTABLE ) {
        lua_pop( L, 1 );
        LeaveCriticalSection( &g_ModuleCs );
        return 0;
    }
    lua_getfield( L, -1, name );                        /* [ tbl fn ] */
    if ( !lua_isfunction( L, -1 ) ) {
        lua_pop( L, 2 );
        LeaveCriticalSection( &g_ModuleCs );
        return 0;
    }
    lua_remove( L, -2 );                                /* [ fn ] */
    lua_pushinteger( L, ( lua_Integer )a );
    lua_pushinteger( L, ( lua_Integer )b );
    status = lua_pcall( L, 2, 1, 0 );
    if ( status == LUA_OK ) {
        if ( lua_isinteger( L, -1 ) ) {
            result = ( int64_t )lua_tointeger( L, -1 );
        } else if ( lua_isnumber( L, -1 ) ) {
            /* Lua may return a float from an integer-shape function
               (`return a+b` on floats). lua_tointeger applies the same
               narrowing convention Lua 5.4 uses for integer contexts. */
            result = ( int64_t )lua_tointeger( L, -1 );
        }
        lua_pop( L, 1 );
    } else {
        lua_pop( L, 1 );
    }
    LeaveCriticalSection( &g_ModuleCs );
    return result;
}

/* String return lifetime: lua_tostring returns a pointer into the Lua string
   object on the stack. The moment we pop the stack the GC may reclaim it, so
   the caller would see freed memory. _strdup the bytes before popping and
   hand the owned copy back to the C caller; ownership crosses the DLL
   boundary and freeing it is the caller's responsibility (CRT-compatible
   free()). Returning NULL on any error keeps this well-defined for callers
   that null-check the result. */
const char *Rt_DllExportDispatch_s_s( const char *s, int64_t pad,
                                       int32_t ordinal ) {
    lua_State  *L;
    const char *result = NULL;
    int         status;
    const char *name;
    ( void )pad;    /* trampoline-position filler, see the comment above */

    if ( g_L == NULL || g_ExportsRef == LUA_NOREF ||
         g_ExportNames == NULL || ordinal < 0 || ordinal >= g_ExportCount ) {
        return NULL;
    }
    name = g_ExportNames[ ordinal ];
    if ( name == NULL ) return NULL;

    EnterCriticalSection( &g_ModuleCs );
    L = g_L;

    lua_rawgeti( L, LUA_REGISTRYINDEX, g_ExportsRef );  /* [ tbl ] */
    if ( lua_type( L, -1 ) != LUA_TTABLE ) {
        lua_pop( L, 1 );
        LeaveCriticalSection( &g_ModuleCs );
        return NULL;
    }
    lua_getfield( L, -1, name );                        /* [ tbl fn ] */
    if ( !lua_isfunction( L, -1 ) ) {
        lua_pop( L, 2 );
        LeaveCriticalSection( &g_ModuleCs );
        return NULL;
    }
    lua_remove( L, -2 );                                /* [ fn ] */
    if ( s != NULL ) {
        lua_pushstring( L, s );
    } else {
        lua_pushnil( L );
    }
    status = lua_pcall( L, 1, 1, 0 );
    if ( status == LUA_OK ) {
        if ( lua_isstring( L, -1 ) ) {
            const char *r = lua_tostring( L, -1 );
            if ( r != NULL ) result = _strdup( r );
        }
        lua_pop( L, 1 );
    } else {
        lua_pop( L, 1 );
    }
    LeaveCriticalSection( &g_ModuleCs );
    return result;
}

/* Populate g_ExportNames from the captured _exports table. Called once after
   Rt_ModuleInit succeeds, before any user thread can dispatch. The names are
   sorted alphabetically to match the order the internal linker uses when it
   lays out AddressOfFunctions (see pe_emit.c: build_exports, qsort by name).
   The strings are strdup'd into a small malloc'd array; freed by
   Rt_ModuleFini. */
static int compare_cstr_ptrs( const void *a, const void *b ) {
    const char *sa = *( const char *const * )a;
    const char *sb = *( const char *const * )b;
    return strcmp( sa, sb );
}

static void Rt_CaptureExportNames( void ) {
    lua_State *L = g_L;
    int i, n = 0;
    if ( L == NULL || g_ExportsRef == LUA_NOREF ) return;

    lua_rawgeti( L, LUA_REGISTRYINDEX, g_ExportsRef );  /* [ tbl ] */
    if ( lua_type( L, -1 ) != LUA_TTABLE ) { lua_pop( L, 1 ); return; }

    /* Count string-keyed entries. */
    lua_pushnil( L );
    while ( lua_next( L, -2 ) != 0 ) {
        if ( lua_type( L, -2 ) == LUA_TSTRING ) n++;
        lua_pop( L, 1 );
    }
    if ( n == 0 ) { lua_pop( L, 1 ); return; }

    g_ExportNames = ( const char ** )calloc( ( size_t )n, sizeof( char * ) );
    if ( g_ExportNames == NULL ) { lua_pop( L, 1 ); return; }

    i = 0;
    lua_pushnil( L );
    while ( lua_next( L, -2 ) != 0 && i < n ) {
        if ( lua_type( L, -2 ) == LUA_TSTRING ) {
            const char *k = lua_tostring( L, -2 );
            g_ExportNames[ i++ ] = _strdup( k );
        }
        lua_pop( L, 1 );
    }
    lua_pop( L, 1 );  /* tbl */

    qsort( g_ExportNames, ( size_t )i, sizeof( char * ), compare_cstr_ptrs );
    g_ExportCount = i;
}

/* The DLL loader entry. Standard signature; MUST return TRUE on ATTACH for
   the loader to accept the DLL. */
BOOL WINAPI Rt_DllMain( HINSTANCE inst, DWORD reason, LPVOID reserved ) {
    ( void )inst; ( void )reserved;
    InitOnceExecuteOnce( &g_ModuleOnce, ModuleInitCb, NULL, NULL );
    switch ( reason ) {
    case DLL_PROCESS_ATTACH:
        EnterCriticalSection( &g_ModuleCs );
        if ( !Rt_ModuleInit( ) ) {
            LeaveCriticalSection( &g_ModuleCs );
            return FALSE;
        }
        /* Snapshot the export-name array so Rt_DllExportDispatch can map an
           ordinal back to a Lua key without repeatedly walking the table. */
        Rt_CaptureExportNames( );
        LeaveCriticalSection( &g_ModuleCs );
        return TRUE;
    case DLL_PROCESS_DETACH:
        EnterCriticalSection( &g_ModuleCs );
        Rt_ModuleFini( );
        LeaveCriticalSection( &g_ModuleCs );
        return TRUE;
    case DLL_THREAD_ATTACH:
    case DLL_THREAD_DETACH:
        return TRUE;
    default:
        return TRUE;
    }
}

/* Legacy fallback export target. Retained so out-of-tree DLL entry objects
   that still force-undef `Rt_DllExportDefault` continue to link cleanly. Not
   referenced by the current export-directory wiring: the linker synthesises
   per-name trampolines that tail-jump to Rt_DllExportDispatch above. If
   gc-sections runs without any --undefined=Rt_DllExportDefault root this
   function is dropped. */
int Rt_DllExportDefault( void ) {
    return 0;
}
