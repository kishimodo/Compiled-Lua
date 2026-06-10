/*!
 * @brief
 *  ffi.load + ffi.C namespace + per-symbol GetProcAddress cache.
 */

#include "ffi/ffi_load.h"
#include "ffi/ffi_atomics.h"
#include "ffi/cdata.h"
#include "ffi/ctype.h"
#include "ffi/marshal.h"
#include "lauxlib.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stdio.h>
#include <string.h>

#define FFI_MAX_LOADED_MODULES 32
static HMODULE g_LoadedModules[ FFI_MAX_LOADED_MODULES ];
static int     g_NumLoadedModules = { 0 };

static void *Ffi_ResolveOne( HMODULE Module, const char *Sym ) {
    return ( void * )GetProcAddress( Module, Sym );
}

void *Ffi_LookupSymAcrossModules( const char *Sym ) {
    if ( Sym == NULL ) return NULL;
    int I = { 0 };
    for ( I = 0; I < g_NumLoadedModules; I++ ) {
        void *P = Ffi_ResolveOne( g_LoadedModules[ I ], Sym );
        if ( P != NULL ) return P;
    }
    return Ffi_AtomicsLookup( Sym );
}

void Ffi_RegisterModule( void *Hm ) {
    if ( Hm == NULL ) return;
    int I = { 0 };
    for ( I = 0; I < g_NumLoadedModules; I++ ) {
        if ( g_LoadedModules[ I ] == ( HMODULE )Hm ) return;  /* already registered */
    }
    if ( g_NumLoadedModules >= FFI_MAX_LOADED_MODULES ) return;
    g_LoadedModules[ g_NumLoadedModules++ ] = ( HMODULE )Hm;
}

/* Cache the CT_LIB ctype so all ffi.load'd cdatas share it.
   Created on first use. */
static PCType_T g_LibType = NULL;

static PCType_T GetLibType( void ) {
    if ( g_LibType == NULL ) {
        g_LibType = Ctype_New( );
        if ( g_LibType == NULL ) return NULL;
        g_LibType->Kind  = CT_LIB;
        g_LibType->Size  = 8;
        g_LibType->Align = 8;
    }
    return g_LibType;
}

/* Append ".dll" to Name if not already ending in .dll. */
static const char *NormalizeDllName( const char *Name, char *Out, size_t OutCap ) {
    size_t Len    = strlen( Name );
    int    HasDll = ( Len >= 4 ) &&
                    ( Name[ Len - 4 ] == '.' ) &&
                    ( Name[ Len - 3 ] == 'd' || Name[ Len - 3 ] == 'D' ) &&
                    ( Name[ Len - 2 ] == 'l' || Name[ Len - 2 ] == 'L' ) &&
                    ( Name[ Len - 1 ] == 'l' || Name[ Len - 1 ] == 'L' );
    if ( HasDll ) {
        snprintf( Out, OutCap, "%s", Name );
    } else {
        snprintf( Out, OutCap, "%s.dll", Name );
    }
    return Out;
}

static int LuaFn_Load( lua_State *L ) {
    const char *Name = luaL_checkstring( L, 1 );
    /* arg 2 (global) is ignored in v1 — LoadLibraryA already process-wide. */

    char Normalized[ 256 ] = { 0 };
    NormalizeDllName( Name, Normalized, sizeof( Normalized ) );

    HMODULE Hm = LoadLibraryA( Normalized );
    if ( Hm == NULL ) {
        char ErrBuf[ 64 ] = { 0 };
        snprintf( ErrBuf, sizeof( ErrBuf ), "%lu", ( unsigned long )GetLastError( ) );
        return luaL_error( L, "ffi: cannot load '%s' (GetLastError = %s)",
                           Normalized, ErrBuf );
    }

    Ffi_RegisterModule( Hm );   /* track for ffi.C lookups */

    PCType_T LibT = GetLibType( );
    if ( LibT == NULL ) {
        return luaL_error( L, "ffi.load: out of memory" );
    }
    PCData_T Cd = FfiNewCData( L, LibT );
    if ( Cd == NULL ) {
        return luaL_error( L, "ffi.load: cdata alloc failed" );
    }
    Cd->Ptr    = ( void * )Hm;
    Cd->Flags &= ~CDATA_FLAG_OWNS_MEMORY; /* HMODULE not freed on __gc */
    return 1;
}

void Ffi_OpenLoad( lua_State *L ) {
    /* L's top is the ffi table. Register ffi.load. */
    lua_pushcfunction( L, LuaFn_Load );
    lua_setfield( L, -2, "load" );

    /* Static preloads — these libs are always available for ffi.C lookup. */
    /* Main exe first so dllexport'd symbols statically linked into the
       runtime (e.g. ImGui host shim) win over a shadowing system import. */
    HMODULE Hself = GetModuleHandleA( NULL );
    if ( Hself ) Ffi_RegisterModule( Hself );
    HMODULE Hk = LoadLibraryA( "kernel32.dll" );
    if ( Hk ) Ffi_RegisterModule( Hk );
    HMODULE Hn = LoadLibraryA( "ntdll.dll" );
    if ( Hn ) Ffi_RegisterModule( Hn );
    HMODULE Ha = LoadLibraryA( "advapi32.dll" );
    if ( Ha ) Ffi_RegisterModule( Ha );

    /* Build ffi.C — a CT_LIB cdata with Ptr=NULL (sentinel for multi-module lookup) */
    PCType_T LibT = GetLibType( );
    if ( LibT != NULL ) {
        PCData_T CCd = FfiNewCData( L, LibT );  /* pushes cdata */
        if ( CCd != NULL ) {
            CCd->Ptr = NULL;
            CCd->Flags &= ~CDATA_FLAG_OWNS_MEMORY;
            lua_setfield( L, -2, "C" );          /* ffi.C = cdata */
        }
    }
}

/* Get the per-namespace symbol cache table for Namespace, creating it
   if it doesn't exist. Pushes the cache table onto L's stack.
   Returns 1 on success, 0 on failure. */
static int GetOrCreateSymbolCache( lua_State *L, PCData_T Namespace ) {
    /* Cache lives in the registry under a key derived from the namespace
       pointer. This way each namespace cdata has its own cache. */
    lua_pushlightuserdata( L, ( void * )Namespace );
    lua_rawget( L, LUA_REGISTRYINDEX );
    if ( lua_istable( L, -1 ) ) {
        return 1;
    }
    lua_pop( L, 1 );
    /* create and register */
    lua_newtable( L );
    lua_pushlightuserdata( L, ( void * )Namespace );
    lua_pushvalue( L, -2 );
    lua_rawset( L, LUA_REGISTRYINDEX );
    return 1;
}

int Ffi_ResolveSymbol( lua_State *L, PCData_T Namespace, const char *Sym ) {
    if ( Namespace == NULL || Namespace->Type->Kind != CT_LIB || Sym == NULL ) {
        lua_pushstring( L, "ffi: not a library namespace" );
        return 0;
    }

    /* Look in the per-namespace cache first */
    GetOrCreateSymbolCache( L, Namespace );  /* cache table on top */
    lua_getfield( L, -1, Sym );
    if ( !lua_isnil( L, -1 ) ) {
        /* hit — remove cache table from below, leave cached cdata on top */
        lua_remove( L, -2 );
        return 1;
    }
    lua_pop( L, 1 );   /* pop nil; cache table still on top */

    /* Find the function's ctype in the global ctype table */
    PCType_T FuncT = Ctype_Lookup( Sym );
    if ( FuncT == NULL || FuncT->Kind != CT_FUNC ) {
        /* Not a function. It may be an extern/global variable declared in cdef
           (`extern T name;`, e.g. oniguruma's OnigEncodingUTF8). Resolve its
           address and marshal the value at that address. Variable reads are not
           cached -- the global may be mutated by the library. */
        PCType_T VarT = Ctype_LookupExtern( Sym );
        if ( VarT != NULL ) {
            void *VAddr = NULL;
            if ( Namespace->Ptr != NULL ) {
                VAddr = Ffi_ResolveOne( ( HMODULE )Namespace->Ptr, Sym );
            } else {
                int J = { 0 };
                for ( J = 0; J < g_NumLoadedModules; J++ ) {
                    VAddr = ( void * )( FARPROC )Ffi_ResolveOne( g_LoadedModules[ J ], Sym );
                    if ( VAddr != NULL ) break;
                }
            }
            lua_pop( L, 1 );   /* pop cache table -- not caching variable reads */
            if ( VAddr == NULL ) {
                lua_pushfstring( L, "ffi: extern symbol '%s' not found in module(s)", Sym );
                return 0;
            }
            /* VAddr is the address OF the global; read its value of type VarT. */
            if ( !Marshal_CToLua( L, VarT, VAddr ) ) {
                lua_pushfstring( L, "ffi: cannot marshal extern '%s'", Sym );
                return 0;
            }
            return 1;
        }
        lua_pop( L, 1 );   /* pop cache table */
        lua_pushfstring( L, "ffi: undeclared function '%s' -- call ffi.cdef first", Sym );
        return 0;
    }

    /* If Namespace->Ptr is NULL, this is the multi-module ffi.C namespace
       — walk all loaded modules in order. */
    void *Addr = NULL;
    if ( Namespace->Ptr != NULL ) {
        Addr = Ffi_ResolveOne( ( HMODULE )Namespace->Ptr, Sym );
    } else {
        int I = { 0 };
        for ( I = 0; I < g_NumLoadedModules; I++ ) {
            Addr = ( void * )( FARPROC )Ffi_ResolveOne( g_LoadedModules[ I ], Sym );
            if ( Addr != NULL ) break;
        }
    }
    /* Fallback: built-in atomic thunks for Interlocked* intrinsics.
       These are compiler-inlined on x64 Windows and not exported by any DLL,
       so GetProcAddress always returns NULL for them. */
    if ( Addr == NULL && Namespace->Ptr == NULL ) {
        Addr = Ffi_AtomicsLookup( Sym );
    }
    if ( Addr == NULL ) {
        lua_pop( L, 1 );
        if ( Namespace->Ptr != NULL ) {
            lua_pushfstring( L, "ffi: symbol '%s' not found in module", Sym );
        } else {
            lua_pushfstring( L, "ffi: symbol '%s' not found in loaded modules", Sym );
        }
        return 0;
    }

    /* Allocate a CT_FUNC cdata holding the resolved address */
    PCData_T FnCd = FfiNewCData( L, FuncT );  /* pushes cdata onto stack */
    if ( FnCd == NULL ) {
        lua_pop( L, 2 );   /* cdata-spot + cache */
        lua_pushstring( L, "ffi: cdata alloc failed" );
        return 0;
    }
    FnCd->Ptr = ( void * )Addr;
    FnCd->Flags &= ~CDATA_FLAG_OWNS_MEMORY;

    /* Cache against the namespace: cache[Sym] = FnCd. Stack: [... cache, FnCd] */
    lua_pushvalue( L, -1 );          /* dup FnCd */
    lua_setfield( L, -3, Sym );      /* cache[Sym] = FnCd; pops FnCd */
    /* Stack: [... cache, FnCd]. Remove cache from below. */
    lua_remove( L, -2 );
    return 1;
}
