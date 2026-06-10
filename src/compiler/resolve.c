#include "compiler/resolve.h"
#include "compiler/lua_compile.h"

#include "lua.h"
#include "lauxlib.h"
#include "lobject.h"
#include "lopcodes.h"
#include "lundump.h"
#include "lstate.h"
#include "lzio.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Lua 5.4 instruction layout (lopcodes.h):
   format iABx: opcode(7) | A(8) | Bx(17)
   format iABC: opcode(7) | A(8) | B(9) | C(9)  */

/* Recognise GETTABUP A B C ; LOADK A+1 Bx ; CALL A 2 ?  where:
     - GETTABUP's K-arg names "require"  (B index into upvalues, but to keep
       this simple we accept ANY GETTABUP whose K constant is "require")
   We collect the LOADK constant string into Out. */

typedef struct _STR_LIST {
    char  **Items;
    size_t  Count;
    size_t  Cap;
} STR_LIST_T, *PSTR_LIST_T;

static void StrList_Push( PSTR_LIST_T L, const char *S ) {
    if ( L->Count == L->Cap ) {
        size_t N = L->Cap ? L->Cap * 2 : 8;
        L->Items = ( char ** )realloc( L->Items, N * sizeof( char * ) );
        L->Cap   = N;
    }
    L->Items[ L->Count++ ] = strdup( S );
}

static int StrList_Contains( PSTR_LIST_T L, const char *S ) {
    for ( size_t I = 0; I < L->Count; I++ ) {
        if ( strcmp( L->Items[ I ], S ) == 0 ) { return 1; }
    }
    return 0;
}

static void StrList_Free( PSTR_LIST_T L ) {
    for ( size_t I = 0; I < L->Count; I++ ) { free( L->Items[ I ] ); }
    free( L->Items );
    L->Items = NULL; L->Count = 0; L->Cap = 0;
}

/* Module names provided by the runtime via package.preload. The compiler
   must not try to resolve these against the filesystem -- they live inside
   runtime.a as embedded Lua source. The list itself is generated at build
   time from src/runtime/packages/<dir>/ by tools/gen-package-rules.ps1,
   so adding a new package needs no edit to this file. */
#include "_builtin_packages.h"

static int IsBuiltinPackage( const char *Name ) {
    int I = { 0 };
    for ( I = 0; k_BuiltinPackages[ I ] != NULL; I++ ) {
        if ( strcmp( k_BuiltinPackages[ I ], Name ) == 0 ) { return 1; }
    }
    return 0;
}

/* Names that aren't proper preload packages but DO refer to runtime-
   provided facilities. The runtime exposes `ffi` as a Lua global rather
   than via package.preload, so a `require "ffi"` at runtime fails -- but
   packages still wrap it in pcall as a LuaJIT-compat probe. From the
   compiler's perspective the right thing is to skip filesystem lookup
   (else the scanner false-positives on pcall(require, "ffi")) and
   skip preload linking (no _pkg_gen.o exists). The same applies to
   `bit`, which packages probe via `bit or require "bit"` for the
   same reason -- our compat shim is per-file, not a real module. */
static int IsRuntimeOnlyName( const char *Name ) {
    if ( Name == NULL ) return 0;
    return strcmp( Name, "ffi" ) == 0 || strcmp( Name, "bit" ) == 0;
}

/*!
 * @brief
 *  Walk one Proto's instructions, looking for require("literal") calls.
 *  Recurses into child protos.
 */
static void ScanProto( Proto *P, PSTR_LIST_T Out, size_t *Warned, PRESOLVE_RESULT_T Res ) {
    int I = { 0 };

    for ( I = 0; I < P->sizecode; I++ ) {
        Instruction Op   = P->code[ I ];
        OpCode      Code = GET_OPCODE( Op );

        if ( Code == OP_GETTABUP ) {
            int    CIdx = GETARG_C( Op );
            TValue *K   = &P->k[ CIdx ];
            if ( !ttisstring( K ) ) { continue; }
            if ( strcmp( getstr( tsvalue( K ) ), "require" ) != 0 ) { continue; }

            /* next instruction should be LOADK with the module-name constant */
            if ( I + 2 >= P->sizecode ) { continue; }
            Instruction Op2 = P->code[ I + 1 ];
            if ( GET_OPCODE( Op2 ) != OP_LOADK ) {
                /* could be require(variable) — warn */
                ( *Warned )++;
                continue;
            }
            int    BxIdx = GETARG_Bx( Op2 );
            TValue *Kn   = &P->k[ BxIdx ];
            if ( !ttisstring( Kn ) ) { ( *Warned )++; continue; }

            const char *Name = getstr( tsvalue( Kn ) );
            /* `ffi` / `bit`: runtime-provided as globals, not as preload
               packages. Skip both filesystem lookup AND preload registration
               so static-scan false positives like pcall(require, "ffi")
               don't fail the build. */
            if ( IsRuntimeOnlyName( Name ) ) {
                continue;
            }
            /* runtime-provided packages live in runtime.a, not on disk. Some
               of them (e.g. "imgui") still need to influence the link line
               so the compiler pulls in the matching native archive. */
            if ( IsBuiltinPackage( Name ) ) {
                /* require("imgui_helpers") also needs the imgui native
                   archive, since the helpers call cimgui directly. */
                if ( Res != NULL &&
                     ( strcmp( Name, "imgui" )         == 0 ||
                       strcmp( Name, "imgui_helpers" ) == 0 ) ) {
                    Res->RequiresImgui = 1;
                }
                /* Append to BuiltinPackages (dedup). Phase 2 binary
                   tree-shaking: pe_link.c reads this list and only
                   links the matching _pkg_gen.o files. */
                if ( Res != NULL ) {
                    /* Transitive dependency: every `windows.X` sub-package
                       has a `local W = require "windows"` at the top of its
                       source for primitive typedefs (HANDLE, DWORD, etc.).
                       The static walker doesn't recurse into package source
                       (we only see the user's bytecode), so name a hardcoded
                       parent dep here. Same pattern applies to other
                       hierarchical package families when they show up. */
                    const char *Parent = NULL;
                    if ( strncmp( Name, "windows.", 8 ) == 0 ) Parent = "windows";
                    const char *ToAdd[ 2 ] = { Parent, Name };
                    for ( int X = 0; X < 2; X++ ) {
                        if ( ToAdd[ X ] == NULL ) continue;
                        int Already = 0;
                        for ( size_t K = 0; K < Res->BuiltinPackageCount; K++ ) {
                            if ( strcmp( Res->BuiltinPackages[ K ], ToAdd[ X ] ) == 0 ) {
                                Already = 1; break;
                            }
                        }
                        if ( !Already ) {
                            Res->BuiltinPackages = ( char ** )realloc(
                                Res->BuiltinPackages,
                                ( Res->BuiltinPackageCount + 1 ) * sizeof( char * ) );
                            Res->BuiltinPackages[ Res->BuiltinPackageCount++ ] = strdup( ToAdd[ X ] );
                        }
                    }
                }
                continue;
            }
            if ( !StrList_Contains( Out, Name ) ) {
                StrList_Push( Out, Name );
            }
        }
    }

    /* recurse into nested function literals */
    for ( I = 0; I < P->sizep; I++ ) {
        ScanProto( P->p[ I ], Out, Warned, Res );
    }
}

/*!
 * @brief
 *  Parse a Lua source file into a Proto* (without dumping), then scan its
 *  instructions. Returns 1 on success, 0 on parse failure.
 */
static int RequiresOfSource( const char        *Path,
                             PSTR_LIST_T        Out,
                             size_t            *Warned,
                             PRESOLVE_RESULT_T  Res ) {
    lua_State *L  = luaL_newstate( );
    int        Rc = { 0 };

    if ( L == NULL ) { return 0; }
    Rc = luaL_loadfile( L, Path );
    if ( Rc != LUA_OK ) {
        fprintf( stderr, "[-] resolve: load %s :: %s\n", Path, lua_tostring( L, -1 ) );
        lua_close( L );
        return 0;
    }
    /* the loaded closure is at -1; reach for its Proto */
    const LClosure *LC = clLvalue( s2v( L->top.p - 1 ) );
    ScanProto( ( Proto * )LC->p, Out, Warned, Res );
    lua_close( L );
    return 1;
}

static void PushResolved( PRESOLVE_RESULT_T R,
                          const char        *Name,
                          const char        *Path,
                          unsigned char     *Bytes,
                          size_t             BytesLen ) {
    R->Modules = ( PRESOLVED_MODULE_T )realloc(
        R->Modules, ( R->Count + 1 ) * sizeof( RESOLVED_MODULE_T ) );
    R->Modules[ R->Count ].Name     = strdup( Name );
    R->Modules[ R->Count ].Path     = strdup( Path );
    R->Modules[ R->Count ].Bytes    = Bytes;
    R->Modules[ R->Count ].BytesLen = BytesLen;
    R->Count++;
}

/* Map a builtin package name to its on-disk source file under
   src/runtime/packages/. Returns 1 if the file exists and was
   written into OutBuf, 0 otherwise.
     "aes"            -> src/runtime/packages/aes/init.lua
     "windows"        -> src/runtime/packages/windows/init.lua
     "windows.bcrypt" -> src/runtime/packages/windows/bcrypt.lua
   The transitive scan tolerates an absent file (returns 0 without
   warning) because winmd-gen sub-packages and ad-hoc names may not
   live where the simple rule guesses. */
static int BuiltinNameToSourcePath( const char *Name, char *OutBuf, size_t OutBufSize ) {
    if ( Name == NULL || OutBuf == NULL ) return 0;
    const char *Dot = strchr( Name, '.' );
    int Written = 0;
    if ( Dot == NULL ) {
        Written = snprintf( OutBuf, OutBufSize,
                            "src/runtime/packages/%s/init.lua", Name );
    } else {
        size_t HeadLen = ( size_t )( Dot - Name );
        Written = snprintf( OutBuf, OutBufSize,
                            "src/runtime/packages/%.*s/%s.lua",
                            ( int )HeadLen, Name, Dot + 1 );
        /* replace any remaining `.` in the suffix with `/` for deeper
           sub-packages (e.g. windows.foo.bar -> windows/foo/bar.lua) */
        for ( size_t I = strlen( "src/runtime/packages/" ) + HeadLen + 1;
              I < ( size_t )Written && OutBuf[ I ] != '\0'; I++ ) {
            if ( OutBuf[ I ] == '.' && I + 4 < ( size_t )Written ) {
                OutBuf[ I ] = '/';
            }
        }
    }
    if ( Written <= 0 || ( size_t )Written >= OutBufSize ) return 0;
    FILE *F = fopen( OutBuf, "rb" );
    if ( F == NULL ) return 0;
    fclose( F );
    return 1;
}

/* Inject a -L/--link name into the resolve worklists exactly as if the entry
   had require()'d it: builtin names join Out->BuiltinPackages (so the
   transitive scan walks their source), other names go on the user-module
   Queue. Mirrors the classification in ScanProto. */
static void ForceLinkName( PRESOLVE_RESULT_T Out, STR_LIST_T *Queue, const char *Name ) {
    if ( Name == NULL || Name[ 0 ] == '\0' ) return;
    if ( IsRuntimeOnlyName( Name ) ) return;          /* ffi / bit: runtime globals */
    if ( IsBuiltinPackage( Name ) ) {
        if ( strcmp( Name, "imgui" ) == 0 || strcmp( Name, "imgui_helpers" ) == 0 ) {
            Out->RequiresImgui = 1;
        }
        const char *Parent = ( strncmp( Name, "windows.", 8 ) == 0 ) ? "windows" : NULL;
        const char *ToAdd[ 2 ] = { Parent, Name };
        for ( int X = 0; X < 2; X++ ) {
            if ( ToAdd[ X ] == NULL ) continue;
            int Already = 0;
            for ( size_t K = 0; K < Out->BuiltinPackageCount; K++ ) {
                if ( strcmp( Out->BuiltinPackages[ K ], ToAdd[ X ] ) == 0 ) { Already = 1; break; }
            }
            if ( !Already ) {
                char **Grown = ( char ** )realloc( Out->BuiltinPackages,
                                  ( Out->BuiltinPackageCount + 1 ) * sizeof( char * ) );
                if ( Grown == NULL ) return;
                Out->BuiltinPackages = Grown;
                Out->BuiltinPackages[ Out->BuiltinPackageCount++ ] = strdup( ToAdd[ X ] );
            }
        }
    } else {
        StrList_Push( Queue, Name );
    }
}

static void EmitCompileError( PRESOLVE_OPTS_T Opts, const char *Path, const char *ErrMsg ) {
    Diag_PrintCompileError( Path, ErrMsg ? ErrMsg : "(unknown error)", 0, Opts->Diag );
}

int Resolve_Walk( const char *EntryPath, PRESOLVE_OPTS_T Opts, PRESOLVE_RESULT_T Out ) {
    STR_LIST_T           Queue        = { 0 };
    STR_LIST_T           Visited      = { 0 };
    STR_LIST_T           BuiltinDone  = { 0 };
    LUA_COMPILE_RESULT_T C            = { 0 };
    size_t               Warned       = { 0 };

    if ( EntryPath == NULL || Opts == NULL || Opts->PathsOpts == NULL || Out == NULL ) {
        return 0;
    }
    memset( Out, 0, sizeof( *Out ) );

    /* entry module compiled first; named "main" */
    if ( !LuaCompile_File( EntryPath, Opts->Strip, &C ) ) {
        EmitCompileError( Opts, EntryPath, C.ErrMsg );
        LuaCompile_FreeResult( &C );
        return 0;
    }
    PushResolved( Out, "main", EntryPath, C.Bytes, C.BytesLen );
    C.Bytes = NULL; /* ownership transferred */
    LuaCompile_FreeResult( &C );

    /* scan entry for require() targets */
    if ( !RequiresOfSource( EntryPath, &Queue, &Warned, Out ) ) {
        Resolve_FreeResult( Out );
        return 0;
    }
    StrList_Push( &Visited, "main" );

    /* -L/--link: inject forced names as if the entry had require()'d them,
       so they (and their transitive deps) get resolved below. */
    if ( Opts->ForceLink != NULL ) {
        for ( size_t I = 0; I < Opts->ForceLinkCount; I++ ) {
            ForceLinkName( Out, &Queue, Opts->ForceLink[ I ] );
        }
    }

    /* Transitive built-in package scan: after the initial scan populates
       Out->BuiltinPackages from the entry, walk each builtin package's
       on-disk source for further require() calls. New builtins discovered
       get queued + scanned; new non-builtin names land on Queue and get
       picked up by the standard loop below. Idempotent via BuiltinDone. */
    {
        int Progress = 1;
        while ( Progress ) {
            Progress = 0;
            for ( size_t I = 0; I < Out->BuiltinPackageCount; I++ ) {
                const char *Pkg = Out->BuiltinPackages[ I ];
                if ( StrList_Contains( &BuiltinDone, Pkg ) ) continue;
                StrList_Push( &BuiltinDone, Pkg );
                Progress = 1;
                char SrcPath[ 512 ] = { 0 };
                if ( !BuiltinNameToSourcePath( Pkg, SrcPath, sizeof( SrcPath ) ) ) {
                    /* missing source: still tree-shake-link the package
                       (it might be code-generated outside the convention),
                       just skip the transitive scan. */
                    continue;
                }
                if ( !RequiresOfSource( SrcPath, &Queue, &Warned, Out ) ) {
                    StrList_Free( &Queue );
                    StrList_Free( &Visited );
                    StrList_Free( &BuiltinDone );
                    Resolve_FreeResult( Out );
                    return 0;
                }
            }
        }
    }

    while ( Queue.Count > 0 ) {
        char *Name = Queue.Items[ --Queue.Count ];
        if ( StrList_Contains( &Visited, Name ) ) { free( Name ); continue; }

        char Path[ 512 ] = { 0 };
        if ( !Paths_ModuleNameToFilePath( Name, Opts->PathsOpts, Path, sizeof( Path ) ) ) {
            fprintf( stderr, "[-] resolve: cannot map module '%s' to path\n", Name );
            free( Name );
            StrList_Free( &Queue );
            StrList_Free( &Visited );
            StrList_Free( &BuiltinDone );
            Resolve_FreeResult( Out );
            return 0;
        }

        LUA_COMPILE_RESULT_T Ci = { 0 };
        if ( !LuaCompile_File( Path, Opts->Strip, &Ci ) ) {
            EmitCompileError( Opts, Path, Ci.ErrMsg );
            free( Name );
            LuaCompile_FreeResult( &Ci );
            StrList_Free( &Queue );
            StrList_Free( &Visited );
            StrList_Free( &BuiltinDone );
            Resolve_FreeResult( Out );
            return 0;
        }
        PushResolved( Out, Name, Path, Ci.Bytes, Ci.BytesLen );
        Ci.Bytes = NULL;
        LuaCompile_FreeResult( &Ci );
        StrList_Push( &Visited, Name );

        /* scan the just-compiled module for further requires */
        if ( !RequiresOfSource( Path, &Queue, &Warned, Out ) ) {
            free( Name );
            StrList_Free( &Queue );
            StrList_Free( &Visited );
            StrList_Free( &BuiltinDone );
            Resolve_FreeResult( Out );
            return 0;
        }
        free( Name );

        /* Module may have introduced new built-in package requirements
           (e.g. user .lua module require'd "windows.bcrypt"). Drain the
           builtin transitive scan again. */
        int Progress = 1;
        while ( Progress ) {
            Progress = 0;
            for ( size_t I = 0; I < Out->BuiltinPackageCount; I++ ) {
                const char *Pkg = Out->BuiltinPackages[ I ];
                if ( StrList_Contains( &BuiltinDone, Pkg ) ) continue;
                StrList_Push( &BuiltinDone, Pkg );
                Progress = 1;
                char SrcPath[ 512 ] = { 0 };
                if ( !BuiltinNameToSourcePath( Pkg, SrcPath, sizeof( SrcPath ) ) ) continue;
                if ( !RequiresOfSource( SrcPath, &Queue, &Warned, Out ) ) {
                    StrList_Free( &Queue );
                    StrList_Free( &Visited );
                    StrList_Free( &BuiltinDone );
                    Resolve_FreeResult( Out );
                    return 0;
                }
            }
        }
    }
    StrList_Free( &BuiltinDone );

    StrList_Free( &Queue );
    StrList_Free( &Visited );
    Out->WarnCount = Warned;
    return 1;
}

void Resolve_FreeResult( PRESOLVE_RESULT_T R ) {
    if ( R == NULL ) { return; }
    for ( size_t I = 0; I < R->Count; I++ ) {
        free( R->Modules[ I ].Name );
        free( R->Modules[ I ].Path );
        free( R->Modules[ I ].Bytes );
    }
    free( R->Modules );
    R->Modules = NULL;
    R->Count = 0;
    for ( size_t I = 0; I < R->BuiltinPackageCount; I++ ) {
        free( R->BuiltinPackages[ I ] );
    }
    free( R->BuiltinPackages );
    R->BuiltinPackages      = NULL;
    R->BuiltinPackageCount  = 0;
}
