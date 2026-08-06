#include "common/version.h"
#include "common/blob_format.h"
#include "common/stream_cipher.h"
#include "compiler/lua_compile.h"
#include "compiler/blob.h"
#include "compiler/pe_link.h"
#include "compiler/resolve.h"
#include "compiler/paths.h"
#include "compiler/diag.h"
#include "compiler/diag_pretty.h"
#include "_lint_src.h"   /* g_LintSource: lint engine embedded at build time */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <io.h>
#include <windows.h>

typedef struct _CLI {
    const char       *SourcePath;
    const char       *OutputPath;
    const char       *RuntimeArchive;
    const char       *LuaArchive;
    const char       *ImguiArchive;     /* set by --imgui or auto-detect */
    int               ImguiUserSet;     /* user explicitly asked for it */
    const char       *Subsystem;
    const char       *IncludeDirs[ 33 ];
    int               IncludeCount;
    const char       *ForceLink[ 64 ];  /* -L/--link: force-bundled package names */
    int               ForceLinkCount;
    PE_OUTPUT_TYPE_T  OutputType;
    int               Strip;            /* --strip: drop Lua debug info */
    int               Encrypt;          /* --encrypt: stream-cipher blob payload */
    int               Randomize;        /* --randomize: random ImageBase + random section names */
    int               RichHeaderStrip;  /* --rich-header-strip: zero Rich header (toolchain fingerprint) */
    int               LuaVersionStrip;  /* --lua-version-strip: runtime nils out _VERSION + copyright strings */
    /* -- Batch 1: post-link/link-flag features. Each composes with the
       others; runtime-side effect is zero (these tune the linker output
       only). */
    int               GcSections;       /* --gc-sections: -ffunction/-fdata-sections + -Wl,--gc-sections */
    int               HighEntropyVa;    /* --high-entropy-va: -Wl,--high-entropy-va for 64-bit ASLR (8 TB range) */
    int               VerifyPeFlags;    /* --verify-pe-flags: post-link assert on DllCharacteristics bits */
    /* -- Batch 2: compile-time hardening for the per-build blob.o +
       pkgrefs.o (runtime.a stays at the baseline produced by the
       Makefile). Runtime-side effect is zero; these only protect the
       freshly-compiled per-binary objects. */
    int               StackProtector;   /* --stack-protector: -fstack-protector-strong (libssp; canary on stack frames) */
    int               FortifySource;    /* --fortify-source: -D_FORTIFY_SOURCE=2 (libc bounds checks) */
    int               StackClash;       /* --stack-clash: -fstack-clash-protection (probes large stack allocs) */
    int               CfProtection;     /* --cf-protection: -fcf-protection=full (Intel CET IBT+SHSTK) */
    /* -- Batch 3: size-oriented compile/link flags. */
    int               OptimizeSize;     /* --optimize-size: -Os on compile + link (favor size over speed) */
    int               Lto;              /* --lto: -flto on compile + link (link-time optimization, dead-code drops) */
    int               NoUnwind;         /* --no-unwind: -fno-asynchronous-unwind-tables -fno-unwind-tables (drops .pdata/.xdata) */
    int               MergeConstants;   /* --merge-constants: -fmerge-all-constants -fmerge-constants (collapse identical literals) */
    /* -- Batch 5: Lua surface trimming. The --no-lua-* flags generate
       a custom luaL_openlibs override (linit_override.c) that omits
       the requested libs; the linker then drops the unreferenced
       .o members of liblua54.a via standard archive resolution. */
    int               NoLuaIolib;       /* --no-lua-iolib: drop io.* */
    int               NoLuaOslib;       /* --no-lua-oslib: drop os.* */
    int               NoLuaDblib;       /* --no-lua-dblib: drop debug.* */
    int               LuaSandbox;       /* --lua-sandbox: runtime removes dangerous globals at startup */
    /* -- Batch 8: bytecode-only mode. */
    int               BytecodeOnly;     /* --bytecode-only: stub luaY_parser, drop lparser.o + lcode.o from link */
    /* -- Batch 10: JIT-only mode. */
    int               JitOnly;          /* --jit-only: stub luaV_execute, drop lvm.o; non-JIT-compilable funcs abort */
    /* -- Batch 11: payload compression. */
    int               CompressBlob;     /* --compress-blob: XPRESS_HUFF the payload region; runtime decompresses pre-BlobReader */
    /* -- Batch 12: explicit require-pruning. Static reachability
       analysis on Lua bytecode (`if false then require(X) end`)
       requires non-trivial dataflow on the post-parse instruction
       stream + K-table; it's deferred to a future batch. This flag
       gives the user an explicit override knob in the meantime: a
       comma-separated list of package names to drop from the bundled
       set even if the scanner finds them. */
    const char       *PrunePackages;    /* --prune-packages a,b,c */
    /* -- Native-DLL embedding (post-package-wave). Each package can
       declare requires_native in its package.lua; the compiler
       reads the auto-generated _builtin_native_deps.h to know which
       DLLs each required package needs. Default mode "embed" bakes
       the DLL bytes into the PE and the runtime's Native_Bootstrap
       extracts them to %TEMP% on startup. */
    const char       *NativeMode;       /* --native-mode embed|sidecar|system (default embed) */
    const char       *NativeModeFor;    /* --native-mode-for sqlite=sidecar,pcre=system (per-pkg override list) */
    const char       *NativeDir;        /* --native-dir <path> (default vendor/native) */
    /* -- Diagnostics (compiler "intellisense"). The lint pass is ON by
       default: it emits located warnings/info for the user's modules.
       Syntax errors always print gcc/clang-style regardless of these. */
    int               NoWarn;           /* -w / --no-warn: skip the advisory lint pass */
    int               WarningsAsErrors; /* --Werror: turn lint findings into build failures */
    /* --color=<auto|always|never>: override the auto-detected color mode. auto
       (the default) enables color only when stderr is a TTY that understands
       ANSI, unless NO_COLOR is set or CLICOLOR_FORCE forces it. */
    LC_DIAG_COLOR_MODE_T ColorMode;
    /* --diagnostics-format=<text|json>: swap the pretty printer for the
       rustc-shaped JSON writer. Editor / LSP shims that already speak rustc
       JSON can then consume CLua diagnostics without a text parser. Default
       is text so the existing byte-for-byte output is preserved. */
    LC_DIAG_FORMAT_T     DiagFormat;
} CLI_T, *PCLI_T;


/*!
 * @brief
 *  Fill Out with KeyLen bytes of unpredictable data. Tries the
 *  Windows CSPRNG (BCryptGenRandom via bcrypt.dll) first; falls back
 *  to a multi-source seed feeding rand() if the dll isn't loadable
 *  (e.g. running under wine without bcrypt). The fallback path is
 *  not cryptographically random but is fine for `--encrypt`'s
 *  threat model -- the key lives in the header next to the
 *  ciphertext anyway.
 */
static void FillRandom( uint8_t *Out, size_t KeyLen ) {
    HMODULE Bcrypt = LoadLibraryA( "bcrypt.dll" );
    if ( Bcrypt != NULL ) {
        typedef LONG ( WINAPI *PBCryptGenRandom )( void *, PUCHAR, ULONG, ULONG );
        PBCryptGenRandom Gen = ( PBCryptGenRandom )( void * )
            GetProcAddress( Bcrypt, "BCryptGenRandom" );
        if ( Gen != NULL ) {
            /* BCRYPT_USE_SYSTEM_PREFERRED_RNG = 0x00000002 */
            if ( Gen( NULL, ( PUCHAR )Out, ( ULONG )KeyLen, 0x00000002 ) == 0 ) {
                FreeLibrary( Bcrypt );
                return;
            }
        }
        FreeLibrary( Bcrypt );
    }
    /* Fallback: mix several time sources and use rand(). */
    unsigned Seed = ( unsigned )time( NULL )
                  ^ ( unsigned )GetTickCount( )
                  ^ ( unsigned )GetCurrentProcessId( );
    srand( Seed );
    for ( size_t I = 0; I < KeyLen; I++ ) {
        Out[ I ] = ( uint8_t )( rand( ) & 0xFF );
    }
}

static int ParseOutputType( const char *S, PE_OUTPUT_TYPE_T *Out ) {
    if ( strcmp( S, "exe" )  == 0 ) { *Out = PE_OUT_EXE;  return 1; }
    if ( strcmp( S, "dll" )  == 0 ) { *Out = PE_OUT_DLL;  return 1; }
    if ( strcmp( S, "obj" )  == 0 ) { *Out = PE_OUT_OBJ;  return 1; }
    if ( strcmp( S, "lib" )  == 0 ) { *Out = PE_OUT_LIB;  return 1; }
    if ( strcmp( S, "blob" ) == 0 ) { *Out = PE_OUT_BLOB; return 1; }
    return 0;
}

static const char *DefaultOutputName( PE_OUTPUT_TYPE_T Type ) {
    switch ( Type ) {
        case PE_OUT_DLL:  return "out.dll";
        case PE_OUT_OBJ:  return "out.o";
        case PE_OUT_LIB:  return "out.a";
        case PE_OUT_BLOB: return "out.clua-interp";
        case PE_OUT_EXE:
        default:          return "out.exe";
    }
}

static int ParseArgv( int Argc, char **Argv, PCLI_T Cli ) {
    int I             = { 0 };
    int OutputSet     = { 0 };
    memset( Cli, 0, sizeof( *Cli ) );
    /* Defaults: point at the embedded (size-optimized + hardened)
       variants of runtime.a and liblua54.a + the matching per-package
       _pkg_gen.o directory. The host variants (no `-embedded` suffix)
       stay available for clua-interp.exe + the unit tests, and can be
       requested explicitly via --runtime / --lualib. */
    Cli->RuntimeArchive = "build/bin/runtime-embedded.a";
    Cli->LuaArchive     = "build/bin/liblua54-embedded.a";
    Cli->ImguiArchive   = "build/bin/imgui.a";  /* auto-linked when require("imgui") seen */
    Cli->Subsystem      = "console";
    Cli->OutputType     = PE_OUT_EXE;
    for ( I = 1; I < Argc; I++ ) {
        if ( strcmp( Argv[ I ], "-o" ) == 0 && I + 1 < Argc ) {
            Cli->OutputPath = Argv[ ++I ];
            OutputSet = 1;
        } else if ( ( strcmp( Argv[ I ], "-L" ) == 0
                   || strcmp( Argv[ I ], "--link" ) == 0 ) && I + 1 < Argc ) {
            /* Force-bundle a package the static require scan can't see
               (dynamic require(var) / conditional require). Accepts dotted
               names (windows.bcrypt). */
            if ( Cli->ForceLinkCount < 63 ) {
                Cli->ForceLink[ Cli->ForceLinkCount++ ] = Argv[ ++I ];
                Cli->ForceLink[ Cli->ForceLinkCount ]   = NULL;
            } else {
                I++;  /* consume the value even when the table is full */
            }
        } else if ( strcmp( Argv[ I ], "-I" ) == 0 && I + 1 < Argc ) {
            if ( Cli->IncludeCount < 32 ) {
                Cli->IncludeDirs[ Cli->IncludeCount++ ] = Argv[ ++I ];
                Cli->IncludeDirs[ Cli->IncludeCount ]   = NULL;
            } else {
                I++;
            }
        } else if ( strcmp( Argv[ I ], "--runtime" ) == 0 && I + 1 < Argc ) {
            Cli->RuntimeArchive = Argv[ ++I ];
        } else if ( strcmp( Argv[ I ], "--lualib" ) == 0 && I + 1 < Argc ) {
            Cli->LuaArchive = Argv[ ++I ];
        } else if ( strcmp( Argv[ I ], "--imgui" ) == 0 && I + 1 < Argc ) {
            Cli->ImguiArchive = Argv[ ++I ];
            Cli->ImguiUserSet = 1;
        } else if ( strcmp( Argv[ I ], "--no-imgui" ) == 0 ) {
            Cli->ImguiArchive = NULL;
            Cli->ImguiUserSet = 1;
        } else if ( strcmp( Argv[ I ], "--subsystem" ) == 0 && I + 1 < Argc ) {
            Cli->Subsystem = Argv[ ++I ];
        } else if ( ( strcmp( Argv[ I ], "--type" ) == 0
                   || strcmp( Argv[ I ], "-t" ) == 0 ) && I + 1 < Argc ) {
            if ( !ParseOutputType( Argv[ ++I ], &Cli->OutputType ) ) {
                fprintf( stderr, "[-] unknown --type '%s' "
                                 "(expected: exe|dll|obj|lib|blob)\n",
                         Argv[ I ] );
                return 0;
            }
        } else if ( strcmp( Argv[ I ], "--strip" ) == 0 ) {
            Cli->Strip = 1;
        } else if ( strcmp( Argv[ I ], "-w" ) == 0 ||
                    strcmp( Argv[ I ], "--no-warn" ) == 0 ) {
            Cli->NoWarn = 1;
        } else if ( strcmp( Argv[ I ], "--Werror" ) == 0 ||
                    strcmp( Argv[ I ], "--warnings-as-errors" ) == 0 ) {
            Cli->WarningsAsErrors = 1;
        } else if ( strncmp( Argv[ I ], "--color=", 8 ) == 0 ) {
            if ( !LcDiag_ParseColorMode( Argv[ I ] + 8, &Cli->ColorMode ) ) {
                fprintf( stderr, "[-] unknown --color '%s' (expected: auto|always|never)\n",
                         Argv[ I ] + 8 );
                return 0;
            }
        } else if ( strcmp( Argv[ I ], "--color" ) == 0 && I + 1 < Argc ) {
            if ( !LcDiag_ParseColorMode( Argv[ ++I ], &Cli->ColorMode ) ) {
                fprintf( stderr, "[-] unknown --color '%s' (expected: auto|always|never)\n",
                         Argv[ I ] );
                return 0;
            }
        } else if ( strncmp( Argv[ I ], "--diagnostics-format=", 21 ) == 0 ) {
            if ( !LcDiag_ParseFormat( Argv[ I ] + 21, &Cli->DiagFormat ) ) {
                fprintf( stderr,
                         "[-] unknown --diagnostics-format '%s' (expected: text|json)\n",
                         Argv[ I ] + 21 );
                return 0;
            }
        } else if ( strcmp( Argv[ I ], "--diagnostics-format" ) == 0 && I + 1 < Argc ) {
            if ( !LcDiag_ParseFormat( Argv[ ++I ], &Cli->DiagFormat ) ) {
                fprintf( stderr,
                         "[-] unknown --diagnostics-format '%s' (expected: text|json)\n",
                         Argv[ I ] );
                return 0;
            }
        } else if ( strcmp( Argv[ I ], "--encrypt" ) == 0 ) {
            Cli->Encrypt = 1;
        } else if ( strcmp( Argv[ I ], "--randomize" ) == 0 ) {
            Cli->Randomize = 1;
        } else if ( strcmp( Argv[ I ], "--rich-header-strip" ) == 0 ) {
            Cli->RichHeaderStrip = 1;
        } else if ( strcmp( Argv[ I ], "--gc-sections" ) == 0 ) {
            Cli->GcSections = 1;
        } else if ( strcmp( Argv[ I ], "--high-entropy-va" ) == 0 ) {
            Cli->HighEntropyVa = 1;
        } else if ( strcmp( Argv[ I ], "--verify-pe-flags" ) == 0 ) {
            Cli->VerifyPeFlags = 1;
        } else if ( strcmp( Argv[ I ], "--stack-protector" ) == 0 ) {
            Cli->StackProtector = 1;
        } else if ( strcmp( Argv[ I ], "--fortify-source" ) == 0 ) {
            Cli->FortifySource = 1;
        } else if ( strcmp( Argv[ I ], "--stack-clash" ) == 0 ) {
            Cli->StackClash = 1;
        } else if ( strcmp( Argv[ I ], "--cf-protection" ) == 0 ) {
            Cli->CfProtection = 1;
        } else if ( strcmp( Argv[ I ], "--optimize-size" ) == 0 ) {
            Cli->OptimizeSize = 1;
        } else if ( strcmp( Argv[ I ], "--lto" ) == 0 ) {
            Cli->Lto = 1;
        } else if ( strcmp( Argv[ I ], "--no-unwind" ) == 0 ) {
            Cli->NoUnwind = 1;
        } else if ( strcmp( Argv[ I ], "--merge-constants" ) == 0 ) {
            Cli->MergeConstants = 1;
        } else if ( strcmp( Argv[ I ], "--no-lua-iolib" ) == 0 ) {
            Cli->NoLuaIolib = 1;
        } else if ( strcmp( Argv[ I ], "--no-lua-oslib" ) == 0 ) {
            Cli->NoLuaOslib = 1;
        } else if ( strcmp( Argv[ I ], "--no-lua-dblib" ) == 0 ) {
            Cli->NoLuaDblib = 1;
        } else if ( strcmp( Argv[ I ], "--lua-version-strip" ) == 0 ) {
            Cli->LuaVersionStrip = 1;
        } else if ( strcmp( Argv[ I ], "--lua-sandbox" ) == 0 ) {
            Cli->LuaSandbox = 1;
        } else if ( strcmp( Argv[ I ], "--bytecode-only" ) == 0 ) {
            Cli->BytecodeOnly = 1;
        } else if ( strcmp( Argv[ I ], "--jit-only" ) == 0 ) {
            Cli->JitOnly = 1;
        } else if ( strcmp( Argv[ I ], "--compress-blob" ) == 0 ) {
            Cli->CompressBlob = 1;
        } else if ( strcmp( Argv[ I ], "--prune-packages" ) == 0 && I + 1 < Argc ) {
            Cli->PrunePackages = Argv[ ++I ];
        } else if ( strcmp( Argv[ I ], "--native-mode" ) == 0 && I + 1 < Argc ) {
            Cli->NativeMode = Argv[ ++I ];
        } else if ( strcmp( Argv[ I ], "--native-mode-for" ) == 0 && I + 1 < Argc ) {
            Cli->NativeModeFor = Argv[ ++I ];
        } else if ( strcmp( Argv[ I ], "--native-dir" ) == 0 && I + 1 < Argc ) {
            Cli->NativeDir = Argv[ ++I ];
        } else if ( Argv[ I ][ 0 ] != '-' && Cli->SourcePath == NULL ) {
            Cli->SourcePath = Argv[ I ];
        }
    }
    if ( !OutputSet ) {
        Cli->OutputPath = DefaultOutputName( Cli->OutputType );
    }
    return Cli->SourcePath != NULL;
}

static const char *DirOf( const char *Path, char *Buf, size_t BufSize ) {
    size_t L = strlen( Path );
    size_t I = { 0 };
    if ( L >= BufSize ) { return "."; }
    memcpy( Buf, Path, L + 1 );
    for ( I = L; I > 0; I-- ) {
        if ( Buf[ I - 1 ] == '/' || Buf[ I - 1 ] == '\\' ) {
            Buf[ I - 1 ] = '\0';
            return Buf;
        }
    }
    return ".";
}

int main( int Argc, char **Argv ) {
    CLI_T Cli = { 0 };
    char  DirBuf[ 512 ] = { 0 };
    PATHS_OPTS_T Paths = { 0 };
    RESOLVE_OPTS_T Opts = { 0 };
    RESOLVE_RESULT_T Resolved = { 0 };
    PBLOB_MODULE_T BlobMods = { 0 };
    BLOB_BUILD_RESULT_T Built = { 0 };
    PE_LINK_OPTS_T LinkOpts = { 0 };
    size_t I = { 0 };

    printf( "[*] CLua compiler v%s\n", CLUA_VERSION_STRING );
    if ( !ParseArgv( Argc, Argv, &Cli ) ) {
        printf( "[_] usage: compiler.exe <main.lua> [-o output] "
                "[-I include_dir]... [--runtime path] [--lualib path] "
                "[--imgui path | --no-imgui] "
                "[--subsystem console|windows] [--type|-t exe|dll|obj|lib|blob]\n"
                "      diag:     [-w|--no-warn] [--Werror] [--color=auto|always|never] "
                "[--diagnostics-format=text|json]\n"
                "      payload:  [--strip] [--encrypt] [--randomize] "
                "[--rich-header-strip]\n"
                "      link:     [--gc-sections] [--high-entropy-va] "
                "[--verify-pe-flags]\n"
                "      harden:   [--stack-protector] [--fortify-source] "
                "[--stack-clash] [--cf-protection]\n"
                "      size:     [--optimize-size] [--lto] [--no-unwind] "
                "[--merge-constants]\n"
                "      lua:      [--no-lua-iolib] [--no-lua-oslib] "
                "[--no-lua-dblib] [--lua-version-strip] [--lua-sandbox]\n"
                "                [--bytecode-only] [--jit-only]\n"
                "      compress: [--compress-blob]\n"
                "      prune:    [--prune-packages name1,name2,...]\n"
                "      native:   [--native-mode embed|sidecar|system] "
                "[--native-mode-for pkg=mode,...] [--native-dir <path>]\n" );
        return EXIT_FAILURE;
    }

    Paths.BasePath      = DirOf( Cli.SourcePath, DirBuf, sizeof( DirBuf ) );
    Paths.IncludeDirs   = Cli.IncludeDirs;
    Opts.PathsOpts      = &Paths;
    Opts.Strip          = Cli.Strip;
    Opts.ForceLink      = ( Cli.ForceLinkCount > 0 ) ? Cli.ForceLink : NULL;
    Opts.ForceLinkCount = ( size_t )Cli.ForceLinkCount;

    /* Diagnostics: rich clang/rustc-style compile errors always; the advisory
       lint pass (warnings/info) is on unless -w/--no-warn. Color goes through
       LcDiag_SetColorMode -- the printer probes GetConsoleMode +
       ENABLE_VIRTUAL_TERMINAL_PROCESSING itself, and honors NO_COLOR /
       CLICOLOR_FORCE under --color=auto. */
    LcDiag_SetColorMode( Cli.ColorMode );
    LcDiag_SetFormat   ( Cli.DiagFormat );
    DIAG_OPTS_T Diag = { 0 };
    Diag.Warnings         = Cli.NoWarn ? 0 : 1;
    Diag.WarningsAsErrors = Cli.WarningsAsErrors;
    Diag.Color            = 0;    /* unused by the printer since diag_pretty landed */
    Opts.Diag             = &Diag;

    if ( !Resolve_Walk( Cli.SourcePath, &Opts, &Resolved ) ) {
        printf( "[-] resolve failed\n" );
        Resolve_FreeResult( &Resolved );
        return EXIT_FAILURE;
    }
    if ( Resolved.WarnCount > 0 ) {
        if ( Cli.ForceLinkCount > 0 ) {
            /* -L was used: some/all of those dynamic requires may already be
               covered by a force-linked package. The static scan can't match a
               require(var) to a -L name, so report both and let the user confirm
               coverage rather than implying nothing was bundled. */
            int K;
            printf( "[!] %zu dynamic require(...) call(s) skipped by the static "
                    "scan; %d force-linked via -L (",
                    Resolved.WarnCount, Cli.ForceLinkCount );
            for ( K = 0; K < Cli.ForceLinkCount; K++ ) {
                printf( "%s%s", K ? ", " : "", Cli.ForceLink[ K ] );
            }
            printf( ") -- verify each dynamic require is covered\n" );
        } else {
            printf( "[!] %zu dynamic require(...) call(s) skipped by the static "
                    "scan; bundle them explicitly with -L <pkg> (e.g. -L json)\n",
                    Resolved.WarnCount );
        }
    }

    /* Advisory lint pass over the user's own modules. The lint engine source is
       embedded into compiler.exe at build time (build/gen/_lint_src.h) so
       warnings work wherever the compiler runs from, not just the repo root.
       Builtin packages live outside Resolved.Modules and are skipped; installed
       third-party store packages are skipped too (the user can't act on warnings
       in code they didn't write). Located warnings/info print to stderr; under
       --Werror any finding fails the build. Syntax errors are handled earlier by
       Resolve_Walk and are unaffected by this pass. */
    if ( Diag.Warnings ) {
        const char *LintSource = ( const char * )g_LintSource;
        int TotalFindings = 0;
        for ( size_t I = 0; I < Resolved.Count; I++ ) {
            if ( Paths_IsStorePath( Resolved.Modules[ I ].Path ) ) { continue; }
            TotalFindings += Diag_RunLint( Resolved.Modules[ I ].Path, LintSource, &Diag );
        }
        if ( TotalFindings > 0 ) {
            if ( Cli.WarningsAsErrors ) {
                fprintf( stderr,
                         "[-] %d warning(s) treated as errors (--Werror)\n",
                         TotalFindings );
                Resolve_FreeResult( &Resolved );
                return EXIT_FAILURE;
            }
            printf( "[!] %d warning(s) -- compiled anyway "
                    "(use --Werror to fail the build, -w to silence)\n",
                    TotalFindings );
        }
    }

    BlobMods = ( PBLOB_MODULE_T )calloc( Resolved.Count, sizeof( BLOB_MODULE_T ) );
    for ( I = 0; I < Resolved.Count; I++ ) {
        BlobMods[ I ].Name     = Resolved.Modules[ I ].Name;
        BlobMods[ I ].Bytes    = Resolved.Modules[ I ].Bytes;
        BlobMods[ I ].BytesLen = Resolved.Modules[ I ].BytesLen;
    }

    if ( !Blob_Build( BlobMods, Resolved.Count, 0, &Built ) ) {
        printf( "[-] blob build failed\n" );
        free( BlobMods );
        Resolve_FreeResult( &Resolved );
        return EXIT_FAILURE;
    }

    /* Stamp hardening flag bits into the built header. The runtime
       reads these to decide which decode / verification pass to run
       at startup. Each --flag is independent and composes. */
    PCLUA_BLOB_HEADER_T Hdr = ( PCLUA_BLOB_HEADER_T )Built.Bytes;
    if ( Cli.Strip ) {
        Hdr->Flags |= CLUA_BLOB_FLAG_STRIPPED;
        printf( "[_] --strip: debug info dropped from bytecode\n" );
    }

    /* --compress-blob: XPRESS_HUFF compress the payload region (everything
       after the CLUA_BLOB_HEADER). The compressed payload is prefixed
       inside the blob with magic "LVCB" + uint32 original size + the
       compressed bytes. The runtime detects the magic and runs
       RtlDecompressBufferEx (Cabinet.dll-equivalent ntdll path) before
       BlobReader_Open sees the bytes. Runs BEFORE --encrypt so the
       ciphertext is over already-compressed bytes (ciphertext doesn't
       compress -- order matters). */
    if ( Cli.CompressBlob ) {
        HMODULE Nt = GetModuleHandleA( "ntdll.dll" );
        if ( Nt == NULL ) Nt = LoadLibraryA( "ntdll.dll" );
        typedef LONG ( WINAPI *PRtlGetCompressionWorkSpaceSize )( USHORT, PULONG, PULONG );
        typedef LONG ( WINAPI *PRtlCompressBuffer )( USHORT, PUCHAR, ULONG, PUCHAR, ULONG, ULONG, PULONG, PVOID );
        PRtlGetCompressionWorkSpaceSize GetWss = ( PRtlGetCompressionWorkSpaceSize )( void * )
            GetProcAddress( Nt, "RtlGetCompressionWorkSpaceSize" );
        PRtlCompressBuffer              Comp   = ( PRtlCompressBuffer )( void * )
            GetProcAddress( Nt, "RtlCompressBuffer" );
        if ( GetWss && Comp ) {
            #define CLUA_PAYLOAD_COMPRESS_FORMAT 4   /* XPRESS_HUFF */
            ULONG WssMain = 0, WssFrag = 0;
            if ( GetWss( CLUA_PAYLOAD_COMPRESS_FORMAT, &WssMain, &WssFrag ) == 0 ) {
                void          *Ws       = malloc( WssMain );
                size_t         HdrSize  = sizeof( CLUA_BLOB_HEADER_T );
                size_t         OldPay   = Built.BytesLen - HdrSize;
                /* worst-case + magic + size prefix */
                size_t         OutCap   = OldPay + ( OldPay / 16 ) + 1024 + 8;
                unsigned char *OutBuf   = ( unsigned char * )malloc( OutCap );
                ULONG          Written  = 0;
                LONG St = Comp( CLUA_PAYLOAD_COMPRESS_FORMAT,
                                Built.Bytes + HdrSize, ( ULONG )OldPay,
                                OutBuf + 8, ( ULONG )( OutCap - 8 ),
                                4096, &Written, Ws );
                free( Ws );
                if ( St == 0 && ( size_t )Written + 8 < OldPay ) {
                    /* Patch in LVCB magic + original-payload-length. */
                    *( uint32_t * )( OutBuf + 0 ) = 0x42435643u;  /* 'LVCB' little-endian */
                    *( uint32_t * )( OutBuf + 4 ) = ( uint32_t )OldPay;
                    /* Rebuild Built: header || compressed-with-prefix. */
                    size_t         NewSize = HdrSize + Written + 8;
                    unsigned char *NewBuf  = ( unsigned char * )malloc( NewSize );
                    memcpy( NewBuf, Built.Bytes, HdrSize );
                    memcpy( NewBuf + HdrSize, OutBuf, ( size_t )Written + 8 );
                    free( Built.Bytes );
                    Built.Bytes   = NewBuf;
                    Built.BytesLen = NewSize;
                    /* Re-point Hdr; rewrite TotalSize. */
                    Hdr = ( PCLUA_BLOB_HEADER_T )Built.Bytes;
                    Hdr->TotalSize = ( uint32_t )NewSize;
                    Hdr->Flags    |= CLUA_BLOB_FLAG_COMPRESS_PAYLOAD;
                    printf( "[_] --compress-blob: payload %zu -> %u bytes (%.1f%%)\n",
                            OldPay, ( unsigned )Written,
                            ( double )Written * 100.0 / ( double )OldPay );
                } else {
                    printf( "[_] --compress-blob: skipped (compressed=%u not smaller than %zu)\n",
                            ( unsigned )Written, OldPay );
                }
                free( OutBuf );
            }
            #undef CLUA_PAYLOAD_COMPRESS_FORMAT
        } else {
            fprintf( stderr, "[-] --compress-blob: ntdll.RtlCompressBuffer not available\n" );
        }
    }

    /* --encrypt: stream-cipher everything after the header, including
       the module entry table, name pool, and bytecode payloads. The
       randomly-generated key is stored in the header itself; the
       runtime XOR's the same keystream over the payload region
       before BlobReader_Open sees it. */
    if ( Cli.Encrypt ) {
        FillRandom( Hdr->EncryptionKey, 32 );
        size_t HdrSize     = sizeof( CLUA_BLOB_HEADER_T );
        size_t PayloadSize = Built.BytesLen - HdrSize;
        StreamCipher_Apply( Hdr->EncryptionKey,
                            Built.Bytes + HdrSize,
                            PayloadSize );
        Hdr->Flags |= CLUA_BLOB_FLAG_ENCRYPTED;
        printf( "[_] --encrypt: %zu payload bytes ciphered\n", PayloadSize );
    }

    if ( Cli.LuaVersionStrip ) {
        Hdr->Flags |= CLUA_BLOB_FLAG_LUA_VERSION_STRIP;
        printf( "[_] --lua-version-strip: _VERSION + copyright strings will be nil'd at startup\n" );
    }

    /* --lua-sandbox: runtime removes a curated set of dangerous globals
       (os.execute / exit / remove / rename / tmpname, io.popen / open /
       tmpfile, loadfile / dofile / load with file mode, package.loadlib,
       debug.*) after luaL_openlibs() and before user code runs. */
    if ( Cli.LuaSandbox ) {
        Hdr->Flags |= CLUA_BLOB_FLAG_LUA_SANDBOX;
        printf( "[_] --lua-sandbox: dangerous globals nil'd at startup\n" );
    }

    /* --bytecode-only: stamp the flag; the actual link-side drop is
       wired via PE_LINK_OPTS_T below. */
    if ( Cli.BytecodeOnly ) {
        Hdr->Flags |= CLUA_BLOB_FLAG_BYTECODE_ONLY;
        printf( "[_] --bytecode-only: lparser+lcode excluded from link; source loads will abort at runtime\n" );
    }

    /* --jit-only: stub luaV_execute so the interpreter (lvm.o) gets
       dropped. Every Lua function path must JIT successfully; an
       unjittable proto aborts the program at first call. */
    if ( Cli.JitOnly ) {
        Hdr->Flags |= CLUA_BLOB_FLAG_JIT_ONLY;
        printf( "[_] --jit-only: lvm.c interpreter excluded; non-JIT-compilable funcs will abort at runtime\n" );
    }

    LinkOpts.RuntimeArchive       = Cli.RuntimeArchive;
    LinkOpts.LuaArchive           = Cli.LuaArchive;
    LinkOpts.Subsystem            = Cli.Subsystem;
    LinkOpts.OutputType           = Cli.OutputType;
    LinkOpts.Strip                = Cli.Strip;
    LinkOpts.Randomize            = Cli.Randomize;
    LinkOpts.RichHeaderStrip      = Cli.RichHeaderStrip;
    LinkOpts.GcSections           = Cli.GcSections;
    LinkOpts.HighEntropyVa        = Cli.HighEntropyVa;
    LinkOpts.VerifyPeFlags        = Cli.VerifyPeFlags;
    LinkOpts.StackProtector       = Cli.StackProtector;
    LinkOpts.FortifySource        = Cli.FortifySource;
    LinkOpts.StackClash           = Cli.StackClash;
    LinkOpts.CfProtection         = Cli.CfProtection;
    LinkOpts.OptimizeSize         = Cli.OptimizeSize;
    LinkOpts.Lto                  = Cli.Lto;
    LinkOpts.NoUnwind             = Cli.NoUnwind;
    LinkOpts.MergeConstants       = Cli.MergeConstants;
    LinkOpts.NoLuaIolib           = Cli.NoLuaIolib;
    LinkOpts.NoLuaOslib           = Cli.NoLuaOslib;
    LinkOpts.NoLuaDblib           = Cli.NoLuaDblib;
    LinkOpts.BytecodeOnly         = Cli.BytecodeOnly;
    LinkOpts.JitOnly              = Cli.JitOnly;
    /* --prune-packages: walk the comma-separated name list and drop
       any matching entries from Resolved.BuiltinPackages BEFORE the
       link step picks them up. Compact in place by swapping the
       removed entry with the tail. Frees the popped name string. */
    if ( Cli.PrunePackages != NULL ) {
        const char *S = Cli.PrunePackages;
        while ( *S ) {
            const char *Comma = strchr( S, ',' );
            size_t      Len   = Comma ? ( size_t )( Comma - S ) : strlen( S );
            char        Name[ 128 ] = { 0 };
            if ( Len < sizeof( Name ) ) {
                memcpy( Name, S, Len );
                Name[ Len ] = 0;
                for ( size_t K = 0; K < Resolved.BuiltinPackageCount; ) {
                    if ( strcmp( Resolved.BuiltinPackages[ K ], Name ) == 0 ) {
                        free( Resolved.BuiltinPackages[ K ] );
                        Resolved.BuiltinPackages[ K ] =
                            Resolved.BuiltinPackages[ Resolved.BuiltinPackageCount - 1 ];
                        Resolved.BuiltinPackageCount--;
                        printf( "[_] --prune-packages: dropped \"%s\" from link\n", Name );
                    } else {
                        K++;
                    }
                }
            }
            S = Comma ? Comma + 1 : S + Len;
        }
    }
    LinkOpts.BuiltinPackages      = Resolved.BuiltinPackages;
    LinkOpts.BuiltinPackageCount  = Resolved.BuiltinPackageCount;
    LinkOpts.NativeMode           = Cli.NativeMode;
    LinkOpts.NativeModeFor        = Cli.NativeModeFor;
    LinkOpts.NativeDir            = Cli.NativeDir;
    /* Default to the embedded (-Os -g0 + hardened) package .o files
       to match the embedded runtime/lualib defaults. Override via the
       CLUA_PKG_OBJ_DIR env var when needed. */
    {
        const char *Env = getenv( "CLUA_PKG_OBJ_DIR" );
        LinkOpts.PackagesObjDir = ( Env != NULL && Env[ 0 ] != '\0' )
                                  ? Env
                                  : "build/bin/obj-emb/runtime/packages";
    }
    if ( Cli.GcSections )     printf( "[_] --gc-sections: -ffunction/-fdata-sections + ld --gc-sections\n" );
    if ( Cli.HighEntropyVa )  printf( "[_] --high-entropy-va: full 64-bit ASLR enabled\n" );
    if ( Cli.VerifyPeFlags )  printf( "[_] --verify-pe-flags: post-link PE characteristics assertion\n" );
    if ( Cli.StackProtector ) printf( "[_] --stack-protector: -fstack-protector-strong on per-build .o\n" );
    if ( Cli.FortifySource )  printf( "[_] --fortify-source: -D_FORTIFY_SOURCE=2 on per-build .o\n" );
    if ( Cli.StackClash )     printf( "[_] --stack-clash: -fstack-clash-protection on per-build .o\n" );
    if ( Cli.CfProtection )   printf( "[_] --cf-protection: -fcf-protection=full (Intel CET) on per-build .o\n" );
    if ( Cli.OptimizeSize )    printf( "[_] --optimize-size: -Os on compile + link\n" );
    if ( Cli.Lto )             printf( "[_] --lto: -flto on compile + link\n" );
    if ( Cli.NoUnwind )        printf( "[_] --no-unwind: drop .pdata/.xdata unwind tables\n" );
    if ( Cli.MergeConstants )  printf( "[_] --merge-constants: -fmerge-all-constants -fmerge-constants\n" );
    if ( Cli.NoLuaIolib )      printf( "[_] --no-lua-iolib: io.* library omitted from link\n" );
    if ( Cli.NoLuaOslib )      printf( "[_] --no-lua-oslib: os.* library omitted from link\n" );
    if ( Cli.NoLuaDblib )      printf( "[_] --no-lua-dblib: debug.* library omitted from link\n" );
    /* Pull in imgui.a + D3D11/Win32 libs only when the resolved program
       actually requires "imgui" (or the user forced it via --imgui). */
    if ( Cli.ImguiUserSet ) {
        LinkOpts.ImguiArchive = Cli.ImguiArchive;
    } else if ( Resolved.RequiresImgui ) {
        LinkOpts.ImguiArchive = Cli.ImguiArchive;
        printf( "[_] auto-linking %s (require(\"imgui\") detected)\n",
                Cli.ImguiArchive );
    }
    if ( !PeLink_Bundle( Built.Bytes, Built.BytesLen, Cli.OutputPath, &LinkOpts ) ) {
        printf( "[-] PE bundle failed\n" );
        Blob_FreeResult( &Built );
        free( BlobMods );
        Resolve_FreeResult( &Resolved );
        return EXIT_FAILURE;
    }

    printf( "[+] %s (%zu modules) -> %s\n",
            Cli.SourcePath, Resolved.Count, Cli.OutputPath );
    for ( I = 0; I < Resolved.Count; I++ ) {
        printf( "    %-24s  %s  %zu bytes\n",
                Resolved.Modules[ I ].Name,
                Resolved.Modules[ I ].Path,
                Resolved.Modules[ I ].BytesLen );
    }

    Blob_FreeResult( &Built );
    free( BlobMods );
    Resolve_FreeResult( &Resolved );
    return EXIT_SUCCESS;
}
