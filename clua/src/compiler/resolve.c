#include "compiler/resolve.h"
#include "compiler/lua_compile.h"
#include "compiler/diag.h"
#include "compiler/diag_pretty.h"
#include "compiler/diag_suggest.h"

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
    if ( strcmp( Name, "ffi" ) == 0 || strcmp( Name, "bit" ) == 0 ) return 1;
    /* The Lua STANDARD LIBRARIES are registered into package.loaded at startup by
    ** aot_entry.c and stdlib_anchors.c, not through package.preload, so
    ** `require "coroutine"` resolves at run time from package.loaded -- but the
    ** compiler must not go looking for a coroutine.lua on disk. Without this,
    ** `print(pcall(require, "coroutine"))` failed to COMPILE with
    ** "cannot open build/tmp/coroutine.lua", where the oracle simply printed
    ** `true  table: ...`. Exactly the false-positive class the ffi/bit entries
    ** above exist for.
    **
    ** These do not need to be force-marked as used: lc_module_used_libs
    ** (opt/passes.c) already scans the constant table for these very names, so a
    ** `require "utf8"` puts "utf8" in the constants, sets LCLIB_UTF8, keeps the
    ** anchor, and the library is registered by the time require runs. */
    {
        static const char *const kStdLibs[] = {
            "_G", "coroutine", "package", "string", "table",
            "math", "io", "os", "utf8", "debug", NULL
        };
        int i;
        for ( i = 0; kStdLibs[i] != NULL; i++ )
            if ( strcmp( Name, kStdLibs[i] ) == 0 ) return 1;
    }
    return 0;
}

/* Scan the entry module's main chunk for a top-level `_exports = { name = fn, ...}`
   assignment and collect the export names.

   The scan is intentionally narrow: it walks ONLY the main chunk's own code
   (not nested protos), which is where a module-scope table literal that is
   later assigned to `_exports` lives. The pattern the Lua 5.4 compiler emits
   for `_exports = { a = fn1, b = fn2 }` is:

     NEWTABLE     RT, 0, N
     EXTRAARG     ...
     CLOSURE      RT+1, PIDX
     SETFIELD     RT, K"a", RT+1
     CLOSURE      RT+1, PIDX2
     SETFIELD     RT, K"b", RT+1
     ...
     SETTABUP     UP"_ENV", K"_exports", RT

   The scan tracks the register `RT` that is the current NEWTABLE target and
   collects every SETFIELD/SETI whose A argument equals RT. When it sees a
   SETTABUP that stores that register into `_exports`, it emits the collected
   names into `Out`. If the pattern doesn't match cleanly (e.g. the user
   assigns _exports = otherTable or builds the table dynamically), the scan
   silently returns no exports — the user just gets an empty DLL and can be
   told by the driver. */
static int StrEq( const char *a, const char *b ) {
    return a != NULL && b != NULL && strcmp( a, b ) == 0;
}

static const char *ConstStr( Proto *P, int idx ) {
    if ( idx < 0 || idx >= P->sizek ) return NULL;
    TValue *k = &P->k[ idx ];
    if ( !ttisstring( k ) ) return NULL;
    return getstr( tsvalue( k ) );
}

static void ExportPush( PRESOLVE_RESULT_T R, const char *Name ) {
    size_t i;
    if ( R == NULL || Name == NULL ) return;
    for ( i = 0; i < R->ExportCount; i++ ) {
        if ( StrEq( R->Exports[ i ].Name, Name ) ) return;
    }
    PRESOLVED_EXPORT_T grown = ( PRESOLVED_EXPORT_T )realloc(
        R->Exports, ( R->ExportCount + 1 ) * sizeof( RESOLVED_EXPORT_T ) );
    if ( grown == NULL ) return;
    R->Exports = grown;
    R->Exports[ R->ExportCount ].Name     = strdup( Name );
    /* Default ABI: (double,double)->double. The first arc supports this
       shape unconditionally; an optional `_export_types = { name = "..." }`
       scan below overrides it on a per-name basis. */
    R->Exports[ R->ExportCount ].AbiShape = strdup( "dd_d" );
    R->ExportCount++;
}

/* Once an entry has an AbiShape assigned to Name, replace it with the
   caller-supplied shape string. Called from the `_export_types` scan below.
   Silently ignores an export that was never declared (a shape override for a
   name that isn't in `_exports = {...}` is a no-op, not an error -- the DLL
   simply won't advertise it). */
static void ExportSetAbiShape( PRESOLVE_RESULT_T R, const char *Name,
                                const char *Shape ) {
    size_t i;
    if ( R == NULL || Name == NULL || Shape == NULL ) return;
    for ( i = 0; i < R->ExportCount; i++ ) {
        if ( StrEq( R->Exports[ i ].Name, Name ) ) {
            free( R->Exports[ i ].AbiShape );
            R->Exports[ i ].AbiShape = strdup( Shape );
            return;
        }
    }
}

/* Scan the main chunk for a top-level `_export_types = { name = "shape", ... }`
   companion table.

   Single forward walk with two active-tracking pieces so string values from
   unrelated tables (`_exports` itself, ordinary module tables) never leak
   into shape overrides:

     - RegStr[i] holds the most recent LOADK'd string constant per register
       (used only when a SETFIELD's value comes from a register rather than
       the inline k-bit path -- long-string values). Short strings, which
       cover every realistic ABI shape token, bypass RegStr entirely.

     - TableReg tracks the register the most recent NEWTABLE targeted; every
       SETFIELD against that register records into a small pending list. If
       the SETTABUP that closes the span names `_export_types`, the list is
       applied; otherwise it is discarded. This way an `_exports = {...}`
       table literal above `_export_types` cannot bleed overrides into
       unrelated exports even when field values happen to be strings.

   Anything not clearly inside a `_export_types` span is ignored -- an
   override that fails to parse just leaves the default "dd_d" in place,
   which preserves the pre-annotation behaviour for anything the user didn't
   touch. */
static void ScanExportTypes( Proto *P, PRESOLVE_RESULT_T Res ) {
    typedef struct { const char *Key; const char *Value; } PENDING_T;
    int I;
    int TableReg = -1;
    PENDING_T *Pending = NULL;
    int NPending = 0, CPending = 0;

    int RegN = 0;
    const char **RegStr = NULL;

    if ( P == NULL || Res == NULL ) return;
    RegN = ( int )P->maxstacksize;
    if ( RegN <= 0 ) RegN = 1;
    RegStr = ( const char ** )calloc( ( size_t )RegN, sizeof( const char * ) );
    if ( RegStr == NULL ) return;

    for ( I = 0; I < P->sizecode; I++ ) {
        Instruction Op = P->code[ I ];
        OpCode      C  = GET_OPCODE( Op );
        int a = GETARG_A( Op );

        if ( C == OP_LOADK ) {
            int bx = GETARG_Bx( Op );
            const char *s = ConstStr( P, bx );
            if ( a >= 0 && a < RegN ) RegStr[ a ] = s;
            continue;
        }

        if ( C == OP_NEWTABLE ) {
            /* start a fresh pending list against a new table register */
            NPending = 0;
            TableReg = a;
            if ( a >= 0 && a < RegN ) RegStr[ a ] = NULL;
            continue;
        }

        if ( C == OP_SETFIELD && TableReg >= 0 && a == TableReg ) {
            const char *Key   = ConstStr( P, GETARG_B( Op ) );
            const char *Value = NULL;
            int         cIsK  = GETARG_k( Op );
            int         cArg  = GETARG_C( Op );
            if ( cIsK ) {
                Value = ConstStr( P, cArg );
            } else if ( cArg >= 0 && cArg < RegN ) {
                Value = RegStr[ cArg ];
            }
            /* Only record entries that look complete. A closure-source
               SETFIELD (Value==NULL) simply drops. */
            if ( Key != NULL && Value != NULL ) {
                if ( NPending == CPending ) {
                    int nc = CPending ? CPending * 2 : 8;
                    PENDING_T *grown = ( PENDING_T * )realloc(
                        Pending, ( size_t )nc * sizeof( PENDING_T ) );
                    if ( grown == NULL ) break;
                    Pending = grown; CPending = nc;
                }
                Pending[ NPending ].Key   = Key;
                Pending[ NPending ].Value = Value;
                NPending++;
            }
            continue;
        }

        if ( C == OP_SETTABUP ) {
            int         cIsK = GETARG_k( Op );
            int         cReg = GETARG_C( Op );
            const char *Key  = ConstStr( P, GETARG_B( Op ) );
            if ( !cIsK && cReg == TableReg && TableReg >= 0 &&
                 StrEq( Key, "_export_types" ) ) {
                int j;
                for ( j = 0; j < NPending; j++ ) {
                    ExportSetAbiShape( Res, Pending[ j ].Key,
                                            Pending[ j ].Value );
                }
                NPending = 0;
                TableReg = -1;
            } else if ( !cIsK && cReg == TableReg ) {
                /* SETTABUP to something else (`_exports`, a user global): the
                   pending list belongs to a different table, so discard it. */
                NPending = 0;
                TableReg = -1;
            }
            continue;
        }

        /* Deliberately do NOT invalidate RegStr[a] on generic writes: doing
           that risks clearing a valid LOADK that a later SETFIELD in the
           same table literal still needs to read. Short-string values go
           inline via the k-bit path and never touch RegStr; the risk of a
           stale LOADK feeding a false override is bounded by the pending-
           list gate above (only SETFIELDs inside a NEWTABLE-...-SETTABUP
           span whose SETTABUP names `_export_types` reach ExportSetAbiShape)
           and by ExportSetAbiShape itself dropping unknown keys. */
        (void)a;
    }

    free( Pending );
    free( RegStr );
}

static void ScanExports( Proto *P, PRESOLVE_RESULT_T Res ) {
    int I;
    int TableReg  = -1;   /* register currently holding a NEWTABLE literal   */
    /* pending field names collected against TableReg, in source order        */
    char **Pending = NULL;
    size_t NPending = 0, CPending = 0;

    if ( P == NULL || Res == NULL ) return;

    for ( I = 0; I < P->sizecode; I++ ) {
        Instruction Op = P->code[ I ];
        OpCode      C  = GET_OPCODE( Op );

        if ( C == OP_NEWTABLE ) {
            /* start (or restart) tracking against this table's register */
            TableReg = GETARG_A( Op );
            /* NEWTABLE is followed by an EXTRAARG carrying the total slot
               count (Lua 5.4). Skip it in the loop by letting the outer
               increment step past it — no action needed here. */
            for ( size_t j = 0; j < NPending; j++ ) free( Pending[ j ] );
            NPending = 0;
            continue;
        }
        if ( TableReg < 0 ) continue;

        if ( ( C == OP_SETFIELD || C == OP_SETI ) &&
             GETARG_A( Op ) == TableReg ) {
            /* SETFIELD's B is a K-index into constants; SETI's B is the
               integer key (uninteresting for named exports). Only named
               entries make it into the export directory. */
            if ( C == OP_SETFIELD ) {
                const char *Name = ConstStr( P, GETARG_B( Op ) );
                if ( Name != NULL ) {
                    if ( NPending == CPending ) {
                        size_t nc = CPending ? CPending * 2 : 8;
                        char **grown = ( char ** )realloc( Pending, nc * sizeof( char * ) );
                        if ( grown == NULL ) break;
                        Pending = grown; CPending = nc;
                    }
                    Pending[ NPending++ ] = strdup( Name );
                }
            }
            continue;
        }

        if ( C == OP_SETTABUP ) {
            /* SETTABUP UP[A][K[B]] := RK(C). Lua 5.4 uses the k-bit of the
               instruction (GETARG_k) to distinguish register from constant
               for the C operand -- unlike 5.3, where bit-8 of C encoded it. */
            int cIsK = GETARG_k( Op );
            int cReg = GETARG_C( Op );
            const char *Key = ConstStr( P, GETARG_B( Op ) );
            if ( !cIsK && cReg == TableReg && StrEq( Key, "_exports" ) ) {
                size_t j;
                for ( j = 0; j < NPending; j++ ) {
                    ExportPush( Res, Pending[ j ] );
                    free( Pending[ j ] );
                }
                NPending = 0;
                TableReg = -1;
            }
        }
    }

    for ( size_t j = 0; j < NPending; j++ ) free( Pending[ j ] );
    free( Pending );
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
                if ( Res != NULL ) Res->RequiresFfi = 1;
                continue;
            }
            /* runtime-provided packages live in runtime.a, not on disk. Some
               of them (e.g. "imgui") still need to influence the link line
               so the compiler pulls in the matching native archive.
               A rover-INSTALLED package of the same name shadows the builtin
               (fall through to ordinary file resolution): the install is
               explicit user intent, and installed packages bundle into AOT
               exes where builtins do not yet. */
            if ( IsBuiltinPackage( Name ) && !Paths_InstalledInStore( Name ) ) {
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
        /* Route the located error through the rustc/clang-style printer so the
           scan-phase failures render the same way as the up-front compile
           failure (file:line:col + snippet + caret). */
        Diag_PrintCompileError( Path, lua_tostring( L, -1 ), 0, NULL );
        lua_close( L );
        return 0;
    }
    /* the loaded closure is at -1; reach for its Proto */
    const LClosure *LC = clLvalue( s2v( L->top.p - 1 ) );
    ScanProto( ( Proto * )LC->p, Out, Warned, Res );
    lua_close( L );
    return 1;
}

/* Public entry: scan the entry module's compiled bytecode for a top-level
   `_exports = {...}` table literal and populate Res->Exports. Called by
   Resolve_Walk after the entry is compiled + pushed. Kept separate from
   ScanProto so an exe build pays nothing (it never invokes this). */
static void ScanEntryExports( const char *Path, PRESOLVE_RESULT_T Res ) {
    lua_State *L  = luaL_newstate( );
    int        Rc;
    if ( L == NULL ) return;
    Rc = luaL_loadfile( L, Path );
    if ( Rc != LUA_OK ) { lua_close( L ); return; }
    const LClosure *LC = clLvalue( s2v( L->top.p - 1 ) );
    ScanExports    ( ( Proto * )LC->p, Res );
    /* Optional shape overrides. Runs AFTER ScanExports so every export it
       overrides is already in the array with the default "dd_d" placeholder. */
    ScanExportTypes( ( Proto * )LC->p, Res );
    lua_close( L );
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
   clua/src/runtime/packages/. Returns 1 if the file exists and was
   written into OutBuf, 0 otherwise.
     "aes"            -> clua/src/runtime/packages/aes/init.lua
     "windows"        -> clua/src/runtime/packages/windows/init.lua
     "windows.bcrypt" -> clua/src/runtime/packages/windows/bcrypt.lua
   The transitive scan tolerates an absent file (returns 0 without
   warning) because winmd-gen sub-packages and ad-hoc names may not
   live where the simple rule guesses. */
static int BuiltinNameToSourcePath( const char *Name, char *OutBuf, size_t OutBufSize ) {
    char Root[ 512 ];
    if ( Name == NULL || OutBuf == NULL ) return 0;
    if ( !Paths_BuiltinPackagesRoot( Root, sizeof( Root ) ) ) return 0;
    const char *Dot = strchr( Name, '.' );
    int Written = 0;
    if ( Dot == NULL ) {
        Written = snprintf( OutBuf, OutBufSize,
                            "%s/%s/init.lua", Root, Name );
    } else {
        size_t HeadLen = ( size_t )( Dot - Name );
        Written = snprintf( OutBuf, OutBufSize,
                            "%s/%.*s/%s.lua", Root,
                            ( int )HeadLen, Name, Dot + 1 );
        /* replace any remaining `.` in the suffix with `/` for deeper
           sub-packages (e.g. windows.foo.bar -> windows/foo/bar.lua) */
        for ( size_t I = strlen( Root ) + 1 + HeadLen + 1;
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
    if ( IsRuntimeOnlyName( Name ) ) {                /* ffi / bit: runtime globals */
        if ( Out != NULL ) Out->RequiresFfi = 1;
        return;
    }
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
    /* Independent scan for the DLL export table on the ENTRY module only.
       The compiler pipeline plumbs the results down to the linker, which
       ignores them for exe output. Nested `require`'d modules never
       contribute exports: only the entry module's `_exports` matters. */
    ScanEntryExports( EntryPath, Out );
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
            char Buf[ 256 ];
            snprintf( Buf, sizeof( Buf ),
                      "cannot map module '%s' to a source path (searched include dirs, base path, package store)",
                      Name );
            LcDiag_PrintError( stderr, EntryPath ? EntryPath : "<source>",
                               0, 0, "error", Buf, NULL );
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

    /* Advisory "did you mean" pass over the entry module's globals.
     * Purely diagnostic (no compile is failed, so byte-identity holds);
     * emits at most one help note per (name, line) pair. Runs AFTER the
     * require worklist so the module set fed to the pool is complete. */
    Resolve_DiagUndefinedGlobals( EntryPath, Out );

    return 1;
}

int Resolve_AppendBuiltinModules( PRESOLVE_RESULT_T Out, PRESOLVE_OPTS_T Opts,
                                  char *Err, size_t ErrLen ) {
    ( void )Opts;
    if ( Err && ErrLen ) Err[ 0 ] = '\0';
    if ( Out == NULL ) return 0;
    for ( size_t I = 0; I < Out->BuiltinPackageCount; I++ ) {
        const char *Pkg = Out->BuiltinPackages[ I ];
        char        SrcPath[ 512 ] = { 0 };
        LUA_COMPILE_RESULT_T C = { 0 };
        int Already = 0;
        for ( size_t K = 0; K < Out->Count; K++ ) {
            if ( strcmp( Out->Modules[ K ].Name, Pkg ) == 0 ) { Already = 1; break; }
        }
        if ( Already ) continue;       /* a rover-installed copy already won */
        if ( !BuiltinNameToSourcePath( Pkg, SrcPath, sizeof( SrcPath ) ) ) {
            if ( Err && ErrLen ) {
                snprintf( Err, ErrLen,
                          "builtin package '%s' has no source under the "
                          "toolchain's packages directory (reinstall CLua, or "
                          "set CLUA_HOME)", Pkg );
            }
            return 0;
        }
        if ( !LuaCompile_File( SrcPath, 0, &C ) ) {
            if ( Err && ErrLen ) {
                snprintf( Err, ErrLen, "compiling builtin package '%s' (%s): %s",
                          Pkg, SrcPath, C.ErrMsg ? C.ErrMsg : "(unknown)" );
            }
            LuaCompile_FreeResult( &C );
            return 0;
        }
        PushResolved( Out, Pkg, SrcPath, C.Bytes, C.BytesLen );
        C.Bytes = NULL;                /* ownership transferred */
        LuaCompile_FreeResult( &C );
    }
    return 1;
}

/* ---------------------------------------------------------------------------
 * "Did you mean" scan for undefined globals.
 *
 * The Lua 5.4 compiler lowers every bare identifier read (`foo`) to
 * `OP_GETTABUP A, _ENV, K"foo"`. We walk every reachable Proto's code[]
 * looking for those, extract the key string, and consult a compilation-wide
 * candidate pool (built from the stdlib names below plus the module's own
 * declared identifiers). Any name absent from the pool is a candidate for
 * a typo suggestion via LcDiag_SuggestName; if a close-enough neighbour
 * exists, we emit a "did you mean" help note pointing at the source
 * location.
 *
 * Behaviour is diagnostic-only: no compile is failed, so byte-identity of
 * correct programs is unchanged. Programs whose globals all resolve
 * against the pool produce zero output from this pass.
 * ------------------------------------------------------------------------- */

/* The stdlib names we consider "always in scope" in a compiled CLua
 * program. These match the runtime's own set (aot_entry.c registers each
 * stdlib and `arg` / `_clua` as globals; runtime_init.c drops the interp-
 * only pseudo-globals like _VERSION so we don't list those). Adding a
 * legitimate never-declared runtime global here silences its false
 * positives; adding a made-up name silences a real one, so keep this
 * list conservative. */
static const char *const k_StdGlobals[] = {
    /* task-specified core set */
    "print", "pairs", "ipairs", "type", "tostring", "tonumber",
    "error", "assert", "pcall", "xpcall", "select",
    "setmetatable", "getmetatable",
    "rawget", "rawset", "rawequal", "rawlen",
    "unpack",
    "table", "string", "math", "io", "os", "utf8", "debug", "coroutine",
    "require",
    /* runtime-supplied globals present in every AOT-compiled program */
    "arg", "_G", "_ENV", "_clua",
    /* frequently-appearing but not in the core set above; keeping the
     * false-positive rate down on realistic programs matters more than
     * a tighter pool. `load`/`loadstring`/`dofile` are banned by the
     * closed-world check but including them here means a bare reference
     * (never called) doesn't ALSO trip a "did you mean" note on top of
     * the eventual closed-world error. */
    "next", "collectgarbage", "load", "loadstring", "dofile",
    "loadfile", "package",
    NULL
};

/* Case-sensitive membership test against a bounded array of names. */
static int InArrayN( const char *const *arr, int n, const char *name ) {
    int i;
    if ( arr == NULL || name == NULL || n <= 0 ) return 0;
    for ( i = 0; i < n; i++ ) {
        if ( arr[ i ] != NULL && strcmp( arr[ i ], name ) == 0 ) return 1;
    }
    return 0;
}

/* Growable pool of const-name pointers. Owns nothing -- points into
 * static k_StdGlobals[], into Proto constant tables (owned by the loader
 * lua_State) and into Res->Modules[i].Name (owned by the resolve
 * result). Freed with free(pool.items) alone. */
typedef struct {
    const char **items;
    int          count;
    int          cap;
} NamePool;

static void Pool_Push( NamePool *P, const char *name ) {
    if ( P == NULL || name == NULL || name[ 0 ] == '\0' ) return;
    /* Dedup to keep the tie-break stable and the linear scan cheap. */
    if ( InArrayN( P->items, P->count, name ) ) return;
    if ( P->count == P->cap ) {
        int          nc = P->cap ? P->cap * 2 : 32;
        const char **ni = ( const char ** )realloc( P->items,
                              ( size_t )nc * sizeof( const char * ) );
        if ( ni == NULL ) return;
        P->items = ni;
        P->cap   = nc;
    }
    P->items[ P->count++ ] = name;
}

/* Walk one Proto's constant table and code[], adding every identifier the
 * function DECLARES to the pool: local variable names (LocVar), globals
 * ASSIGNED via SETTABUP over _ENV, and function definitions (which lower
 * to a SETTABUP of a NEWTABLE/CLOSURE at module scope). Recurses into
 * nested protos so inner-scope declarations feed the pool too -- a name
 * declared as an inner local shouldn't trigger a "did you mean" suggestion
 * for the outer reference to the same name, and vice versa. */
static void PoolAddFromProto( Proto *P, NamePool *Pool ) {
    int i;
    if ( P == NULL || Pool == NULL ) return;

    /* Locals: every named LocVar contributes. Compiler-synthesised
     * placeholders start with '(' (like "(for state)"); those aren't
     * user-typable, so exclude them. */
    for ( i = 0; i < P->sizelocvars; i++ ) {
        const LocVar *lv = &P->locvars[ i ];
        const char   *nm;
        if ( lv->varname == NULL ) continue;
        nm = getstr( lv->varname );
        if ( nm == NULL || nm[ 0 ] == '\0' || nm[ 0 ] == '(' ) continue;
        Pool_Push( Pool, nm );
    }

    /* Globals assigned in this Proto: SETTABUP UP[A][K[B]] := ... where
     * UP[A] is _ENV. We accept every SETTABUP against _ENV rather than
     * confirm the A upvalue is truly _ENV, because assigning to a non-
     * _ENV upvalue-table is exotic (would require `local t = ...; t.x = y`
     * on a captured `t`) and the false-positive direction here is safe
     * (an over-broad pool means we suggest less, never more). */
    for ( i = 0; i < P->sizecode; i++ ) {
        Instruction op = P->code[ i ];
        OpCode      oc = GET_OPCODE( op );
        int         b, ua;
        if ( oc != OP_SETTABUP ) continue;
        ua = GETARG_A( op );
        if ( ua < 0 || ua >= P->sizeupvalues ) continue;
        if ( P->upvalues[ ua ].name == NULL ||
             strcmp( getstr( P->upvalues[ ua ].name ), "_ENV" ) != 0 ) {
            continue;
        }
        b = GETARG_B( op );
        if ( b < 0 || b >= P->sizek ) continue;
        if ( !ttisstring( &P->k[ b ] ) ) continue;
        Pool_Push( Pool, getstr( tsvalue( &P->k[ b ] ) ) );
    }

    for ( i = 0; i < P->sizep; i++ ) {
        PoolAddFromProto( P->p[ i ], Pool );
    }
}

/* Line at pc: greatest abslineinfo anchor <= pc, then walk lineinfo
 * deltas forward. Mirrors warn_unused.c LineAtPc so the two diagnostic
 * passes report the same line for the same instruction. */
static int SuggestLineAtPc( const Proto *P, int pc ) {
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
    for ( i = base_pc + 1; i <= pc && i < P->sizelineinfo; i++ ) {
        ls_byte d = P->lineinfo[ i ];
        if ( ( int )d == -128 /* ABSLINEINFO */ ) continue;
        cur_line += ( int )d;
    }
    return cur_line;
}

/* Get one 1-based source line from Text into Out (no newline). Returns the
 * line length, or -1 if the line doesn't exist. Same shape as diag.c's
 * GetSourceLine -- kept local so this pass doesn't depend on the private
 * helper in that TU. */
static int SuggestGetSourceLine( const char *Text, int Line,
                                 char *Out, size_t OutSize ) {
    int CurLine = 1;
    const char *P = Text;
    size_t I = 0;
    if ( Text == NULL || Line < 1 ) return -1;
    while ( CurLine < Line && *P != '\0' ) {
        if ( *P == '\n' ) CurLine++;
        P++;
    }
    if ( CurLine != Line ) return -1;
    while ( P[ I ] != '\0' && P[ I ] != '\n' && I + 1 < OutSize ) {
        Out[ I ] = ( P[ I ] == '\r' ) ? ' ' : P[ I ];
        I++;
    }
    Out[ I ] = '\0';
    return ( int )I;
}

/* Locate the name inside the source line (word-boundary check so `xy`
 * inside `xyz` doesn't match), returning a 1-based column. Falls back to
 * column 1 when the name isn't visible on the line (e.g. spilled over a
 * continuation). */
static int SuggestNameColumn( const char *line, const char *name ) {
    size_t nlen;
    const char *p;
    if ( line == NULL || name == NULL ) return 1;
    nlen = strlen( name );
    if ( nlen == 0 ) return 1;
    for ( p = line; *p != '\0'; p++ ) {
        if ( strncmp( p, name, nlen ) == 0 ) {
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
            if ( !prev_id && !next_id ) return ( int )( p - line ) + 1;
        }
    }
    return 1;
}

/* Track (name, pc) pairs already reported so a repeated `foo()` inside a
 * loop only earns one help note, not one per bytecode reference. Small
 * fixed cap because the pass is intentionally noisy-averse; if a program
 * has more than 64 distinct undefined-global-with-suggestion pairs, the
 * later ones just don't print (the first 64 are already telling). */
typedef struct { const char *name; int line; } SeenPair;

/* Walk one Proto's code[] for OP_GETTABUP through the _ENV upvalue whose
 * K string isn't in the pool. For each such reference, ask
 * LcDiag_SuggestName for a suggestion; if one comes back, emit a
 * two-line diagnostic: an error header identifying the undefined name,
 * followed by a `help:` note carrying the suggestion. Recurses into
 * nested protos so a typo in an inner function is reported too. */
static void ScanProtoUndef( Proto *P, const char *SourcePath,
                            const char *SourceText, NamePool *Pool,
                            SeenPair *Seen, int *SeenN, int SeenCap ) {
    int i;
    if ( P == NULL ) return;

    for ( i = 0; i < P->sizecode; i++ ) {
        Instruction op = P->code[ i ];
        OpCode      oc = GET_OPCODE( op );
        int         ua, kidx;
        const char *name;
        char        suggestion[ 64 ];
        int         line, col, j, already, srclen;
        char        line_buf[ 1024 ];
        char        msg[ 256 ];

        if ( oc != OP_GETTABUP ) continue;
        ua = GETARG_B( op );
        if ( ua < 0 || ua >= P->sizeupvalues ) continue;
        if ( P->upvalues[ ua ].name == NULL ||
             strcmp( getstr( P->upvalues[ ua ].name ), "_ENV" ) != 0 ) {
            continue;
        }
        kidx = GETARG_C( op );
        if ( kidx < 0 || kidx >= P->sizek ) continue;
        if ( !ttisstring( &P->k[ kidx ] ) ) continue;
        name = getstr( tsvalue( &P->k[ kidx ] ) );
        if ( name == NULL || name[ 0 ] == '\0' ) continue;

        /* In-pool means "defined somewhere in the program": skip. */
        if ( InArrayN( Pool->items, Pool->count, name ) ) continue;

        /* Ask the suggester. If it returns 0, either the name is too short
         * for the confident-suggestion floor or no candidate lay within
         * the edit-distance bound -- either way, stay quiet: a compile-time
         * warning without an actionable fix is just noise. */
        if ( !LcDiag_SuggestName( name, Pool->items, Pool->count,
                                  suggestion, sizeof( suggestion ) ) ) {
            continue;
        }

        line = SuggestLineAtPc( P, i );
        already = 0;
        for ( j = 0; j < *SeenN; j++ ) {
            if ( Seen[ j ].line == line && Seen[ j ].name != NULL &&
                 strcmp( Seen[ j ].name, name ) == 0 ) {
                already = 1; break;
            }
        }
        if ( already ) continue;
        if ( *SeenN < SeenCap ) {
            Seen[ *SeenN ].name = name;
            Seen[ *SeenN ].line = line;
            ( *SeenN )++;
        } else {
            /* Cap reached: emit the reference we discovered but stop
             * remembering, so repeated names past this point still risk
             * duplicating -- an acceptable trade against unbounded state. */
        }

        srclen = -1;
        if ( SourceText != NULL ) {
            srclen = SuggestGetSourceLine( SourceText, line, line_buf,
                                           sizeof( line_buf ) );
        }
        col = ( srclen >= 0 ) ? SuggestNameColumn( line_buf, name ) : 1;

        snprintf( msg, sizeof( msg ),
                  "undefined variable '%s'", name );
        LcDiag_PrintError( stderr, SourcePath, line, col,
                           "warning[Wundef]", msg,
                           ( srclen >= 0 ) ? line_buf : NULL );

        snprintf( msg, sizeof( msg ),
                  "did you mean '%s'?", suggestion );
        LcDiag_PrintError( stderr, SourcePath, line, col,
                           "help", msg,
                           ( srclen >= 0 ) ? line_buf : NULL );
    }

    for ( i = 0; i < P->sizep; i++ ) {
        ScanProtoUndef( P->p[ i ], SourcePath, SourceText, Pool,
                        Seen, SeenN, SeenCap );
    }
}

void Resolve_DiagUndefinedGlobals( const char *EntryPath, PRESOLVE_RESULT_T Res ) {
    lua_State *L;
    NamePool   Pool  = { 0 };
    char      *Src   = NULL;
    size_t     SrcLen = 0;
    SeenPair   Seen[ 64 ];
    int        SeenN = 0;

    if ( EntryPath == NULL ) return;

    /* Seed the pool with always-in-scope stdlib globals first so tie-break
     * (earliest wins at equal distance) favours the "real" name over any
     * later-added candidate: `pritn` should prefer `print` (stdlib) rather
     * than a same-distance user local `paint`. */
    {
        int i;
        for ( i = 0; k_StdGlobals[ i ] != NULL; i++ ) {
            Pool_Push( &Pool, k_StdGlobals[ i ] );
        }
    }
    /* require'd modules become identifiers the program is allowed to
     * reference by their dotted name -- but a `require "json"` typically
     * gets bound to a local; the plausible typo is `require "jsson"`
     * which the require scan handles elsewhere. Add module names to the
     * pool anyway so a stray `json` reference (some programs assign to a
     * table with that name) doesn't false-positive. */
    if ( Res != NULL ) {
        size_t i;
        for ( i = 0; i < Res->Count; i++ ) {
            Pool_Push( &Pool, Res->Modules[ i ].Name );
        }
        for ( i = 0; i < Res->BuiltinPackageCount; i++ ) {
            Pool_Push( &Pool, Res->BuiltinPackages[ i ] );
        }
    }

    L = luaL_newstate( );
    if ( L == NULL ) { free( Pool.items ); return; }
    if ( luaL_loadfile( L, EntryPath ) != LUA_OK ) {
        /* Front-end already printed the compile error via Resolve_Walk;
         * nothing left to scan. */
        lua_close( L );
        free( Pool.items );
        return;
    }
    {
        Proto *P = ( Proto * )clLvalue( s2v( L->top.p - 1 ) )->p;
        PoolAddFromProto( P, &Pool );

        /* Slurp the source once for snippet lines; NULL just means the
         * printer omits the source/caret rows. SrcLen is retained by the
         * signature but not used here -- the snippet copier stops at NUL. */
        Src = Diag_SlurpFile( EntryPath, &SrcLen );
        ( void )SrcLen;

        ScanProtoUndef( P, EntryPath, Src, &Pool,
                        Seen, &SeenN,
                        ( int )( sizeof( Seen ) / sizeof( Seen[ 0 ] ) ) );
    }

    free( Src );
    lua_close( L );
    free( Pool.items );
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
    for ( size_t I = 0; I < R->ExportCount; I++ ) {
        free( R->Exports[ I ].Name );
        free( R->Exports[ I ].AbiShape );
    }
    free( R->Exports );
    R->Exports      = NULL;
    R->ExportCount  = 0;
}
