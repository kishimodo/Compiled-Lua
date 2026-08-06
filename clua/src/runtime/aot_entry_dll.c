/*!
 * @file aot_entry_dll.c
 * @brief
 *  Entry object for CLua's `--output=dll` builds. The exe path is
 *  aot_entry.c (main() + closed-world stubs + the lookup dispatch hook);
 *  this file provides the same closed-world stubs plus a `Rt_DllMain` entry
 *  point (the DLL loader's initial call), a `Rt_ModuleInit` / `Rt_ModuleFini`
 *  pair, and a placeholder `Rt_DllExportDefault` symbol every export in the
 *  synthesized IMAGE_EXPORT_DIRECTORY points at.
 *
 *  This first arc lands the PE-header and export-directory plumbing. Each
 *  exported name resolves to `Rt_DllExportDefault`, which returns zero. Real
 *  per-export trampolines (extract args from the C ABI, push onto the Lua
 *  stack, call the `_exports[name]` closure, return the result) are the
 *  immediate follow-up documented in the commit message.
 *
 *  What does work end-to-end today:
 *    - `clua build foo.lua --output=dll -o foo.dll` produces a valid PE with
 *      IMAGE_FILE_DLL set, an IMAGE_EXPORT_DIRECTORY whose Name/Ordinal/RVA
 *      tables the Windows loader accepts, and each requested name available
 *      via GetProcAddress.
 *    - `Rt_DllMain` stands up the Lua state on DLL_PROCESS_ATTACH, runs the
 *      module chunk (which populates `_exports = {...}` in globals), stores
 *      that table in the registry for the follow-up trampoline work, and
 *      tears the state down on DLL_PROCESS_DETACH.
 *
 *  What does NOT work end-to-end today, deliberately:
 *    - Calling an exported name from C actually invokes `Rt_DllExportDefault`
 *      (returns 0). Wiring the export RVA to a per-export C ABI trampoline
 *      is the immediate follow-up commit.
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
}

/* The DLL loader entry. Standard signature; MUST return TRUE on ATTACH for
   the loader to accept the DLL. See the follow-up commit for the real
   per-export trampolines that would call into g_L / g_ExportsRef. */
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

/* Placeholder export target. Every entry in IMAGE_EXPORT_DIRECTORY.AddressOfFunctions
   points at this symbol until the per-export trampoline generator lands.
   Callers who take &foo via GetProcAddress will get a valid function pointer
   that returns 0, rather than a garbage address. The signature is
   deliberately int(void) so the loader-side type check (most FFIs coerce
   the value type based on the caller's declared cdecl) does not reject it. */
int Rt_DllExportDefault( void ) {
    return 0;
}
