#include "compiler/pe_link.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <windows.h>

static int WriteAllBytes( const char *Path, const unsigned char *Bytes, size_t Len ) {
    FILE  *Fp = { 0 };
    size_t W  = { 0 };
    Fp = fopen( Path, "wb" );
    if ( Fp == NULL ) { return 0; }
    W = fwrite( Bytes, 1, Len, Fp );
    fclose( Fp );
    return W == Len;
}

static int ReadAllBytes( const char *Path, unsigned char **Out, size_t *OutLen ) {
    FILE *Fp = fopen( Path, "rb" );
    if ( Fp == NULL ) { return 0; }
    fseek( Fp, 0, SEEK_END );
    long N = ftell( Fp );
    fseek( Fp, 0, SEEK_SET );
    if ( N < 0 ) { fclose( Fp ); return 0; }
    unsigned char *Buf = ( unsigned char * )malloc( ( size_t )N );
    if ( Buf == NULL ) { fclose( Fp ); return 0; }
    size_t R = fread( Buf, 1, ( size_t )N, Fp );
    fclose( Fp );
    if ( R != ( size_t )N ) { free( Buf ); return 0; }
    *Out    = Buf;
    *OutLen = ( size_t )N;
    return 1;
}

/* SplitMix64 PRNG -- used to drive --randomize. Seeded from time + tick + PID
   so each build gives a distinct ImageBase and section names. */
static uint64_t g_RandState = 0;

static void RandInit( void ) {
    g_RandState = ( uint64_t )time( NULL )
                ^ ( ( uint64_t )GetTickCount( ) << 8 )
                ^ ( ( uint64_t )GetCurrentProcessId( ) << 16 );
    if ( g_RandState == 0 ) g_RandState = 0xDEADBEEFCAFEBABEULL;
}

static uint64_t RandNext( void ) {
    uint64_t Z = ( g_RandState += 0x9E3779B97F4A7C15ULL );
    Z = ( Z ^ ( Z >> 30 ) ) * 0xBF58476D1CE4E5B9ULL;
    Z = ( Z ^ ( Z >> 27 ) ) * 0x94D049BB133111EBULL;
    return Z ^ ( Z >> 31 );
}

/*!
 * @brief
 *  Post-link binary patches for --randomize and --rich-header-strip.
 *  Both are no-ops on inputs that don't look like a valid MZ/PE.
 *
 *  --randomize: rewrites section-table name fields with random 7-char
 *  strings. Sections are identified by RVA at load time, not by name,
 *  so renaming is semantically safe. ImageBase randomization is handled
 *  at link time via -Wl,--image-base.
 *
 *  --rich-header-strip: zeros the MSVC Rich header (between DOS stub and
 *  PE header). Walks backwards from the "Rich" marker to find "DanS".
 *  mingw doesn't emit Rich headers; this is a no-op for mingw-built PEs.
 */
static int PostLinkPatchPE( const char *Path, int Randomize, int RichHeaderStrip ) {
    unsigned char *Buf = NULL;
    size_t         Len = 0;
    if ( !ReadAllBytes( Path, &Buf, &Len ) ) { return 0; }

    if ( Len < 64 || Buf[ 0 ] != 'M' || Buf[ 1 ] != 'Z' ) { free( Buf ); return 1; }
    uint32_t PeOff = *( uint32_t * )( Buf + 0x3C );
    if ( ( size_t )PeOff + 4 + 20 + 224 > Len ) { free( Buf ); return 1; }
    if ( Buf[ PeOff ] != 'P' || Buf[ PeOff + 1 ] != 'E' ) { free( Buf ); return 1; }

    if ( RichHeaderStrip && PeOff > 64 ) {
        for ( uint32_t I = 64; I + 8 <= PeOff; I++ ) {
            if ( Buf[ I ] == 'R' && Buf[ I + 1 ] == 'i' &&
                 Buf[ I + 2 ] == 'c' && Buf[ I + 3 ] == 'h' ) {
                uint32_t XorKey = *( uint32_t * )( Buf + I + 4 );
                uint32_t DanS   = ( 'D' ) | ( 'a' << 8 ) | ( 'n' << 16 ) | ( 'S' << 24 );
                uint32_t Want   = DanS ^ XorKey;
                uint32_t J      = I;
                while ( J >= 64 + 4 ) {
                    J -= 4;
                    if ( *( uint32_t * )( Buf + J ) == Want ) {
                        memset( Buf + J, 0, I + 8 - J );
                        break;
                    }
                }
                break;
            }
        }
    }

    if ( Randomize ) {
        uint16_t NumberOfSections = *( uint16_t * )( Buf + PeOff + 4 + 2 );
        uint16_t SizeOfOptHdr     = *( uint16_t * )( Buf + PeOff + 4 + 16 );
        size_t   SecTabOff        = ( size_t )PeOff + 4 + 20 + SizeOfOptHdr;
        if ( SecTabOff + ( size_t )NumberOfSections * 40 <= Len ) {
            const char *Alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
            size_t      ABLen    = strlen( Alphabet );
            for ( uint16_t I = 0; I < NumberOfSections; I++ ) {
                unsigned char *NamePtr = Buf + SecTabOff + ( size_t )I * 40;
                NamePtr[ 0 ] = '.';
                for ( int J = 1; J < 8; J++ ) {
                    NamePtr[ J ] = ( unsigned char )Alphabet[ RandNext( ) % ABLen ];
                }
            }
        }
    }

    int Ok = WriteAllBytes( Path, Buf, Len );
    free( Buf );
    return Ok;
}

static int RunCmd( const char *Cmd ) {
    int Rc = { 0 };
    Rc = system( Cmd );
    return Rc == 0;
}

static const char *DefaultOr( const char *V, const char *Default ) {
    return V != NULL ? V : Default;
}

/*!
 * @brief
 *  Resolve a tool name to a full path. If the LUAVM_MINGW_BIN env var is
 *  set (build.bat sets it), prefer "<dir>\<tool>". Otherwise return the
 *  bare tool name and trust PATH. The env-var pass avoids picking up
 *  Embarcadero's same-named tools when they shadow MinGW on PATH.
 *
 *  The returned pointer is into the caller-supplied Out buffer.
 */
static const char *ResolveTool( const char *ToolName, char *Out, size_t OutSize ) {
    const char *MingwBin = getenv( "LUAVM_MINGW_BIN" );
    if ( MingwBin == NULL || MingwBin[ 0 ] == '\0' ) {
        return ToolName;
    }
    snprintf( Out, OutSize, "%s\\%s", MingwBin, ToolName );
    return Out;
}

/*!
 * @brief
 *  Embed the blob as a C `const unsigned char[]` and compile it to a
 *  .o file. The resulting object lands the blob bytes in .rdata (the
 *  standard read-only data section) alongside the runtime's other
 *  string and constant literals -- there's no dedicated `.luablob`
 *  section header in the final PE for an analyst to grep for.
 *
 *  Symbols emitted (referenced by runtime_init.c):
 *    extern const unsigned char g_LuaBlob[];
 *    extern const unsigned int  g_LuaBlob_size;
 *
 *  Writes the temp .c source to BlobBinFullOut and the compiled
 *  object to BlobObjFullOut. Caller owns cleanup of both.
 *
 *  Replaces the previous objcopy(--rename-section .data=.luablob)
 *  trick. That path produced a dedicated section header which showed
 *  up in `objdump -h` as a clear fingerprint -- even with the section
 *  renamed by --randomize, the count + size of the standalone blob
 *  section was distinctive. Putting the bytes through the regular C
 *  compiler folds them into the runtime's .rdata.
 */
/* Compose the per-object compile flags from the Opts struct. Used by
   both MakeBlobCObject and MakePackagesRefsObject so the two temp
   objects always get the same hardening / size flags. Caller-owned
   buffer; pass empty string when Opts is NULL. */
static void ComposeObjectCompileFlags( const PE_LINK_OPTS_T *Opts,
                                       char *Out, size_t Cap ) {
    Out[ 0 ] = 0;
    if ( Opts == NULL ) return;
    size_t W = 0;
    #define APPEND_COMPILE(...) do {                                \
        int _n = snprintf( Out + W, Cap - W, __VA_ARGS__ );         \
        if ( _n > 0 && ( size_t )_n < Cap - W ) W += ( size_t )_n;  \
    } while ( 0 )

    if ( Opts->GcSections ) {
        APPEND_COMPILE( " -ffunction-sections -fdata-sections" );
    }
    /* -fstack-protector-strong: emits a stack canary on functions with
       large local arrays / address-taken locals. Pulls in libssp from
       the mingw runtime. */
    if ( Opts->StackProtector ) {
        APPEND_COMPILE( " -fstack-protector-strong" );
    }
    /* -D_FORTIFY_SOURCE=2: glibc-style bounds checks on libc string /
       memory routines. Requires an active -O setting (else gcc emits
       a warning and disables the feature). The per-build blob.o /
       pkgrefs.o won't pick up the call-site checks (they contain no
       libc calls) -- the meaningful effect lands when --optimize-size
       is paired or when batch 6's runtime-hardened.a is built. */
    if ( Opts->FortifySource ) {
        APPEND_COMPILE( " -D_FORTIFY_SOURCE=2" );
    }
    /* -fstack-clash-protection: probes large stack allocations so they
       can't skip past the guard page. mingw gcc 15 supports this. */
    if ( Opts->StackClash ) {
        APPEND_COMPILE( " -fstack-clash-protection" );
    }
    /* -fcf-protection=full: Intel CET. IBT (indirect-branch tracking)
       + SHSTK (shadow stack) instrumentation. Runs harmless on
       non-CET CPUs; the prologue endbr64 is a NOP there. */
    if ( Opts->CfProtection ) {
        APPEND_COMPILE( " -fcf-protection=full" );
    }
    /* -Os: optimize for size at the expense of speed. ~5% perf drop
       on dispatch-heavy code is the typical trade. */
    if ( Opts->OptimizeSize ) {
        APPEND_COMPILE( " -Os" );
    }
    /* -flto: emit LLVM/GIMPLE bytecode in the .o so the linker can
       do whole-program optimization. Pair with -flto at link time. */
    if ( Opts->Lto ) {
        APPEND_COMPILE( " -flto" );
    }
    /* Drop the SEH unwind tables. Saves ~28 KB in the bundled image,
       cost is lossy stack-unwinding through C++ exceptions / SEH. */
    if ( Opts->NoUnwind ) {
        APPEND_COMPILE( " -fno-asynchronous-unwind-tables -fno-unwind-tables" );
    }
    /* Merge identical string / numeric constants across the TU. */
    if ( Opts->MergeConstants ) {
        APPEND_COMPILE( " -fmerge-all-constants -fmerge-constants" );
    }

    #undef APPEND_COMPILE
}

/* Compose the link-line flag fragment from the Opts struct. Called by
   both the DLL and EXE branches so a new --foo flag only needs to be
   added in one place. Writes a string that begins with a space so it
   can be appended directly to the per-output-type prefix (e.g.
   "-shared" or "-Wl,--subsystem,console"). */
static void ComposeLinkLineFlags( const PE_LINK_OPTS_T *Opts,
                                  char *Out, size_t Cap ) {
    Out[ 0 ] = 0;
    if ( Opts == NULL ) return;
    size_t W = 0;
    #define APPEND_FLAG(...) do {                                   \
        int _n = snprintf( Out + W, Cap - W, __VA_ARGS__ );         \
        if ( _n > 0 && ( size_t )_n < Cap - W ) W += ( size_t )_n;  \
    } while ( 0 )

    if ( Opts->Strip ) {
        APPEND_FLAG( " -Wl,--strip-all" );
    }
    if ( Opts->GcSections ) {
        APPEND_FLAG( " -Wl,--gc-sections" );
    }
    if ( Opts->HighEntropyVa ) {
        APPEND_FLAG( " -Wl,--high-entropy-va" );
    }
    /* -Os at link time lets the LTO pass (when --lto is also set)
       optimize the linked image for size rather than speed. */
    if ( Opts->OptimizeSize ) {
        APPEND_FLAG( " -Os" );
    }
    /* -flto at link time activates the cross-TU optimization pass. */
    if ( Opts->Lto ) {
        APPEND_FLAG( " -flto" );
    }
    /* --jit-only: lvm.o still gets pulled in for non-luaV_execute
       helper symbols (luaV_concat / luaV_equalobj / luaV_lessthan /
       luaV_finishget / ...). Allow our stub's luaV_execute to win
       the duplicate-definition clash since our stub appears earlier
       in the link line than the archive. The duplicate-definition
       picks the first one seen. */
    if ( Opts->JitOnly ) {
        APPEND_FLAG( " -Wl,--allow-multiple-definition" );
    }
    if ( Opts->Randomize ) {
        if ( g_RandState == 0 ) RandInit( );
        uint64_t Base = 0x140000000ULL + ( ( RandNext( ) & 0xFFFFULL ) << 16 );
        APPEND_FLAG( " -Wl,--image-base=0x%llx", ( unsigned long long )Base );
    }
    #undef APPEND_FLAG
}

/* --verify-pe-flags: post-link sanity check. Reads the DllCharacteristics
   field of the linked PE's optional header and asserts the bits we
   expect to see. Reports each mismatch; returns 1 if all expected bits
   are set, 0 otherwise (but never aborts the build -- the binary is
   already on disk, the caller decides what to do).
   IMAGE_DLLCHARACTERISTICS_*:
       0x0020  HIGH_ENTROPY_VA
       0x0040  DYNAMIC_BASE  (ASLR)
       0x0100  NX_COMPAT     (DEP)
       0x4000  GUARD_CF      (CFG -- mingw stubs, won't be set) */
static int VerifyPeCharacteristics( const char *Path, int RequireHighEntropy ) {
    unsigned char *Buf = NULL;
    size_t         Len = 0;
    if ( !ReadAllBytes( Path, &Buf, &Len ) ) {
        fprintf( stderr, "[-] PeLink: --verify-pe-flags cannot read %s\n", Path );
        return 0;
    }
    if ( Len < 0x100 || Buf[ 0 ] != 'M' || Buf[ 1 ] != 'Z' ) {
        fprintf( stderr, "[-] PeLink: --verify-pe-flags: not a PE\n" );
        free( Buf );
        return 0;
    }
    uint32_t PeOff = *( uint32_t * )( Buf + 0x3C );
    if ( ( size_t )PeOff + 24 + 96 > Len ) { free( Buf ); return 0; }
    /* Optional header starts at PeOff + 4 (sig) + 20 (file hdr).
       DllCharacteristics is at offset 0x46 inside the PE32+ optional
       header (Magic at 0, ..., DllCharacteristics at 0x46). */
    size_t   OptOff = ( size_t )PeOff + 24;
    uint16_t Magic  = *( uint16_t * )( Buf + OptOff );
    size_t   DcOff  = OptOff + ( ( Magic == 0x20b ) ? 0x46 : 0x46 );
    if ( DcOff + 2 > Len ) { free( Buf ); return 0; }
    uint16_t Dc = *( uint16_t * )( Buf + DcOff );
    free( Buf );

    int Ok = 1;
    if ( !( Dc & 0x0040 ) ) {
        fprintf( stderr, "[-] PeLink: --verify-pe-flags: DYNAMIC_BASE (ASLR) bit missing (DllCharacteristics=0x%04X)\n", Dc );
        Ok = 0;
    }
    if ( !( Dc & 0x0100 ) ) {
        fprintf( stderr, "[-] PeLink: --verify-pe-flags: NX_COMPAT (DEP) bit missing\n" );
        Ok = 0;
    }
    if ( RequireHighEntropy && !( Dc & 0x0020 ) ) {
        fprintf( stderr, "[-] PeLink: --verify-pe-flags: HIGH_ENTROPY_VA requested but bit missing\n" );
        Ok = 0;
    }
    if ( Ok ) {
        printf( "[+] --verify-pe-flags: DllCharacteristics=0x%04X (DYNAMIC_BASE+NX_COMPAT%s OK)\n",
                Dc, ( Dc & 0x0020 ) ? "+HIGH_ENTROPY_VA" : "" );
    }
    return Ok;
}

static int MakeBlobCObject( const unsigned char *Blob,
                            size_t               BlobLen,
                            const char          *Cc,
                            const PE_LINK_OPTS_T *Opts,
                            char                *BlobBinFullOut,
                            size_t               BlobBinFullCap,
                            char                *BlobObjFullOut,
                            size_t               BlobObjFullCap ) {
    char TempDir[ MAX_PATH ] = { 0 };
    char Cmd[ 4096 ]         = { 0 };
    char ObjFlags[ 512 ]     = { 0 };

    if ( GetTempPathA( MAX_PATH, TempDir ) == 0 ) { return 0; }
    snprintf( BlobBinFullOut, BlobBinFullCap, "%sluablob%lu.c",
              TempDir, ( unsigned long )GetCurrentProcessId( ) );
    snprintf( BlobObjFullOut, BlobObjFullCap, "%sluablob%lu.o",
              TempDir, ( unsigned long )GetCurrentProcessId( ) );
    ComposeObjectCompileFlags( Opts, ObjFlags, sizeof( ObjFlags ) );

    FILE *Fp = fopen( BlobBinFullOut, "wb" );
    if ( Fp == NULL ) {
        fprintf( stderr, "[-] PeLink: cannot write %s\n", BlobBinFullOut );
        return 0;
    }
    /* No #include needed -- plain unsigned char + unsigned int are
       built-in. The 8-byte alignment guarantees the LUAVM_BLOB_HEADER's
       uint32 fields are correctly aligned for in-place reads. */
    fprintf( Fp, "__attribute__((aligned(8)))\n" );
    fprintf( Fp, "const unsigned char g_LuaBlob[%zu] = {\n", BlobLen );
    for ( size_t I = 0; I < BlobLen; I++ ) {
        if ( ( I % 16 ) == 0 ) fprintf( Fp, "    " );
        fprintf( Fp, "0x%02X,", ( unsigned )Blob[ I ] );
        if ( ( I % 16 ) == 15 || I + 1 == BlobLen ) {
            fprintf( Fp, "\n" );
        } else {
            fprintf( Fp, " " );
        }
    }
    fprintf( Fp, "};\n" );
    fprintf( Fp, "const unsigned int g_LuaBlob_size = %zu;\n", BlobLen );
    fclose( Fp );

    int N = snprintf( Cmd, sizeof( Cmd ),
        "%s%s -c \"%s\" -o \"%s\"",
        Cc, ObjFlags, BlobBinFullOut, BlobObjFullOut );
    if ( N <= 0 || ( size_t )N >= sizeof( Cmd ) ) {
        fprintf( stderr, "[-] PeLink: blob compile command too long\n" );
        DeleteFileA( BlobBinFullOut );
        return 0;
    }
    if ( !RunCmd( Cmd ) ) {
        fprintf( stderr, "[-] PeLink: blob C compile failed :: %s\n", Cmd );
        DeleteFileA( BlobBinFullOut );
        return 0;
    }
    return 1;
}

/*!
 * @brief
 *  Generate a per-build parser stub that defines luaY_parser (the
 *  entry point ldo.c::lua_load calls when the chunk isn't bytecode).
 *  Linked before liblua54.a so it wins symbol resolution, which
 *  prevents the linker from pulling lparser.o + lcode.o (and a chunk
 *  of llex.o that's only reachable through them) into the final PE.
 *  Loading source at runtime aborts with a clear error.
 *
 *  Returns 0 on failure; 1 on success (or 1+empty-paths when not
 *  requested).
 */
static int MakeBytecodeOnlyStub( const PE_LINK_OPTS_T *Opts,
                                 const char *Cc,
                                 char *StubCFull,   size_t StubCCap,
                                 char *StubObjFull, size_t StubObjCap ) {
    StubCFull[ 0 ]   = 0;
    StubObjFull[ 0 ] = 0;
    if ( Opts == NULL || !Opts->BytecodeOnly ) return 1;
    char TempDir[ MAX_PATH ] = { 0 };
    char Cmd[ 4096 ]         = { 0 };
    if ( GetTempPathA( MAX_PATH, TempDir ) == 0 ) return 0;
    snprintf( StubCFull,   StubCCap,
              "%sbconly%lu.c", TempDir,
              ( unsigned long )GetCurrentProcessId( ) );
    snprintf( StubObjFull, StubObjCap,
              "%sbconly%lu.o", TempDir,
              ( unsigned long )GetCurrentProcessId( ) );

    FILE *Fp = fopen( StubCFull, "wb" );
    if ( Fp == NULL ) {
        fprintf( stderr, "[-] PeLink: cannot write %s\n", StubCFull );
        return 0;
    }
    fprintf( Fp,
        "/* compiler-injected stub when --bytecode-only is set.\n"
        "   Defines luaY_parser so the linker doesn't pull lparser.o /\n"
        "   lcode.o from liblua54.a. Calling load()/loadstring() on\n"
        "   source aborts via luaG_runerror -- bytecode loads still\n"
        "   work because lua_load detects the LUA_SIGNATURE prefix\n"
        "   and routes through lundump.o instead. */\n"
        "typedef struct lua_State LuaState_T;\n"
        "typedef struct Zio       Zio_T;\n"
        "typedef struct Mbuffer   Mbuffer_T;\n"
        "typedef struct Dyndata   Dyndata_T;\n"
        "typedef struct LClosure  LClosure_T;\n"
        "extern void luaG_runerror(LuaState_T *L, const char *fmt, ...);\n"
        "LClosure_T *luaY_parser(LuaState_T *L, Zio_T *z, Mbuffer_T *buff,\n"
        "                         Dyndata_T *dyd, const char *name,\n"
        "                         int firstchar) {\n"
        "    (void)z; (void)buff; (void)dyd; (void)name; (void)firstchar;\n"
        "    luaG_runerror(L,\n"
        "        \"source loading disabled (compiled with --bytecode-only)\");\n"
        "    return (LClosure_T *)0;\n"
        "}\n" );
    fclose( Fp );

    char ObjFlags[ 512 ] = { 0 };
    ComposeObjectCompileFlags( Opts, ObjFlags, sizeof( ObjFlags ) );
    int N = snprintf( Cmd, sizeof( Cmd ), "%s%s -c \"%s\" -o \"%s\"",
                      Cc, ObjFlags, StubCFull, StubObjFull );
    if ( N <= 0 || ( size_t )N >= sizeof( Cmd ) ) {
        DeleteFileA( StubCFull );
        return 0;
    }
    if ( !RunCmd( Cmd ) ) {
        fprintf( stderr, "[-] PeLink: --bytecode-only stub compile failed :: %s\n", Cmd );
        DeleteFileA( StubCFull );
        return 0;
    }
    return 1;
}

/*!
 * @brief
 *  Generate a per-build luaV_execute stub when --jit-only is set.
 *  The interpreter dispatch loop is by far the biggest function in
 *  lvm.o (~30-50 KB compiled). With -ffunction-sections (default in
 *  the embedded runtime) + --gc-sections the linker drops it.
 *  Calling the stub from Rt_TailCall's fallback path aborts via
 *  luaG_runerror -- the JIT must succeed on every Lua proto for the
 *  binary to run correctly.
 */
static int MakeJitOnlyStub( const PE_LINK_OPTS_T *Opts,
                            const char *Cc,
                            char *StubCFull,   size_t StubCCap,
                            char *StubObjFull, size_t StubObjCap ) {
    StubCFull[ 0 ]   = 0;
    StubObjFull[ 0 ] = 0;
    if ( Opts == NULL || !Opts->JitOnly ) return 1;
    char TempDir[ MAX_PATH ] = { 0 };
    char Cmd[ 4096 ]         = { 0 };
    if ( GetTempPathA( MAX_PATH, TempDir ) == 0 ) return 0;
    snprintf( StubCFull,   StubCCap,
              "%sjitonly%lu.c", TempDir,
              ( unsigned long )GetCurrentProcessId( ) );
    snprintf( StubObjFull, StubObjCap,
              "%sjitonly%lu.o", TempDir,
              ( unsigned long )GetCurrentProcessId( ) );

    FILE *Fp = fopen( StubCFull, "wb" );
    if ( Fp == NULL ) {
        fprintf( stderr, "[-] PeLink: cannot write %s\n", StubCFull );
        return 0;
    }
    fprintf( Fp,
        "/* compiler-injected stub when --jit-only is set.\n"
        "   Defines luaV_execute so the linker drops the interpreter\n"
        "   dispatch loop from lvm.o via --gc-sections + per-function\n"
        "   sections. Any code path that falls through here aborts:\n"
        "   the JIT must succeed on every reachable Lua proto. */\n"
        "typedef struct lua_State LuaState_T;\n"
        "typedef struct CallInfo  CallInfo_T;\n"
        "extern void luaG_runerror(LuaState_T *L, const char *fmt, ...);\n"
        "void luaV_execute(LuaState_T *L, CallInfo_T *ci) {\n"
        "    (void)ci;\n"
        "    luaG_runerror(L,\n"
        "        \"interpreter dispatch disabled (compiled with --jit-only); JIT-uncompilable Lua function reached\");\n"
        "}\n" );
    fclose( Fp );

    char ObjFlags[ 512 ] = { 0 };
    ComposeObjectCompileFlags( Opts, ObjFlags, sizeof( ObjFlags ) );
    int N = snprintf( Cmd, sizeof( Cmd ), "%s%s -c \"%s\" -o \"%s\"",
                      Cc, ObjFlags, StubCFull, StubObjFull );
    if ( N <= 0 || ( size_t )N >= sizeof( Cmd ) ) {
        DeleteFileA( StubCFull );
        return 0;
    }
    if ( !RunCmd( Cmd ) ) {
        fprintf( stderr, "[-] PeLink: --jit-only stub compile failed :: %s\n", Cmd );
        DeleteFileA( StubCFull );
        return 0;
    }
    return 1;
}

/* --- Native-DLL embedding ----------------------------------------------
 *
 * Each builtin package can declare `requires_native = {...}` in its
 * package.lua. The auto-scan generator emits build/gen/_builtin_native_deps.h
 * with the full registry. At link time we:
 *
 *   1. Walk the required packages (already resolved via the static
 *      walker) and collect their native deps from the registry.
 *   2. Apply mode resolution: --native-mode-for <pkg>=<mode> overrides
 *      --native-mode which overrides the manifest's mode_default.
 *   3. For each dep:
 *      - embed:    read the DLL bytes from --native-dir/<dll> (default
 *                  vendor/native/<dll>), emit a C array, register in
 *                  the dispatch table the runtime walks at startup
 *      - sidecar:  copy the DLL to the output directory
 *      - system:   no-op (assume on PATH/system32)
 *   4. Compile + link the generated native_refs.c -- it defines
 *      Native_GetEmbeddedDlls which overrides the weak default in
 *      runtime/native_loader.c.
 *
 * When a package's DLL isn't in the native-dir, we skip embedding
 * (with a warning) -- the user can still drop the DLL alongside the
 * exe by hand. The build doesn't fail on a missing DLL because the
 * package may still ffi.load via env-var override at runtime.
 */

#include "../../build/gen/_builtin_native_deps.h"
#include "common/sha256_lite.h"

/* Resolve mode for a given package name. Order: --native-mode-for
   override > --native-mode global > manifest mode_default. Returns
   a pointer into one of those strings (caller doesn't free). */
static const char *ResolveNativeMode( const char *PkgName,
                                      const char *ManifestDefault,
                                      const PE_LINK_OPTS_T *Opts ) {
    if ( Opts && Opts->NativeModeFor && PkgName ) {
        /* "sqlite=sidecar,pcre=system" -- find pkg=. */
        const char *S = Opts->NativeModeFor;
        size_t      PkgLen = strlen( PkgName );
        while ( *S ) {
            const char *Comma = strchr( S, ',' );
            size_t      EntLen = Comma ? ( size_t )( Comma - S ) : strlen( S );
            if ( EntLen > PkgLen + 1 &&
                 strncmp( S, PkgName, PkgLen ) == 0 &&
                 S[ PkgLen ] == '=' ) {
                /* Return a static buffer with the mode. */
                static char ModeBuf[ 32 ] = { 0 };
                size_t      ModeLen = EntLen - PkgLen - 1;
                if ( ModeLen >= sizeof( ModeBuf ) ) ModeLen = sizeof( ModeBuf ) - 1;
                memcpy( ModeBuf, S + PkgLen + 1, ModeLen );
                ModeBuf[ ModeLen ] = 0;
                return ModeBuf;
            }
            S = Comma ? Comma + 1 : S + EntLen;
        }
    }
    if ( Opts && Opts->NativeMode ) return Opts->NativeMode;
    if ( ManifestDefault )           return ManifestDefault;
    return "embed";
}

/* Read whole file into a malloc'd buffer. */
static int ReadFileBytes( const char *Path, unsigned char **Out, size_t *OutLen ) {
    FILE *Fp = fopen( Path, "rb" );
    if ( Fp == NULL ) return 0;
    fseek( Fp, 0, SEEK_END );
    long N = ftell( Fp );
    fseek( Fp, 0, SEEK_SET );
    if ( N < 0 ) { fclose( Fp ); return 0; }
    unsigned char *Buf = ( unsigned char * )malloc( ( size_t )N );
    if ( Buf == NULL ) { fclose( Fp ); return 0; }
    size_t R = fread( Buf, 1, ( size_t )N, Fp );
    fclose( Fp );
    if ( R != ( size_t )N ) { free( Buf ); return 0; }
    *Out    = Buf;
    *OutLen = ( size_t )N;
    return 1;
}

/* Make a C-identifier-safe symbol from a DLL filename:
   "sqlite3.dll" -> "sqlite3_dll", "Zydis.dll" -> "Zydis_dll". */
static void DllNameToSymbol( const char *Dll, char *Out, size_t Cap ) {
    size_t I = 0;
    while ( *Dll && I + 1 < Cap ) {
        char C = *Dll;
        if ( ( C >= 'A' && C <= 'Z' ) || ( C >= 'a' && C <= 'z' ) ||
             ( C >= '0' && C <= '9' ) || C == '_' ) {
            Out[ I++ ] = C;
        } else {
            Out[ I++ ] = '_';
        }
        Dll++;
    }
    Out[ I ] = 0;
}

/*!
 * @brief
 *  Generate + compile a per-build native_refs.c that overrides the
 *  runtime's weak Native_GetEmbeddedDlls with the actual embedded
 *  DLLs for this build. Also copies sidecar DLLs to the output
 *  directory. Returns 0 on failure; 1 on success (or 1+empty paths
 *  when no native deps need embedding).
 */
static int MakeNativeRefsObject( const PE_LINK_OPTS_T *Opts,
                                 const char *Cc,
                                 const char *OutputPath,
                                 char *RefsCFull,   size_t RefsCCap,
                                 char *RefsObjFull, size_t RefsObjCap ) {
    RefsCFull[ 0 ]   = 0;
    RefsObjFull[ 0 ] = 0;
    if ( Opts == NULL || Opts->BuiltinPackages == NULL ) return 1;

    const char *NativeDir = ( Opts->NativeDir != NULL && Opts->NativeDir[ 0 ] != '\0' )
                            ? Opts->NativeDir
                            : "vendor/native";

    /* First pass: walk all required packages, collect embedded DLLs
       (deduplicated by filename). Sidecar DLLs we copy immediately. */
    typedef struct {
        const char    *Dll;
        unsigned char *Bytes;
        size_t         Len;
        char           Symbol[ 128 ];
    } EmbeddedEntry;
    EmbeddedEntry Embedded[ 64 ] = { 0 };
    size_t        EmbeddedCount  = 0;

    for ( size_t P = 0; P < Opts->BuiltinPackageCount; P++ ) {
        const char *Pkg = Opts->BuiltinPackages[ P ];
        for ( int I = 0; k_BuiltinNativeDeps[ I ].PkgName != NULL; I++ ) {
            if ( strcmp( k_BuiltinNativeDeps[ I ].PkgName, Pkg ) != 0 ) continue;
            const char *Dll  = k_BuiltinNativeDeps[ I ].Dll;
            const char *Mode = ResolveNativeMode(
                Pkg, k_BuiltinNativeDeps[ I ].ModeDefault, Opts );
            if ( strcmp( Mode, "system" ) == 0 ) {
                printf( "[_] native: %s -> %s (system, expected on PATH)\n", Pkg, Dll );
                continue;
            }
            /* Resolve DLL path on disk. */
            char DllPath[ MAX_PATH ] = { 0 };
            snprintf( DllPath, sizeof( DllPath ), "%s/%s", NativeDir, Dll );
            /* Honor env var override if set. */
            if ( k_BuiltinNativeDeps[ I ].EnvVar &&
                 k_BuiltinNativeDeps[ I ].EnvVar[ 0 ] != '\0' ) {
                const char *Over = getenv( k_BuiltinNativeDeps[ I ].EnvVar );
                if ( Over != NULL && Over[ 0 ] != '\0' ) {
                    snprintf( DllPath, sizeof( DllPath ), "%s", Over );
                }
            }
            unsigned char *Bytes  = NULL;
            size_t         BytLen = 0;
            int            HasFile = ReadFileBytes( DllPath, &Bytes, &BytLen );

            if ( strcmp( Mode, "sidecar" ) == 0 ) {
                if ( !HasFile ) {
                    fprintf( stderr, "[!] native: %s sidecar requested but %s not found -- skipping\n",
                             Pkg, DllPath );
                    continue;
                }
                /* Copy to the output's directory. */
                char OutDir[ MAX_PATH ] = { 0 };
                snprintf( OutDir, sizeof( OutDir ), "%s", OutputPath );
                for ( int K = ( int )strlen( OutDir ) - 1; K >= 0; K-- ) {
                    if ( OutDir[ K ] == '/' || OutDir[ K ] == '\\' ) {
                        OutDir[ K ] = 0; break;
                    }
                    if ( K == 0 ) OutDir[ 0 ] = 0;
                }
                char Dst[ MAX_PATH ] = { 0 };
                if ( OutDir[ 0 ] ) snprintf( Dst, sizeof( Dst ), "%s\\%s", OutDir, Dll );
                else               snprintf( Dst, sizeof( Dst ), "%s", Dll );
                if ( !CopyFileA( DllPath, Dst, FALSE ) ) {
                    fprintf( stderr, "[!] native: %s sidecar copy %s -> %s failed\n",
                             Pkg, DllPath, Dst );
                } else {
                    printf( "[_] native: %s -> %s (sidecar, copied to %s)\n", Pkg, Dll, Dst );
                }
                free( Bytes );
                continue;
            }

            /* embed mode */
            if ( !HasFile ) {
                fprintf( stderr, "[!] native: %s embed requested but %s not found -- skipping (binary will fall back to PATH/env-override at runtime)\n",
                         Pkg, DllPath );
                continue;
            }
            /* Dedup by DLL name. */
            int Already = 0;
            for ( size_t K = 0; K < EmbeddedCount; K++ ) {
                if ( strcmp( Embedded[ K ].Dll, Dll ) == 0 ) {
                    Already = 1; free( Bytes ); break;
                }
            }
            if ( Already ) continue;
            if ( EmbeddedCount >= sizeof( Embedded ) / sizeof( Embedded[ 0 ] ) ) {
                fprintf( stderr, "[!] native: too many embedded DLLs (%zu); dropping %s\n",
                         EmbeddedCount, Dll );
                free( Bytes );
                continue;
            }
            Embedded[ EmbeddedCount ].Dll   = Dll;
            Embedded[ EmbeddedCount ].Bytes = Bytes;
            Embedded[ EmbeddedCount ].Len   = BytLen;
            DllNameToSymbol( Dll, Embedded[ EmbeddedCount ].Symbol,
                             sizeof( Embedded[ 0 ].Symbol ) );
            printf( "[_] native: %s -> %s (embed, %zu bytes)\n", Pkg, Dll, BytLen );
            EmbeddedCount++;
        }
    }

    if ( EmbeddedCount == 0 ) return 1;   /* nothing to embed */

    char TempDir[ MAX_PATH ] = { 0 };
    char Cmd[ 8192 ]         = { 0 };
    if ( GetTempPathA( MAX_PATH, TempDir ) == 0 ) goto fail;
    snprintf( RefsCFull,   RefsCCap,
              "%snatrefs%lu.c", TempDir,
              ( unsigned long )GetCurrentProcessId( ) );
    snprintf( RefsObjFull, RefsObjCap,
              "%snatrefs%lu.o", TempDir,
              ( unsigned long )GetCurrentProcessId( ) );

    FILE *Fp = fopen( RefsCFull, "wb" );
    if ( Fp == NULL ) goto fail;
    fprintf( Fp,
        "/* per-build native DLL embedding -- generated by compiler.exe.\n"
        "   Each entry carries a SHA-256 digest of the DLL bytes; the\n"
        "   runtime's Native_Bootstrap verifies the on-disk extracted\n"
        "   copy against this digest before LoadLibrary, closing the\n"
        "   DLL-hijacking window. */\n"
        "#include <stddef.h>\n\n"
        "typedef struct {\n"
        "    const char          *Name;\n"
        "    const unsigned char *Bytes;\n"
        "    const unsigned int  *LenPtr;\n"
        "    const unsigned char *Digest;\n"
        "} EMBEDDED_NATIVE_DLL_T;\n\n" );
    for ( size_t I = 0; I < EmbeddedCount; I++ ) {
        /* Compute SHA-256 of the DLL bytes for build-time embedding. */
        uint8_t Digest[ 32 ] = { 0 };
        Sha256Lite_Hash( Embedded[ I ].Bytes, Embedded[ I ].Len, Digest );

        fprintf( Fp, "__attribute__((aligned(8)))\n" );
        fprintf( Fp, "static const unsigned char g_NativeDll_%s[%zu] = {\n",
                 Embedded[ I ].Symbol, Embedded[ I ].Len );
        for ( size_t J = 0; J < Embedded[ I ].Len; J++ ) {
            if ( ( J % 16 ) == 0 ) fprintf( Fp, "    " );
            fprintf( Fp, "0x%02X,", ( unsigned )Embedded[ I ].Bytes[ J ] );
            if ( ( J % 16 ) == 15 || J + 1 == Embedded[ I ].Len ) fprintf( Fp, "\n" );
            else                                                  fprintf( Fp, " " );
        }
        fprintf( Fp, "};\n" );
        fprintf( Fp, "static const unsigned int g_NativeDll_%s_len = %zu;\n",
                 Embedded[ I ].Symbol, Embedded[ I ].Len );
        fprintf( Fp, "static const unsigned char g_NativeDll_%s_digest[32] = {\n    ",
                 Embedded[ I ].Symbol );
        for ( int J = 0; J < 32; J++ ) {
            fprintf( Fp, "0x%02X,", ( unsigned )Digest[ J ] );
            if ( J == 15 ) fprintf( Fp, "\n    " );
            else if ( J < 31 ) fprintf( Fp, " " );
        }
        fprintf( Fp, "\n};\n\n" );
    }
    fprintf( Fp, "static const EMBEDDED_NATIVE_DLL_T g_EmbeddedDlls[] = {\n" );
    for ( size_t I = 0; I < EmbeddedCount; I++ ) {
        fprintf( Fp, "    { \"%s\", g_NativeDll_%s, &g_NativeDll_%s_len, g_NativeDll_%s_digest },\n",
                 Embedded[ I ].Dll, Embedded[ I ].Symbol,
                 Embedded[ I ].Symbol, Embedded[ I ].Symbol );
    }
    fprintf( Fp, "};\n\n" );
    fprintf( Fp,
        "const EMBEDDED_NATIVE_DLL_T *Native_GetEmbeddedDlls(size_t *OutCount) {\n"
        "    if (OutCount) *OutCount = sizeof(g_EmbeddedDlls)/sizeof(g_EmbeddedDlls[0]);\n"
        "    return g_EmbeddedDlls;\n"
        "}\n" );
    fclose( Fp );

    /* Free the in-memory bytes (already written out). */
    for ( size_t I = 0; I < EmbeddedCount; I++ ) free( Embedded[ I ].Bytes );

    int N = snprintf( Cmd, sizeof( Cmd ), "%s -c \"%s\" -o \"%s\"",
                      Cc, RefsCFull, RefsObjFull );
    if ( N <= 0 || ( size_t )N >= sizeof( Cmd ) ) {
        DeleteFileA( RefsCFull );
        return 0;
    }
    if ( !RunCmd( Cmd ) ) {
        fprintf( stderr, "[-] PeLink: native_refs compile failed :: %s\n", Cmd );
        DeleteFileA( RefsCFull );
        return 0;
    }
    return 1;

fail:
    for ( size_t I = 0; I < EmbeddedCount; I++ ) free( Embedded[ I ].Bytes );
    return 0;
}

/*!
 * @brief
 *  Generate + compile a per-build linit_override.c that re-defines
 *  luaL_openlibs to omit the lua sub-libraries the user opted out of
 *  (--no-lua-iolib / --no-lua-oslib / --no-lua-dblib). Linking this
 *  .o before liblua54.a wins the symbol race; ld then drops the
 *  unreferenced sub-lib .o members from the archive via standard
 *  resolution. Returns 0 on failure, 1 on success (or 1+empty-paths
 *  when no opt-out was requested -- caller skips the link step).
 *
 *  Caller owns cleanup of OverrideCFull + OverrideObjFull paths.
 */
static int MakeLuaInitOverride( const PE_LINK_OPTS_T *Opts,
                                const char *Cc,
                                char *OverrideCFull,   size_t OverrideCCap,
                                char *OverrideObjFull, size_t OverrideObjCap ) {
    OverrideCFull[ 0 ] = 0;
    OverrideObjFull[ 0 ] = 0;
    if ( Opts == NULL ||
         ( !Opts->NoLuaIolib && !Opts->NoLuaOslib && !Opts->NoLuaDblib ) ) {
        return 1;  /* nothing requested -- no override needed */
    }
    char TempDir[ MAX_PATH ] = { 0 };
    char Cmd[ 4096 ]         = { 0 };
    if ( GetTempPathA( MAX_PATH, TempDir ) == 0 ) return 0;
    snprintf( OverrideCFull,   OverrideCCap,
              "%slinitov%lu.c", TempDir,
              ( unsigned long )GetCurrentProcessId( ) );
    snprintf( OverrideObjFull, OverrideObjCap,
              "%slinitov%lu.o", TempDir,
              ( unsigned long )GetCurrentProcessId( ) );

    FILE *Fp = fopen( OverrideCFull, "wb" );
    if ( Fp == NULL ) {
        fprintf( stderr, "[-] PeLink: cannot write %s\n", OverrideCFull );
        return 0;
    }
    fprintf( Fp, "/* per-build luaL_openlibs override -- generated by compiler.exe.\n"
                 "   Omits Lua sub-libraries the user dropped via --no-lua-*; the\n"
                 "   linker tree-shakes their .o members out of liblua54.a. */\n" );
    fprintf( Fp, "#define lua_c\n#define LUA_LIB\n\n" );
    fprintf( Fp, "typedef struct lua_State lua_State;\n" );
    fprintf( Fp, "typedef int (*lua_CFunction)(lua_State *);\n" );
    fprintf( Fp, "extern int  luaopen_base(lua_State *);\n" );
    fprintf( Fp, "extern int  luaopen_package(lua_State *);\n" );
    fprintf( Fp, "extern int  luaopen_coroutine(lua_State *);\n" );
    fprintf( Fp, "extern int  luaopen_table(lua_State *);\n" );
    fprintf( Fp, "extern int  luaopen_string(lua_State *);\n" );
    fprintf( Fp, "extern int  luaopen_math(lua_State *);\n" );
    fprintf( Fp, "extern int  luaopen_utf8(lua_State *);\n" );
    if ( !Opts->NoLuaIolib ) fprintf( Fp, "extern int  luaopen_io(lua_State *);\n" );
    if ( !Opts->NoLuaOslib ) fprintf( Fp, "extern int  luaopen_os(lua_State *);\n" );
    if ( !Opts->NoLuaDblib ) fprintf( Fp, "extern int  luaopen_debug(lua_State *);\n" );
    fprintf( Fp, "extern void luaL_requiref(lua_State *, const char *, lua_CFunction, int);\n" );
    fprintf( Fp, "extern void lua_settop(lua_State *, int);\n" );
    fprintf( Fp, "#define lua_pop(L,n) lua_settop(L, -(n)-1)\n\n" );
    fprintf( Fp, "__declspec(dllexport) void luaL_openlibs(lua_State *L) {\n" );
    fprintf( Fp, "    luaL_requiref(L, \"_G\",        luaopen_base,      1); lua_pop(L, 1);\n" );
    fprintf( Fp, "    luaL_requiref(L, \"package\",   luaopen_package,   1); lua_pop(L, 1);\n" );
    fprintf( Fp, "    luaL_requiref(L, \"coroutine\", luaopen_coroutine, 1); lua_pop(L, 1);\n" );
    fprintf( Fp, "    luaL_requiref(L, \"table\",     luaopen_table,     1); lua_pop(L, 1);\n" );
    if ( !Opts->NoLuaIolib )
        fprintf( Fp, "    luaL_requiref(L, \"io\",        luaopen_io,        1); lua_pop(L, 1);\n" );
    if ( !Opts->NoLuaOslib )
        fprintf( Fp, "    luaL_requiref(L, \"os\",        luaopen_os,        1); lua_pop(L, 1);\n" );
    fprintf( Fp, "    luaL_requiref(L, \"string\",    luaopen_string,    1); lua_pop(L, 1);\n" );
    fprintf( Fp, "    luaL_requiref(L, \"math\",      luaopen_math,      1); lua_pop(L, 1);\n" );
    fprintf( Fp, "    luaL_requiref(L, \"utf8\",      luaopen_utf8,      1); lua_pop(L, 1);\n" );
    if ( !Opts->NoLuaDblib )
        fprintf( Fp, "    luaL_requiref(L, \"debug\",     luaopen_debug,     1); lua_pop(L, 1);\n" );
    fprintf( Fp, "}\n" );
    fclose( Fp );

    char ObjFlags[ 512 ] = { 0 };
    ComposeObjectCompileFlags( Opts, ObjFlags, sizeof( ObjFlags ) );
    int N = snprintf( Cmd, sizeof( Cmd ), "%s%s -c \"%s\" -o \"%s\"",
                      Cc, ObjFlags, OverrideCFull, OverrideObjFull );
    if ( N <= 0 || ( size_t )N >= sizeof( Cmd ) ) {
        DeleteFileA( OverrideCFull );
        return 0;
    }
    if ( !RunCmd( Cmd ) ) {
        fprintf( stderr, "[-] PeLink: linit override compile failed :: %s\n", Cmd );
        DeleteFileA( OverrideCFull );
        return 0;
    }
    return 1;
}

/* --- Phase 2: package tree-shaking helpers --------------------------------
 *
 * The compiler-emitted packages_refs.c provides the dispatch table the
 * runtime reads via Runtime_GetPackages(). It declares extern symbols
 * for every required package's bytecode + length, builds a small
 * REGISTERED_PACKAGE_T[] array, and exposes a getter.
 *
 * The hard-references inside the static initializer are what causes ld
 * to pull in the matching <pkg>_pkg_gen.o files from the packages-obj
 * directory. Packages NOT listed get NO ref, ld doesn't drag them in,
 * their bytes never reach the output binary.
 */

/* Convert dotted package name to underscore-separated filename base.
   e.g. "windows.bcrypt" -> "windows_bcrypt". */
static void PackageNameToFileBase( const char *Name, char *Out, size_t Cap ) {
    size_t N = 0;
    while ( *Name && N + 1 < Cap ) {
        Out[ N++ ] = ( *Name == '.' ) ? '_' : *Name;
        Name++;
    }
    Out[ N ] = 0;
}

/* Convert dotted package name to CamelCase symbol fragment.
   e.g. "windows.bcrypt" -> "WindowsBcrypt". Used for the
   g_Package<X>Lua symbol naming convention. */
static void PackageNameToSymbol( const char *Name, char *Out, size_t Cap ) {
    size_t N = 0;
    int    Cap1 = 1;   /* capitalize next non-separator char */
    while ( *Name && N + 1 < Cap ) {
        char C = *Name;
        if ( C == '_' || C == '.' ) {
            Cap1 = 1;
        } else {
            if ( Cap1 && C >= 'a' && C <= 'z' ) C = ( char )( C - 'a' + 'A' );
            Out[ N++ ] = C;
            Cap1 = 0;
        }
        Name++;
    }
    Out[ N ] = 0;
}

/*!
 * @brief
 *  Generate + compile the per-build packages_refs.c. Writes the .c to
 *  RefsCFull and the .o to RefsObjFull (both under OS temp dir).
 *  Caller owns cleanup of both paths.
 *
 *  When BuiltinPackageCount is 0 a stub is emitted that returns
 *  (NULL, 0) -- the runtime then registers no packages, and no
 *  per-package _pkg_gen.o files get pulled into the link.
 */
static int MakePackagesRefsObject( char **Pkgs, size_t Count,
                                   const char *Cc,
                                   const PE_LINK_OPTS_T *Opts,
                                   char *RefsCFull,    size_t RefsCCap,
                                   char *RefsObjFull,  size_t RefsObjCap ) {
    char TempDir[ MAX_PATH ] = { 0 };
    char Cmd[ 4096 ]         = { 0 };
    char ObjFlags[ 512 ]     = { 0 };
    if ( GetTempPathA( MAX_PATH, TempDir ) == 0 ) return 0;
    snprintf( RefsCFull,   RefsCCap,   "%spkgrefs%lu.c", TempDir,
              ( unsigned long )GetCurrentProcessId( ) );
    snprintf( RefsObjFull, RefsObjCap, "%spkgrefs%lu.o", TempDir,
              ( unsigned long )GetCurrentProcessId( ) );
    ComposeObjectCompileFlags( Opts, ObjFlags, sizeof( ObjFlags ) );

    FILE *Fp = fopen( RefsCFull, "wb" );
    if ( Fp == NULL ) {
        fprintf( stderr, "[-] PeLink: cannot write %s\n", RefsCFull );
        return 0;
    }
    fprintf( Fp, "/* per-build packages dispatch table -- generated by compiler.exe */\n" );
    fprintf( Fp, "#include <stddef.h>\n\n" );
    fprintf( Fp, "typedef struct {\n" );
    fprintf( Fp, "    const char         *Name;\n" );
    fprintf( Fp, "    const char         *Src;\n" );
    fprintf( Fp, "    const unsigned int *LenPtr;\n" );
    fprintf( Fp, "} REGISTERED_PACKAGE_T;\n\n" );
    for ( size_t I = 0; I < Count; I++ ) {
        char Sym[ 256 ] = { 0 };
        PackageNameToSymbol( Pkgs[ I ], Sym, sizeof( Sym ) );
        fprintf( Fp, "extern const char         g_Package%sLua[];\n",     Sym );
        fprintf( Fp, "extern const unsigned int g_Package%sLua_len;\n",   Sym );
    }
    fprintf( Fp, "\n" );
    if ( Count == 0 ) {
        fprintf( Fp, "const REGISTERED_PACKAGE_T *Runtime_GetPackages(size_t *OutCount) {\n" );
        fprintf( Fp, "    if (OutCount) *OutCount = 0;\n" );
        fprintf( Fp, "    return (const REGISTERED_PACKAGE_T *)0;\n" );
        fprintf( Fp, "}\n" );
    } else {
        fprintf( Fp, "static const REGISTERED_PACKAGE_T g_Packages[] = {\n" );
        for ( size_t I = 0; I < Count; I++ ) {
            char Sym[ 256 ] = { 0 };
            PackageNameToSymbol( Pkgs[ I ], Sym, sizeof( Sym ) );
            fprintf( Fp, "    { \"%s\", g_Package%sLua, &g_Package%sLua_len },\n",
                     Pkgs[ I ], Sym, Sym );
        }
        fprintf( Fp, "};\n\n" );
        fprintf( Fp, "const REGISTERED_PACKAGE_T *Runtime_GetPackages(size_t *OutCount) {\n" );
        fprintf( Fp, "    if (OutCount) *OutCount = sizeof(g_Packages) / sizeof(g_Packages[0]);\n" );
        fprintf( Fp, "    return g_Packages;\n" );
        fprintf( Fp, "}\n" );
    }
    fclose( Fp );

    int N = snprintf( Cmd, sizeof( Cmd ), "%s%s -c \"%s\" -o \"%s\"",
                      Cc, ObjFlags, RefsCFull, RefsObjFull );
    if ( N <= 0 || ( size_t )N >= sizeof( Cmd ) ) {
        fprintf( stderr, "[-] PeLink: pkgrefs compile cmdline too long\n" );
        DeleteFileA( RefsCFull );
        return 0;
    }
    if ( !RunCmd( Cmd ) ) {
        fprintf( stderr, "[-] PeLink: pkgrefs compile failed :: %s\n", Cmd );
        DeleteFileA( RefsCFull );
        return 0;
    }
    return 1;
}

/*!
 * @brief
 *  Append the path of each required package's _pkg_gen.o to Buf as a
 *  space-separated quoted list. Buf is appended into; the caller
 *  passes the current write offset and the buffer cap.
 *
 *  Returns the number of bytes written, or -1 on overflow.
 */
static int AppendPackageObjects( char **Pkgs, size_t Count,
                                 const char *PackagesObjDir,
                                 char *Buf, size_t BufCap ) {
    size_t Wrote = 0;
    for ( size_t I = 0; I < Count; I++ ) {
        char Base[ 128 ] = { 0 };
        char Path[ MAX_PATH ] = { 0 };
        PackageNameToFileBase( Pkgs[ I ], Base, sizeof( Base ) );
        snprintf( Path, sizeof( Path ), "%s/%s_pkg_gen.o", PackagesObjDir, Base );
        int N = snprintf( Buf + Wrote, BufCap - Wrote, " \"%s\"", Path );
        if ( N <= 0 || ( size_t )( Wrote + N ) >= BufCap ) return -1;
        Wrote += ( size_t )N;
    }
    return ( int )Wrote;
}

/* Linker invocation for exe/dll. ExtraFlags is a string appended after
   the inputs (e.g. "-shared" for DLLs, "-Wl,--subsystem,console" for exes).
   WholeArchive=1 wraps the runtime + lua archives in --whole-archive so
   the linker can't drop objects that nothing in the DLL surface
   references (needed because luavm_run is the only user-visible export
   but the runtime needs everything to actually work).

   ImguiArchive (optional): if set, link via g++ instead of gcc (to pull
   in the C++ runtime), --whole-archive imgui.a (its dllexport'd entry
   points are only referenced at runtime via FFI, so the linker has no
   compile-time root keeping them alive), add the Win32 + D3D11 + DXGI +
   GDI + DWM system libraries, and pass --export-all-symbols so the host
   shim's dllexport entries end up in the PE export table where
   GetProcAddress can find them. */
static int LinkBlobWithRuntime( const char *Cc,
                                const char *Cxx,
                                const char *BlobObjFull,
                                const char *RuntimeArchive,
                                const char *LuaArchive,
                                const char *ImguiArchive,
                                const char *OutputPath,
                                const char *ExtraFlags,
                                const char *ExtraObjs,
                                int         WholeArchive ) {
    char Cmd[ 8192 ] = { 0 };
    int N;
    const char *Linker = ImguiArchive ? Cxx : Cc;
    const char *ImguiPrefix = ImguiArchive
        ? "-static-libgcc -static-libstdc++ -Wl,--export-all-symbols "
        : "";
    char ImguiArc[ 512 ] = { 0 };
    if ( ImguiArchive ) {
        snprintf( ImguiArc, sizeof( ImguiArc ),
                  " -Wl,--whole-archive \"%s\" -Wl,--no-whole-archive",
                  ImguiArchive );
    }
    const char *ImguiLibs = ImguiArchive
        ? " -ld3d11 -ldxgi -ld3dcompiler -lgdi32 -luser32 -ldwmapi -limm32"
        : "";
    const char *Extras = ExtraObjs ? ExtraObjs : "";

    if ( WholeArchive ) {
        N = snprintf( Cmd, sizeof( Cmd ),
            "%s %s-o \"%s\" \"%s\"%s "
            "-Wl,--whole-archive \"%s\" \"%s\" -Wl,--no-whole-archive%s "
            "-lm -lkernel32 -ladvapi32 -liphlpapi -lpsapi%s %s",
            Linker, ImguiPrefix, OutputPath, BlobObjFull, Extras,
            RuntimeArchive, LuaArchive, ImguiArc,
            ImguiLibs,
            ExtraFlags ? ExtraFlags : "" );
    } else {
        N = snprintf( Cmd, sizeof( Cmd ),
            "%s %s-o \"%s\" \"%s\"%s \"%s\" \"%s\"%s "
            "-lm -lkernel32 -ladvapi32 -liphlpapi -lpsapi%s %s",
            Linker, ImguiPrefix, OutputPath, BlobObjFull, Extras,
            RuntimeArchive, LuaArchive, ImguiArc,
            ImguiLibs,
            ExtraFlags ? ExtraFlags : "" );
    }
    if ( N <= 0 || ( size_t )N >= sizeof( Cmd ) ) {
        fprintf( stderr, "[-] PeLink: link command line too long\n" );
        return 0;
    }
    if ( !RunCmd( Cmd ) ) {
        fprintf( stderr, "[-] PeLink: link failed :: %s\n", Cmd );
        return 0;
    }
    return 1;
}

/* Bundle blob.o + runtime.a + liblua54.a into one static archive. The
   trick: extract every .o from the two input archives into a temp dir,
   then re-ar everything together with blob.o. The resulting .a is a
   one-stop dependency the consumer can link as
       gcc their_main.c our.a -lm -lkernel32 -ladvapi32 */
static int MakeFatLib( const char *Ar,
                       const char *BlobObjFull,
                       const char *RuntimeArchive,
                       const char *LuaArchive,
                       const char *OutputPath ) {
    char TempDir[ MAX_PATH ]   = { 0 };
    char StageDir[ MAX_PATH ]  = { 0 };
    char Cmd[ 4096 ]           = { 0 };

    if ( GetTempPathA( MAX_PATH, TempDir ) == 0 ) { return 0; }
    snprintf( StageDir, sizeof( StageDir ), "%sluavmlib%lu",
              TempDir, ( unsigned long )GetCurrentProcessId( ) );
    if ( CreateDirectoryA( StageDir, NULL ) == 0
            && GetLastError( ) != ERROR_ALREADY_EXISTS ) {
        fprintf( stderr, "[-] PeLink: mkdir %s failed\n", StageDir );
        return 0;
    }

    /* extract runtime.a then liblua54.a into StageDir. ar x's input path
       is interpreted relative to the current directory, so we resolve to
       absolute paths before cd'ing into the stage dir. */
    char RuntimeAbs[ MAX_PATH ] = { 0 };
    char LuaAbs[ MAX_PATH ]     = { 0 };
    if ( GetFullPathNameA( RuntimeArchive, MAX_PATH, RuntimeAbs, NULL ) == 0 ) {
        fprintf( stderr, "[-] PeLink: cannot resolve runtime.a path\n" );
        return 0;
    }
    if ( GetFullPathNameA( LuaArchive, MAX_PATH, LuaAbs, NULL ) == 0 ) {
        fprintf( stderr, "[-] PeLink: cannot resolve liblua54.a path\n" );
        return 0;
    }
    snprintf( Cmd, sizeof( Cmd ),
        "cd /d \"%s\" && %s x \"%s\" && %s x \"%s\"",
        StageDir, Ar, RuntimeAbs, Ar, LuaAbs );
    if ( !RunCmd( Cmd ) ) {
        fprintf( stderr, "[-] PeLink: ar extract failed :: %s\n", Cmd );
        return 0;
    }

    /* copy blob.o into StageDir under a stable name */
    char StagedBlob[ MAX_PATH ] = { 0 };
    snprintf( StagedBlob, sizeof( StagedBlob ), "%s\\luablob.o", StageDir );
    if ( !CopyFileA( BlobObjFull, StagedBlob, FALSE ) ) {
        fprintf( stderr, "[-] PeLink: cannot copy blob.o into stage\n" );
        return 0;
    }

    /* ar rcs the output. cmd.exe doesn't expand globs, so we enumerate
       *.o ourselves and write each filename to a response file that ar
       reads via @file -- avoids the cmd-line length limit too. */
    char OutAbs[ MAX_PATH ] = { 0 };
    if ( GetFullPathNameA( OutputPath, MAX_PATH, OutAbs, NULL ) == 0 ) {
        fprintf( stderr, "[-] PeLink: cannot resolve output path\n" );
        return 0;
    }
    DeleteFileA( OutAbs );  /* ar appends to an existing archive otherwise */

    char RspPath[ MAX_PATH ] = { 0 };
    snprintf( RspPath, sizeof( RspPath ), "%s\\objs.rsp", StageDir );
    FILE *Rsp = fopen( RspPath, "w" );
    if ( Rsp == NULL ) {
        fprintf( stderr, "[-] PeLink: cannot open response file\n" );
        return 0;
    }
    WIN32_FIND_DATAA Find = { 0 };
    char             FindPat[ MAX_PATH ] = { 0 };
    snprintf( FindPat, sizeof( FindPat ), "%s\\*.o", StageDir );
    HANDLE FH = FindFirstFileA( FindPat, &Find );
    int    AnyObj = 0;
    if ( FH != INVALID_HANDLE_VALUE ) {
        do {
            fprintf( Rsp, "%s\n", Find.cFileName );
            AnyObj = 1;
        } while ( FindNextFileA( FH, &Find ) );
        FindClose( FH );
    }
    fclose( Rsp );
    if ( !AnyObj ) {
        fprintf( stderr, "[-] PeLink: no .o files staged in %s\n", StageDir );
        return 0;
    }

    snprintf( Cmd, sizeof( Cmd ),
        "cd /d \"%s\" && %s rcs \"%s\" @objs.rsp",
        StageDir, Ar, OutAbs );
    if ( !RunCmd( Cmd ) ) {
        fprintf( stderr, "[-] PeLink: ar rcs failed :: %s\n", Cmd );
        return 0;
    }
    DeleteFileA( RspPath );

    /* best-effort cleanup: nuke staged .o files and the dir itself */
    {
        WIN32_FIND_DATAA Fd = { 0 };
        char             Pat[ MAX_PATH ] = { 0 };
        snprintf( Pat, sizeof( Pat ), "%s\\*.o", StageDir );
        HANDLE H = FindFirstFileA( Pat, &Fd );
        if ( H != INVALID_HANDLE_VALUE ) {
            do {
                char Full[ MAX_PATH ] = { 0 };
                snprintf( Full, sizeof( Full ), "%s\\%s", StageDir, Fd.cFileName );
                DeleteFileA( Full );
            } while ( FindNextFileA( H, &Fd ) );
            FindClose( H );
        }
        RemoveDirectoryA( StageDir );
    }
    return 1;
}

int PeLink_Bundle( const unsigned char *Blob,
                   size_t               BlobLen,
                   const char          *OutputPath,
                   PPE_LINK_OPTS_T      Opts ) {
    char  BlobBinFull[ MAX_PATH ] = { 0 };
    char  BlobObjFull[ MAX_PATH ] = { 0 };
    char  ObjCopyPath[ MAX_PATH ] = { 0 };
    char  CcPath[ MAX_PATH ]      = { 0 };
    char  CxxPath[ MAX_PATH ]     = { 0 };
    char  ArPath[ MAX_PATH ]      = { 0 };
    const char *Subsystem = DefaultOr( Opts ? Opts->Subsystem : NULL, "console" );
    const char *ObjCopy   = DefaultOr( Opts ? Opts->ObjCopyExe : NULL,
                                       ResolveTool( "objcopy.exe", ObjCopyPath, sizeof( ObjCopyPath ) ) );
    const char *Cc        = DefaultOr( Opts ? Opts->CcExe : NULL,
                                       ResolveTool( "x86_64-w64-mingw32-gcc.exe", CcPath, sizeof( CcPath ) ) );
    const char *Cxx       = DefaultOr( Opts ? Opts->CxxExe : NULL,
                                       ResolveTool( "x86_64-w64-mingw32-g++.exe", CxxPath, sizeof( CxxPath ) ) );
    const char *Ar        = DefaultOr( Opts ? Opts->ArExe : NULL,
                                       ResolveTool( "ar.exe", ArPath, sizeof( ArPath ) ) );
    const char *ImguiArc  = ( Opts != NULL ) ? Opts->ImguiArchive : NULL;
    PE_OUTPUT_TYPE_T Type = ( Opts != NULL ) ? Opts->OutputType : PE_OUT_EXE;

    if ( Blob == NULL || BlobLen == 0 || OutputPath == NULL ) { return 0; }

    /* PE_OUT_BLOB: skip toolchain entirely, just write the bytes. */
    if ( Type == PE_OUT_BLOB ) {
        if ( !WriteAllBytes( OutputPath, Blob, BlobLen ) ) {
            fprintf( stderr, "[-] PeLink: cannot write blob to %s\n", OutputPath );
            return 0;
        }
        return 1;
    }

    /* Every other type needs the blob wrapped as a .o first. We compile
       it as a regular C const array via the C frontend so the bytes
       land in the standard .rdata section -- no dedicated `.luablob`
       section header in the output. (void)ObjCopy: kept resolved
       above for symmetry but no longer used here. */
    ( void )ObjCopy;
    if ( !MakeBlobCObject( Blob, BlobLen, Cc, Opts,
                           BlobBinFull, sizeof( BlobBinFull ),
                           BlobObjFull, sizeof( BlobObjFull ) ) ) {
        return 0;
    }

    /* obj/lib don't need runtime archives, but exe/dll do. */
    if ( ( Type == PE_OUT_EXE || Type == PE_OUT_DLL || Type == PE_OUT_LIB ) &&
         ( Opts == NULL || Opts->RuntimeArchive == NULL ||
           Opts->LuaArchive == NULL ) ) {
        fprintf( stderr, "[-] PeLink: runtime/lua archives required for this output type\n" );
        DeleteFileA( BlobBinFull );
        DeleteFileA( BlobObjFull );
        return 0;
    }

    /* Phase 2 tree-shaking: generate the per-build packages_refs.o and
       collect the per-package _pkg_gen.o paths the runtime needs. Both
       get passed as ExtraObjs to LinkBlobWithRuntime.
       Batch 5: optional linit_override.o joins the same ExtraObjs list
       when any --no-lua-* flag was set. */
    char PkgRefsCFull[ MAX_PATH ]   = { 0 };
    char PkgRefsObjFull[ MAX_PATH ] = { 0 };
    char LinitOvCFull[ MAX_PATH ]   = { 0 };
    char LinitOvObjFull[ MAX_PATH ] = { 0 };
    char BcOnlyCFull[ MAX_PATH ]    = { 0 };
    char BcOnlyObjFull[ MAX_PATH ]  = { 0 };
    char JitOnlyCFull[ MAX_PATH ]   = { 0 };
    char JitOnlyObjFull[ MAX_PATH ] = { 0 };
    char NatRefsCFull[ MAX_PATH ]   = { 0 };
    char NatRefsObjFull[ MAX_PATH ] = { 0 };
    char ExtraObjs[ 4096 ]          = { 0 };
    int  ExtraObjsLen               = 0;
    if ( Type == PE_OUT_EXE || Type == PE_OUT_DLL ) {
        char **Pkgs = ( Opts != NULL ) ? Opts->BuiltinPackages : NULL;
        size_t PCount = ( Opts != NULL ) ? Opts->BuiltinPackageCount : 0;
        const char *PObjDir = ( Opts != NULL && Opts->PackagesObjDir != NULL )
                              ? Opts->PackagesObjDir
                              : "build/bin/obj/runtime/packages";
        if ( !MakePackagesRefsObject( Pkgs, PCount, Cc, Opts,
                                      PkgRefsCFull, sizeof( PkgRefsCFull ),
                                      PkgRefsObjFull, sizeof( PkgRefsObjFull ) ) ) {
            DeleteFileA( BlobBinFull );
            DeleteFileA( BlobObjFull );
            return 0;
        }
        int N = snprintf( ExtraObjs, sizeof( ExtraObjs ),
                          " \"%s\"", PkgRefsObjFull );
        if ( N <= 0 ) ExtraObjsLen = 0;
        else          ExtraObjsLen = N;
        int AppN = AppendPackageObjects( Pkgs, PCount, PObjDir,
                                         ExtraObjs + ExtraObjsLen,
                                         sizeof( ExtraObjs ) - ( size_t )ExtraObjsLen );
        if ( AppN < 0 ) {
            fprintf( stderr, "[-] PeLink: package-object list overflow\n" );
            DeleteFileA( PkgRefsCFull );
            DeleteFileA( PkgRefsObjFull );
            DeleteFileA( BlobBinFull );
            DeleteFileA( BlobObjFull );
            return 0;
        }
        ExtraObjsLen += AppN;
        if ( PCount > 0 ) {
            printf( "[_] packages: linking %zu (%s%s%s%s)\n", PCount,
                    Pkgs[ 0 ],
                    PCount > 1 ? ", " : "",
                    PCount > 1 ? Pkgs[ 1 ] : "",
                    PCount > 2 ? ", ..." : "" );
        }

        /* --no-lua-* override: generate + add linit_override.o to the
           link before liblua54.a so the linker drops unused lib .o's. */
        if ( !MakeLuaInitOverride( Opts, Cc,
                                   LinitOvCFull, sizeof( LinitOvCFull ),
                                   LinitOvObjFull, sizeof( LinitOvObjFull ) ) ) {
            DeleteFileA( PkgRefsCFull );
            DeleteFileA( PkgRefsObjFull );
            DeleteFileA( BlobBinFull );
            DeleteFileA( BlobObjFull );
            return 0;
        }
        if ( LinitOvObjFull[ 0 ] ) {
            int LN = snprintf( ExtraObjs + ExtraObjsLen,
                               sizeof( ExtraObjs ) - ( size_t )ExtraObjsLen,
                               " \"%s\"", LinitOvObjFull );
            if ( LN > 0 && ExtraObjsLen + LN < ( int )sizeof( ExtraObjs ) ) {
                ExtraObjsLen += LN;
            }
            printf( "[_] linit override active (no-iolib=%d no-oslib=%d no-dblib=%d)\n",
                    Opts->NoLuaIolib, Opts->NoLuaOslib, Opts->NoLuaDblib );
        }

        /* --bytecode-only: stub luaY_parser so lparser.o + lcode.o stay
           out of the link. */
        if ( !MakeBytecodeOnlyStub( Opts, Cc,
                                    BcOnlyCFull, sizeof( BcOnlyCFull ),
                                    BcOnlyObjFull, sizeof( BcOnlyObjFull ) ) ) {
            DeleteFileA( PkgRefsCFull );
            DeleteFileA( PkgRefsObjFull );
            DeleteFileA( LinitOvCFull );
            DeleteFileA( LinitOvObjFull );
            DeleteFileA( BlobBinFull );
            DeleteFileA( BlobObjFull );
            return 0;
        }
        if ( BcOnlyObjFull[ 0 ] ) {
            int BN = snprintf( ExtraObjs + ExtraObjsLen,
                               sizeof( ExtraObjs ) - ( size_t )ExtraObjsLen,
                               " \"%s\"", BcOnlyObjFull );
            if ( BN > 0 && ExtraObjsLen + BN < ( int )sizeof( ExtraObjs ) ) {
                ExtraObjsLen += BN;
            }
            printf( "[_] --bytecode-only stub active\n" );
        }

        /* --jit-only: stub luaV_execute so the interpreter loop in
           lvm.o becomes unreachable; --gc-sections then drops it. */
        if ( !MakeJitOnlyStub( Opts, Cc,
                               JitOnlyCFull, sizeof( JitOnlyCFull ),
                               JitOnlyObjFull, sizeof( JitOnlyObjFull ) ) ) {
            DeleteFileA( PkgRefsCFull );
            DeleteFileA( PkgRefsObjFull );
            DeleteFileA( LinitOvCFull );
            DeleteFileA( LinitOvObjFull );
            DeleteFileA( BcOnlyCFull );
            DeleteFileA( BcOnlyObjFull );
            DeleteFileA( BlobBinFull );
            DeleteFileA( BlobObjFull );
            return 0;
        }
        if ( JitOnlyObjFull[ 0 ] ) {
            int JN = snprintf( ExtraObjs + ExtraObjsLen,
                               sizeof( ExtraObjs ) - ( size_t )ExtraObjsLen,
                               " \"%s\"", JitOnlyObjFull );
            if ( JN > 0 && ExtraObjsLen + JN < ( int )sizeof( ExtraObjs ) ) {
                ExtraObjsLen += JN;
            }
            printf( "[_] --jit-only stub active (auto-pair with --gc-sections for max drop)\n" );
        }

        /* Native-DLL embed / sidecar / system handling. The generator
           returns an empty path when no embed-mode deps exist for
           this build (sidecar/system are handled inline, no link
           contribution). */
        if ( !MakeNativeRefsObject( Opts, Cc, OutputPath,
                                    NatRefsCFull, sizeof( NatRefsCFull ),
                                    NatRefsObjFull, sizeof( NatRefsObjFull ) ) ) {
            DeleteFileA( PkgRefsCFull );
            DeleteFileA( PkgRefsObjFull );
            DeleteFileA( LinitOvCFull );
            DeleteFileA( LinitOvObjFull );
            DeleteFileA( BcOnlyCFull );
            DeleteFileA( BcOnlyObjFull );
            DeleteFileA( JitOnlyCFull );
            DeleteFileA( JitOnlyObjFull );
            DeleteFileA( BlobBinFull );
            DeleteFileA( BlobObjFull );
            return 0;
        }
        if ( NatRefsObjFull[ 0 ] ) {
            int NN = snprintf( ExtraObjs + ExtraObjsLen,
                               sizeof( ExtraObjs ) - ( size_t )ExtraObjsLen,
                               " \"%s\"", NatRefsObjFull );
            if ( NN > 0 && ExtraObjsLen + NN < ( int )sizeof( ExtraObjs ) ) {
                ExtraObjsLen += NN;
            }
        }
    }

    int Ok = 0;
    switch ( Type ) {
        case PE_OUT_OBJ: {
            /* Just rename/copy the blob .o to the requested path. */
            DeleteFileA( OutputPath );  /* MoveFileA fails if target exists */
            if ( MoveFileA( BlobObjFull, OutputPath ) == 0 ) {
                /* fall back to copy + delete on cross-volume */
                if ( CopyFileA( BlobObjFull, OutputPath, FALSE ) == 0 ) {
                    fprintf( stderr, "[-] PeLink: cannot place .o at %s\n",
                             OutputPath );
                    break;
                }
                DeleteFileA( BlobObjFull );
            }
            BlobObjFull[ 0 ] = '\0';  /* mark as already-cleaned */
            Ok = 1;
            break;
        }
        case PE_OUT_LIB: {
            Ok = MakeFatLib( Ar, BlobObjFull,
                             Opts->RuntimeArchive, Opts->LuaArchive,
                             OutputPath );
            break;
        }
        case PE_OUT_DLL: {
            char LinkFlags[ 1024 ] = { 0 };
            char ExtraFlags[ 1024 ] = { 0 };
            ComposeLinkLineFlags( Opts, LinkFlags, sizeof( LinkFlags ) );
            snprintf( ExtraFlags, sizeof( ExtraFlags ), "-shared%s", LinkFlags );
            Ok = LinkBlobWithRuntime( Cc, Cxx, BlobObjFull,
                                      Opts->RuntimeArchive, Opts->LuaArchive,
                                      ImguiArc,
                                      OutputPath, ExtraFlags, ExtraObjs,
                                      /*whole=*/1 );
            break;
        }
        case PE_OUT_EXE:
        default: {
            char LinkFlags[ 1024 ] = { 0 };
            char ExtraFlags[ 1024 ] = { 0 };
            ComposeLinkLineFlags( Opts, LinkFlags, sizeof( LinkFlags ) );
            snprintf( ExtraFlags, sizeof( ExtraFlags ),
                      "-Wl,--subsystem,%s%s", Subsystem, LinkFlags );
            Ok = LinkBlobWithRuntime( Cc, Cxx, BlobObjFull,
                                      Opts->RuntimeArchive, Opts->LuaArchive,
                                      ImguiArc,
                                      OutputPath, ExtraFlags, ExtraObjs,
                                      /*whole=*/0 );
            break;
        }
    }

    /* Post-link binary patches: section-name randomization and Rich-header
       scrub. Only meaningful for exe/dll outputs. */
    if ( Ok && ( Type == PE_OUT_EXE || Type == PE_OUT_DLL ) && Opts &&
         ( Opts->Randomize || Opts->RichHeaderStrip ) ) {
        if ( !PostLinkPatchPE( OutputPath, Opts->Randomize, Opts->RichHeaderStrip ) ) {
            fprintf( stderr, "[-] PeLink: post-link PE patch failed (continuing)\n" );
        }
    }

    /* --verify-pe-flags: assert the linker actually set the bits we
       requested. Runs after post-link patches. */
    if ( Ok && ( Type == PE_OUT_EXE || Type == PE_OUT_DLL ) &&
         Opts && Opts->VerifyPeFlags ) {
        ( void )VerifyPeCharacteristics( OutputPath, Opts->HighEntropyVa );
    }

    if ( BlobBinFull[ 0 ] )    DeleteFileA( BlobBinFull );
    if ( BlobObjFull[ 0 ] )    DeleteFileA( BlobObjFull );
    if ( PkgRefsCFull[ 0 ] )   DeleteFileA( PkgRefsCFull );
    if ( PkgRefsObjFull[ 0 ] ) DeleteFileA( PkgRefsObjFull );
    if ( LinitOvCFull[ 0 ] )   DeleteFileA( LinitOvCFull );
    if ( LinitOvObjFull[ 0 ] ) DeleteFileA( LinitOvObjFull );
    if ( BcOnlyCFull[ 0 ] )    DeleteFileA( BcOnlyCFull );
    if ( BcOnlyObjFull[ 0 ] )  DeleteFileA( BcOnlyObjFull );
    if ( JitOnlyCFull[ 0 ] )   DeleteFileA( JitOnlyCFull );
    if ( JitOnlyObjFull[ 0 ] ) DeleteFileA( JitOnlyObjFull );
    if ( NatRefsCFull[ 0 ] )   DeleteFileA( NatRefsCFull );
    if ( NatRefsObjFull[ 0 ] ) DeleteFileA( NatRefsObjFull );
    ( void )ExtraObjsLen;
    return Ok;
}
