/*!
 * @brief
 *  Standalone clua-interp.exe entry: runs a Lua script file or drops into an
 *  interactive REPL. Links against the same runtime.a + Lua core, so it
 *  has the FFI, fiber-coroutines, and the embedded windows preload.
 *  Always executes through the reference bytecode interpreter — clua-interp is
 *  the frozen fidelity oracle the differential test layers diff compiled
 *  CLua exes against. (`-i` is still accepted as a no-op for the many
 *  suite invocations that pass it; the v1 JIT it used to disable has been
 *  removed from the tree.)
 *
 *  Usage:
 *    clua-interp.exe [-i]                       -- REPL
 *    clua-interp.exe [-i] script.lua [args...]  -- run script with arg = {...}
 *    clua-interp.exe [-i] -e "code"             -- execute code string
 */

#include "runtime/coro.h"
#include "ffi/ffi_lib.h"
#include "ffi/ffi_callback.h"
#include "ffi/ctype.h"
#include "ffi/win_types.h"
#include "ffi/veh.h"

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
#include "lstate.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

extern const char         g_PackageWindowsLua[ ];
extern const unsigned int g_PackageWindowsLua_len;
extern const char         g_PackageAsyncLua[ ];
extern const unsigned int g_PackageAsyncLua_len;

/* Same msghandler used by runtime_init.c -- appends a traceback so
   uncaught errors print with full call chain context. */
static int Clua_Msghandler( lua_State *L ) {
    const char *Msg = lua_tostring( L, 1 );
    if ( Msg == NULL ) {
        if ( luaL_callmeta( L, 1, "__tostring" ) && lua_type( L, -1 ) == LUA_TSTRING ) {
            return 1;
        }
        Msg = lua_pushfstring( L, "(error object is a %s value)",
                                luaL_typename( L, 1 ) );
    }
    luaL_traceback( L, L, Msg, 1 );
    return 1;
}

/* The embedded `g_Package<Name>Lua` blobs are emitted by embed_luac and are
   often LVC1+XPRESS_HUFF *compressed* (the windows package is), so the host
   must NOT luaL_loadbuffer them raw -- doing so fed the compressed bytes to
   the Lua lexer and produced the historical `=windows: syntax error`. This
   loader mirrors the runtime's Runtime_PackageLoader: detect the "LVC1"
   prefix, decompress via ntdll RtlDecompressBufferEx, then load. (Kept
   self-contained here so the host doesn't drag in the compiled-runtime
   registration code, which needs a per-build Runtime_GetPackages symbol.) */
#define CLUA_PKG_COMPRESS_MAGIC   0x3143564Cu   /* 'LVC1' little-endian */
#define CLUA_PKG_COMPRESS_HDR     8             /* magic (4) + uint32 orig len */
#define CLUA_PKG_COMPRESS_FORMAT  4             /* COMPRESSION_FORMAT_XPRESS_HUFF */

typedef LONG ( WINAPI *PRtlDecompressBufferEx )(
    USHORT, PUCHAR, ULONG, PUCHAR, ULONG, PULONG, PVOID );

/* package.preload loader. Upvalues: (1) blob bytes, (2) &len, (3) name. */
static int Clua_PackageLoader( lua_State *L ) {
    const char         *Src    = ( const char         * )lua_touserdata( L, lua_upvalueindex( 1 ) );
    const unsigned int *LenPtr = ( const unsigned int * )lua_touserdata( L, lua_upvalueindex( 2 ) );
    const char         *Name   = lua_tostring( L, lua_upvalueindex( 3 ) );
    char Chunkname[ 128 ];
    snprintf( Chunkname, sizeof( Chunkname ), "=%s", Name ? Name : "?" );

    size_t         Len     = ( size_t )*LenPtr;
    const char    *Body    = Src;
    size_t         BodyLen = Len;
    unsigned char *Decomp  = NULL;

    if ( Len >= CLUA_PKG_COMPRESS_HDR &&
         *( const uint32_t * )Src == CLUA_PKG_COMPRESS_MAGIC ) {
        static PRtlDecompressBufferEx s_Decompress = NULL;
        if ( s_Decompress == NULL ) {
            HMODULE H = GetModuleHandleA( "ntdll.dll" );
            if ( H == NULL ) H = LoadLibraryA( "ntdll.dll" );
            if ( H != NULL ) {
                s_Decompress = ( PRtlDecompressBufferEx )( void * )
                    GetProcAddress( H, "RtlDecompressBufferEx" );
            }
        }
        if ( s_Decompress == NULL ) {
            lua_pushfstring( L, "package %s: RtlDecompressBufferEx unavailable",
                             Name ? Name : "?" );
            return lua_error( L );
        }
        uint32_t UncompLen = *( const uint32_t * )( Src + 4 );
        Decomp = ( unsigned char * )malloc( UncompLen );
        if ( Decomp == NULL ) {
            lua_pushfstring( L, "package %s: oom", Name ? Name : "?" );
            return lua_error( L );
        }
        ULONG  ScratchLen = ( ULONG )( Len * 8 + 4096 );
        void  *Scratch    = malloc( ScratchLen );
        ULONG  OutLen     = 0;
        LONG   Status     = s_Decompress(
            CLUA_PKG_COMPRESS_FORMAT,
            ( PUCHAR )Decomp, UncompLen,
            ( PUCHAR )( Src + CLUA_PKG_COMPRESS_HDR ),
            ( ULONG )( Len - CLUA_PKG_COMPRESS_HDR ),
            &OutLen, Scratch );
        if ( Scratch ) free( Scratch );
        if ( Status != 0 || OutLen != UncompLen ) {
            free( Decomp );
            lua_pushfstring( L, "package %s: decompress failed status=0x%X",
                             Name ? Name : "?", ( unsigned )Status );
            return lua_error( L );
        }
        Body    = ( const char * )Decomp;
        BodyLen = ( size_t )UncompLen;
    }

    int Rc = luaL_loadbuffer( L, Body, BodyLen, Chunkname );
    if ( Decomp ) free( Decomp );  /* loadbuffer copied the bytes */
    if ( Rc != LUA_OK ) return lua_error( L );
    lua_call( L, 0, 1 );
    return 1;
}

static void Clua_RegisterPreload( lua_State *L, const char *Name,
                                   const char *Blob, const unsigned int *LenPtr ) {
    lua_pushlightuserdata( L, ( void * )Blob );      /* upvalue 1: blob bytes */
    lua_pushlightuserdata( L, ( void * )LenPtr );    /* upvalue 2: &len       */
    lua_pushstring( L, Name );                       /* upvalue 3: name       */
    lua_pushcclosure( L, Clua_PackageLoader, 3 );
    lua_setfield( L, -2, Name );                     /* preload[Name] = loader */
}

static void Clua_InstallPreloads( lua_State *L ) {
    lua_getglobal( L, "package" );
    lua_getfield( L, -1, "preload" );
    Clua_RegisterPreload( L, "windows", g_PackageWindowsLua, &g_PackageWindowsLua_len );
    Clua_RegisterPreload( L, "async",   g_PackageAsyncLua,   &g_PackageAsyncLua_len );
    lua_pop( L, 2 );
}

/* Register the runtime exe's .text region with VEH so faults inside our
   helpers still surface as Lua errors. Mirrors runtime_init.c. */
static void Clua_RegisterRuntimeTextRegion( void ) {
    HMODULE Hm = GetModuleHandleW( NULL );
    if ( Hm == NULL ) return;
    BYTE *Base = ( BYTE * )Hm;
    PIMAGE_DOS_HEADER Dos = ( PIMAGE_DOS_HEADER )Base;
    if ( Dos->e_magic != IMAGE_DOS_SIGNATURE ) return;
    PIMAGE_NT_HEADERS Nt = ( PIMAGE_NT_HEADERS )( Base + Dos->e_lfanew );
    if ( Nt->Signature != IMAGE_NT_SIGNATURE ) return;
    PIMAGE_SECTION_HEADER Sec = IMAGE_FIRST_SECTION( Nt );
    for ( int I = 0; I < Nt->FileHeader.NumberOfSections; I++ ) {
        if ( memcmp( Sec[ I ].Name, ".text", 5 ) == 0 ) {
            Veh_RegisterRegion( Base + Sec[ I ].VirtualAddress,
                                ( size_t )Sec[ I ].Misc.VirtualSize );
            return;
        }
    }
}

/* Print an error from the top of L (whatever the msghandler returned).
   Pops the error object. */
static void Clua_PrintError( lua_State *L ) {
    const char *Msg = lua_tostring( L, -1 );
    fprintf( stderr, "clua-interp: %s\n", Msg ? Msg : "(no message)" );
    lua_pop( L, 1 );
}

/* Run the function at top of stack with nargs args (consumed) and the
   msghandler we install for traceback support. Returns the lua_pcall
   status code. */
static int Clua_CallProtected( lua_State *L, int NArgs, int NResults ) {
    int Base = lua_gettop( L ) - NArgs;  /* function index */
    lua_pushcfunction( L, Clua_Msghandler );
    lua_insert( L, Base );  /* push msghandler below function + args */
    int Status = lua_pcall( L, NArgs, NResults, Base );
    lua_remove( L, Base );  /* remove msghandler */
    return Status;
}

static int Clua_DoString( lua_State *L, const char *Src, const char *ChunkName ) {
    if ( luaL_loadbuffer( L, Src, strlen( Src ), ChunkName ) != LUA_OK ) {
        Clua_PrintError( L );
        return -1;
    }
    if ( Clua_CallProtected( L, 0, 0 ) != LUA_OK ) {
        Clua_PrintError( L );
        return -1;
    }
    return 0;
}

static int Clua_DoFile( lua_State *L, const char *Path ) {
    if ( luaL_loadfile( L, Path ) != LUA_OK ) {
        Clua_PrintError( L );
        return -1;
    }
    if ( Clua_CallProtected( L, 0, 0 ) != LUA_OK ) {
        Clua_PrintError( L );
        return -1;
    }
    return 0;
}

/* Push the global `arg` table using the stock-Lua convention: arg[0] is the
   script (or program) name at Argv[ProgIdx], and arg[1], arg[2], ... are the
   arguments that follow it. (The previous version put the script name at
   arg[1], shifting every real argument by one -- so scripts reading arg[1]
   as their first argument got the script path instead.) */
static void Clua_PushArgTable( lua_State *L, int Argc, char **Argv, int ProgIdx ) {
    lua_createtable( L, Argc - ProgIdx, 1 );
    if ( ProgIdx < Argc ) {
        lua_pushstring( L, Argv[ ProgIdx ] );
        lua_rawseti( L, -2, 0 );                 /* arg[0] = script/program name */
    }
    for ( int I = ProgIdx + 1; I < Argc; I++ ) {
        lua_pushstring( L, Argv[ I ] );
        lua_rawseti( L, -2, I - ProgIdx );        /* arg[1..] = arguments */
    }
    lua_setglobal( L, "arg" );
}

/* Try compiling `<line>` first as an expression (with `return ` prefix)
   so the REPL prints the result of bare expressions like `1 + 2`; on
   syntax error fall through to compiling as a statement. */
static int Clua_LoadReplLine( lua_State *L, const char *Line ) {
    char *Wrapped = ( char * )malloc( strlen( Line ) + 16 );
    if ( Wrapped == NULL ) return -1;
    sprintf( Wrapped, "return %s;", Line );
    int Rc = luaL_loadbuffer( L, Wrapped, strlen( Wrapped ), "=stdin" );
    free( Wrapped );
    if ( Rc == LUA_OK ) return 0;
    /* expression form failed -- discard the error and retry as statement */
    lua_pop( L, 1 );
    return luaL_loadbuffer( L, Line, strlen( Line ), "=stdin" ) == LUA_OK ? 0 : -1;
}

static void Clua_PrintReplResults( lua_State *L, int Top ) {
    int N = lua_gettop( L ) - Top;
    if ( N <= 0 ) return;
    lua_getglobal( L, "print" );
    lua_insert( L, -N - 1 );
    if ( Clua_CallProtected( L, N, 0 ) != LUA_OK ) {
        Clua_PrintError( L );
    }
}

static int Clua_Repl( lua_State *L ) {
    fprintf( stderr, "CLua REPL  -- ^Z + enter to exit\n" );
    char Line[ 4096 ] = { 0 };
    for ( ;; ) {
        fputs( "> ", stderr );
        fflush( stderr );
        if ( fgets( Line, sizeof( Line ), stdin ) == NULL ) break;
        size_t Len = strlen( Line );
        while ( Len > 0 && ( Line[ Len - 1 ] == '\n' || Line[ Len - 1 ] == '\r' ) ) {
            Line[ --Len ] = '\0';
        }
        if ( Len == 0 ) continue;
        int Top = lua_gettop( L );
        if ( Clua_LoadReplLine( L, Line ) != 0 ) {
            Clua_PrintError( L );
            continue;
        }
        if ( Clua_CallProtected( L, 0, LUA_MULTRET ) != LUA_OK ) {
            Clua_PrintError( L );
            continue;
        }
        Clua_PrintReplResults( L, Top );
    }
    return 0;
}

/* Prepend the rover global package store to package.path so the host /
   interpreter can `require` installed third-party packages from disk. Mirrors
   the store location the compiler's Paths_StoreBase resolves at compile time:
   %CLUA_HOME%\packages or %LOCALAPPDATA%\clua\packages. Best-effort. */
static void Clua_SetupModulePath( lua_State *L ) {
    static const char *Code =
        "local home = os.getenv('CLUA_HOME')\n"
        "if not home or home == '' then home = (os.getenv('LOCALAPPDATA') or '.') .. '\\\\clua' end\n"
        "local store = home .. '\\\\packages'\n"
        /* lock-pinned version searcher (multi-version store). Inserted before the
           flat-path searcher so a project's rover.lock pin wins over `latest`. */
        "local function lock_version_ok(v)\n"
        "  return type(v) == 'string' and #v > 0 and #v <= 64\n"
        "    and v:match('^[%w_%.%+%-]+$') ~= nil\n"
        "    and v:sub(1, 1) ~= '.' and v:sub(1, 1) ~= '-'\n"
        "    and not v:find('..', 1, true)\n"
        "end\n"
        "local function locked_version(name)\n"
        "  local f = io.open('rover.lock', 'rb'); if not f then return nil end\n"
        "  local c = f:read('*a') or ''; f:close()\n"
        "  local esc = name:gsub('(%W)', '%%%1')\n"
        "  local v = c:match('%[\"' .. esc .. '\"%]%s*=%s*{[^}]-version%s*=%s*\"([^\"]+)\"')\n"
        "  return lock_version_ok(v) and v or nil\n"
        "end\n"
        "table.insert(package.searchers, 2, function(name)\n"
        "  local v = locked_version(name); if not v then return nil end\n"
        "  local path = store .. '\\\\' .. name:gsub('%.', '\\\\') .. '\\\\' .. v .. '\\\\init.lua'\n"
        "  local chunk = loadfile(path)\n"
        "  if chunk then return chunk, path end\n"
        "  return '\\n\\tno locked-version file ' .. path\n"
        "end)\n"
        /* lock-less / latest: the flat <store>/<name>/init.lua via package.path */
        "package.path = store .. '\\\\?.lua;' .. store .. '\\\\?\\\\init.lua;' .. package.path\n";
    if ( luaL_dostring( L, Code ) != LUA_OK ) {
        lua_pop( L, 1 );   /* ignore — installed-package path is optional */
    }
}

int main( int Argc, char **Argv ) {
    /* clua-interp always interprets: no dispatch hook is ever installed, so
       luaV_execute runs the bytecode interpreter loop (the frozen oracle).
       A leading -i / --interpret is accepted as a NO-OP for compatibility —
       it used to select the interpreter over the (since-removed) v1 JIT,
       and every differential suite still invokes `clua-interp.exe -i ...`. */
    int ArgBase = 1;
    if ( Argc > 1 && ( strcmp( Argv[ 1 ], "-i" ) == 0
                    || strcmp( Argv[ 1 ], "--interpret" ) == 0 ) ) {
        ArgBase = 2;
    }

    if ( !Veh_Init( ) ) {
        fprintf( stderr, "clua-interp: Veh_Init failed (GLE=%lu)\n",
                 ( unsigned long )GetLastError( ) );
        return EXIT_FAILURE;
    }
    Clua_RegisterRuntimeTextRegion( );

    lua_State *L = luaL_newstate( );
    if ( L == NULL ) {
        fprintf( stderr, "clua-interp: out of memory\n" );
        return EXIT_FAILURE;
    }
    Ffi_SetDispatchL( L );
    luaL_openlibs( L );
    Coro_OpenLib( L );
    Clua_InstallPreloads( L );
    Clua_SetupModulePath( L );
    Ctype_Init( );
    Ffi_RegisterWindowsTypes( );
    Ffi_OpenLib( L );

    int Rc = 0;
    if ( Argc <= ArgBase ) {
        Rc = Clua_Repl( L );   /* no script -> REPL */
    } else if ( strcmp( Argv[ ArgBase ], "-e" ) == 0 ) {
        if ( Argc < ArgBase + 2 ) {
            fprintf( stderr, "clua-interp: -e requires a code string\n" );
            Rc = -1;
        } else {
            Clua_PushArgTable( L, Argc, Argv, ArgBase + 1 );  /* arg[0]=code, arg[1..]=args */
            Rc = Clua_DoString( L, Argv[ ArgBase + 1 ], "=(command line)" );
        }
    } else {
        /* run a file: arg[0] = scriptname, arg[1..] = remaining argv */
        Clua_PushArgTable( L, Argc, Argv, ArgBase );
        Rc = Clua_DoFile( L, Argv[ ArgBase ] );
    }

    lua_close( L );
    return Rc == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
