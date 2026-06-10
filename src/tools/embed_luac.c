/*!
 * @brief
 *  Compile a Lua source file to Lua 5.4 bytecode and write it out as
 *  a C source file embedding the bytecode as a `const char[]` array
 *  + a matching `_len` constant. The runtime's luaL_loadbuffer
 *  handles both bytecode and source transparently, so this drops in
 *  as a replacement for tools/embed-lua.ps1's source-only emit.
 *
 *  Usage:
 *      embed_luac.exe <input.lua> <output.c> <symbol_name>
 *
 *  Generated output:
 *      const char SYMBOL[N] = { 0x1B, 0x4C, 0x75, 0x61, ... };
 *      const unsigned int SYMBOL_len = N;
 *
 *  This is the build-time equivalent of `string.dump(load(src))` --
 *  the `\x1B\x4CuaT\0` Lua-bytecode signature is what triggers
 *  luaL_loadbuffer's binary path at runtime.
 *
 *  Batch 7 of the size-reduction work. Lua bytecode for the
 *  cdef-heavy windows package is ~30-50% the size of the source.
 */

#include "lua.h"
#include "lauxlib.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

/* In-memory writer: lua_dump streams chunks here; we accumulate into
   a malloc'd buffer so we can optionally compress before emitting. */
typedef struct {
    unsigned char *Buf;
    size_t         Len;
    size_t         Cap;
} MEM_WRITER_T;

static int MemWriter( lua_State *L, const void *Buf, size_t Sz, void *Ud ) {
    ( void )L;
    MEM_WRITER_T *W = ( MEM_WRITER_T * )Ud;
    if ( W->Len + Sz > W->Cap ) {
        size_t NewCap = W->Cap ? W->Cap * 2 : 4096;
        while ( NewCap < W->Len + Sz ) NewCap *= 2;
        unsigned char *NewBuf = ( unsigned char * )realloc( W->Buf, NewCap );
        if ( NewBuf == NULL ) return 1;
        W->Buf = NewBuf;
        W->Cap = NewCap;
    }
    memcpy( W->Buf + W->Len, Buf, Sz );
    W->Len += Sz;
    return 0;
}

static void EmitBytes( FILE *Fp, const unsigned char *Bytes, size_t Len ) {
    for ( size_t I = 0; I < Len; I++ ) {
        if ( ( I % 16 ) == 0 ) fprintf( Fp, "    " );
        fprintf( Fp, "0x%02X,", ( unsigned )Bytes[ I ] );
        if ( ( I % 16 ) == 15 || I + 1 == Len ) fprintf( Fp, "\n" );
        else                                    fprintf( Fp, " " );
    }
}

/* XPRESS_HUFF compression via ntdll. Matches the runtime decompress
   path: LVC1 magic + uint32 original length + compressed payload.
   Returns malloc'd output buffer + length, or NULL on failure.
   Caller owns Out. */
#define EMBED_PKG_COMPRESS_MAGIC  0x3143564Cu  /* 'LVC1' */
#define EMBED_PKG_COMPRESSION_FMT 4            /* COMPRESSION_FORMAT_XPRESS_HUFF */

typedef LONG ( WINAPI *PRtlGetCompressionWorkSpaceSize )(
    USHORT, PULONG, PULONG );
typedef LONG ( WINAPI *PRtlCompressBuffer )(
    USHORT, PUCHAR, ULONG, PUCHAR, ULONG, ULONG, PULONG, PVOID );

static unsigned char *CompressBytes( const unsigned char *In, size_t InLen,
                                     size_t *OutLen ) {
    HMODULE Nt = GetModuleHandleA( "ntdll.dll" );
    if ( Nt == NULL ) Nt = LoadLibraryA( "ntdll.dll" );
    if ( Nt == NULL ) return NULL;
    PRtlGetCompressionWorkSpaceSize GetWss = ( PRtlGetCompressionWorkSpaceSize )( void * )
        GetProcAddress( Nt, "RtlGetCompressionWorkSpaceSize" );
    PRtlCompressBuffer              Comp   = ( PRtlCompressBuffer )( void * )
        GetProcAddress( Nt, "RtlCompressBuffer" );
    if ( GetWss == NULL || Comp == NULL ) return NULL;
    ULONG WssMain = 0, WssFrag = 0;
    if ( GetWss( EMBED_PKG_COMPRESSION_FMT, &WssMain, &WssFrag ) != 0 ) return NULL;
    void *Workspace = malloc( WssMain );
    if ( Workspace == NULL ) return NULL;
    /* Worst-case output: a hair larger than input. Allocate 1.05x + slack. */
    size_t        OutCap = InLen + ( InLen / 16 ) + 1024;
    unsigned char *Out   = ( unsigned char * )malloc( OutCap + 8 );
    if ( Out == NULL ) { free( Workspace ); return NULL; }
    ULONG Written = 0;
    LONG  St = Comp( EMBED_PKG_COMPRESSION_FMT,
                     ( PUCHAR )In, ( ULONG )InLen,
                     ( PUCHAR )( Out + 8 ), ( ULONG )OutCap,
                     4096, &Written, Workspace );
    free( Workspace );
    if ( St != 0 ) { free( Out ); return NULL; }
    /* Prepend the magic + original-length header. */
    *( uint32_t * )( Out + 0 ) = EMBED_PKG_COMPRESS_MAGIC;
    *( uint32_t * )( Out + 4 ) = ( uint32_t )InLen;
    *OutLen = ( size_t )Written + 8;
    return Out;
}

int main( int Argc, char **Argv ) {
    if ( Argc < 4 ) {
        fprintf( stderr,
                 "usage: embed_luac.exe <input.lua> <output.c> <symbol_name> [--no-compress]\n" );
        return EXIT_FAILURE;
    }
    const char *InPath    = Argv[ 1 ];
    const char *OutPath   = Argv[ 2 ];
    const char *Symbol    = Argv[ 3 ];
    int         Compress  = 1;  /* default ON */
    if ( Argc > 4 && strcmp( Argv[ 4 ], "--no-compress" ) == 0 ) {
        Compress = 0;
    }

    lua_State *L = luaL_newstate( );
    if ( L == NULL ) {
        fprintf( stderr, "embed_luac: luaL_newstate failed\n" );
        return EXIT_FAILURE;
    }

    if ( luaL_loadfile( L, InPath ) != LUA_OK ) {
        fprintf( stderr, "embed_luac: load %s failed: %s\n",
                 InPath, lua_tostring( L, -1 ) );
        lua_close( L );
        return EXIT_FAILURE;
    }

    /* Dump bytecode into a memory buffer first (strip=1 to drop debug
       symbols / line tables). Then optionally LVC1+XPRESS_HUFF
       compress before emit. */
    MEM_WRITER_T MW = { 0 };
    if ( lua_dump( L, MemWriter, &MW, 1 ) != 0 ) {
        fprintf( stderr, "embed_luac: lua_dump failed\n" );
        lua_close( L );
        return EXIT_FAILURE;
    }
    lua_close( L );

    const unsigned char *EmitBuf    = MW.Buf;
    size_t               EmitLen    = MW.Len;
    unsigned char       *CompBuf    = NULL;
    if ( Compress ) {
        size_t CompLen = 0;
        CompBuf = CompressBytes( MW.Buf, MW.Len, &CompLen );
        /* Only swap to compressed form if it's actually smaller; tiny
           inputs sometimes inflate via header overhead. */
        if ( CompBuf != NULL && CompLen + 16 < EmitLen ) {
            EmitBuf = CompBuf;
            EmitLen = CompLen;
        }
    }

    FILE *Out = fopen( OutPath, "wb" );
    if ( Out == NULL ) {
        fprintf( stderr, "embed_luac: cannot open %s\n", OutPath );
        free( CompBuf ); free( MW.Buf );
        return EXIT_FAILURE;
    }

    fprintf( Out, "/* AUTO-GENERATED bytecode embed of %s (raw=%zu emit=%zu%s). DO NOT EDIT. */\n\n",
             InPath, MW.Len, EmitLen,
             EmitBuf == CompBuf ? " LVC1" : "" );
    fprintf( Out, "__attribute__((aligned(8)))\n" );
    fprintf( Out, "const char %s[] = {\n", Symbol );
    EmitBytes( Out, EmitBuf, EmitLen );
    fprintf( Out, "};\n" );
    fprintf( Out, "const unsigned int %s_len = sizeof(%s);\n", Symbol, Symbol );

    fclose( Out );
    free( CompBuf );
    free( MW.Buf );
    return EXIT_SUCCESS;
}
