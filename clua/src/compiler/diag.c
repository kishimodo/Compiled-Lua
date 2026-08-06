#include "compiler/diag.h"
#include "compiler/diag_pretty.h"

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

char *Diag_SlurpFile( const char *Path, size_t *OutLen ) {
    FILE *F = fopen( Path, "rb" );
    long  N;
    char *Buf;
    if ( F == NULL ) { return NULL; }
    fseek( F, 0, SEEK_END );
    N = ftell( F );
    fseek( F, 0, SEEK_SET );
    if ( N < 0 ) { fclose( F ); return NULL; }
    Buf = ( char * )malloc( ( size_t )N + 1 );
    if ( Buf == NULL ) { fclose( F ); return NULL; }
    if ( fread( Buf, 1, ( size_t )N, F ) != ( size_t )N ) { fclose( F ); free( Buf ); return NULL; }
    fclose( F );
    Buf[ N ] = '\0';
    if ( OutLen ) { *OutLen = ( size_t )N; }
    return Buf;
}

/* Copy 1-based line `Line` of `Text` into Out (without its newline). Returns the
 * line length, or -1 if the line doesn't exist. */
static int GetSourceLine( const char *Text, int Line, char *Out, size_t OutSize ) {
    int CurLine = 1;
    const char *P = Text;
    if ( Text == NULL || Line < 1 ) { return -1; }
    while ( CurLine < Line && *P != '\0' ) {
        if ( *P == '\n' ) { CurLine++; }
        P++;
    }
    if ( CurLine != Line ) { return -1; }
    {
        size_t I = 0;
        while ( P[ I ] != '\0' && P[ I ] != '\n' && I + 1 < OutSize ) {
            Out[ I ] = ( P[ I ] == '\r' ) ? ' ' : P[ I ];
            I++;
        }
        Out[ I ] = '\0';
        return ( int )I;
    }
}

/* Route through the rustc/clang-style pretty printer. Col <= 0 means "unknown
 * column" -- we point the caret at the first non-blank character of the source
 * line so the reader still gets a location hint. When SourceText is NULL (file
 * unreadable / missing) the snippet block is dropped entirely. */
static void PrintDiag( const char *File, int Line, int Col,
                       const char *Category,
                       const char *Message,
                       const char *SourceText ) {
    char LineBuf[ 1024 ];
    int  Len = ( SourceText != NULL )
             ? GetSourceLine( SourceText, Line, LineBuf, sizeof( LineBuf ) )
             : -1;
    int  Caret = Col;
    if ( Len >= 0 && Caret < 1 ) {
        int I = 0;
        while ( I < Len && ( LineBuf[ I ] == ' ' || LineBuf[ I ] == '\t' ) ) { I++; }
        Caret = I + 1;
    }
    if ( Caret < 1 ) { Caret = 1; }
    LcDiag_PrintError( stderr, File, Line, Caret,
                       Category, Message,
                       ( Len >= 0 ) ? LineBuf : NULL );
}

/* Parse a Lua loader error "<chunk>:<line>: <message>". Returns 1 with *OutLine
 * and *OutMsg (pointer into Raw) set. Chunk text itself is ignored (we relabel
 * to the real source path). */
static int ParseLuaError( const char *Raw, int *OutLine, const char **OutMsg ) {
    const char *P = Raw, *Colon1 = NULL, *Colon2 = NULL;
    if ( Raw == NULL ) { return 0; }
    /* find the LAST ":<digits>:" pattern near the start: chunk names can contain
       ':' (drive letters), so scan for "<n>:" where the segment after the first
       colon is all digits. Simplest robust approach: find the first ": " that is
       preceded by digits. */
    for ( ; *P != '\0'; P++ ) {
        if ( *P == ':' && P[ 1 ] >= '0' && P[ 1 ] <= '9' ) {
            const char *D = P + 1;
            while ( *D >= '0' && *D <= '9' ) { D++; }
            if ( *D == ':' ) { Colon1 = P; Colon2 = D; break; }
        }
    }
    if ( Colon1 == NULL ) { return 0; }
    *OutLine = atoi( Colon1 + 1 );
    *OutMsg  = Colon2 + 1;
    while ( **OutMsg == ' ' ) { ( *OutMsg )++; }
    return 1;
}

/* Best-effort column from a `near '<token>'` clause: locate the token in the
 * source line. Returns 1-based column, or 0 if not determinable. */
static int ColumnFromNear( const char *Message, const char *SourceText, int Line ) {
    const char *Near = strstr( Message, "near '" );
    char Token[ 128 ];
    char LineBuf[ 1024 ];
    size_t TI = 0;
    const char *T;
    if ( Near == NULL ) { return 0; }
    T = Near + 6;
    while ( *T != '\0' && *T != '\'' && TI + 1 < sizeof( Token ) ) { Token[ TI++ ] = *T++; }
    Token[ TI ] = '\0';
    if ( TI == 0 ) { return 0; }
    if ( SourceText == NULL ) { return 0; }
    if ( GetSourceLine( SourceText, Line, LineBuf, sizeof( LineBuf ) ) < 0 ) { return 0; }
    {
        char *Hit = strstr( LineBuf, Token );
        if ( Hit == NULL ) { return 0; }
        return ( int )( Hit - LineBuf ) + 1;
    }
}

void Diag_PrintCompileError( const char *SourcePath, const char *RawLuaErr,
                             int PrefixLines, const DIAG_OPTS_T *Opts ) {
    int   Line = 0;
    const char *Msg = NULL;
    char *Src;
    size_t SrcLen = 0;
    ( void )Opts;                             /* legacy plumb; color mode is now process-global */

    if ( !ParseLuaError( RawLuaErr, &Line, &Msg ) ) {
        /* Couldn't parse -- fall back to the located header only (no snippet). */
        LcDiag_PrintError( stderr,
                           SourcePath ? SourcePath : "<source>",
                           1, 1, "error",
                           RawLuaErr ? RawLuaErr : "(unknown error)",
                           NULL );
        return;
    }
    Line -= PrefixLines;                      /* map @injected line back to user source */
    if ( Line < 1 ) { Line = 1; }
    Src = SourcePath ? Diag_SlurpFile( SourcePath, &SrcLen ) : NULL;
    {
        int Col = ColumnFromNear( Msg, Src, Line );
        PrintDiag( SourcePath ? SourcePath : "<source>", Line, Col,
                   "error", Msg, Src );
    }
    free( Src );
}

/* ----- lint pass ----------------------------------------------------------- */

int Diag_RunLint( const char *SourcePath, const char *LintSource,
                  const DIAG_OPTS_T *Opts ) {
    lua_State *L;
    char      *Src;
    size_t     SrcLen = 0;
    int        Findings = 0;

    if ( Opts == NULL || !Opts->Warnings ) { return 0; }
    if ( LintSource == NULL || SourcePath == NULL ) { return 0; }
    Src = Diag_SlurpFile( SourcePath, &SrcLen );
    if ( Src == NULL ) { return 0; }

    L = luaL_newstate( );
    if ( L == NULL ) { free( Src ); return 0; }
    luaL_openlibs( L );

    /* load + run the lint module source -> module table on the stack */
    if ( luaL_loadbuffer( L, LintSource, strlen( LintSource ), "@lint" ) != LUA_OK ||
         lua_pcall( L, 0, 1, 0 ) != LUA_OK ) {
        lua_close( L ); free( Src );
        return 0;                          /* lint unavailable -> skip silently */
    }
    if ( !lua_istable( L, -1 ) ) { lua_close( L ); free( Src ); return 0; }

    lua_getfield( L, -1, "check" );        /* M.check */
    if ( !lua_isfunction( L, -1 ) ) { lua_close( L ); free( Src ); return 0; }
    lua_pushlstring( L, Src, SrcLen );     /* arg1: source */
    lua_newtable( L );                     /* arg2: opts (defaults) */
    if ( lua_pcall( L, 2, 1, 0 ) != LUA_OK || !lua_istable( L, -1 ) ) {
        lua_close( L ); free( Src );
        return 0;
    }

    /* iterate the issues array: each is { line, col, severity, code, message } */
    {
        lua_Integer N = ( lua_Integer )lua_rawlen( L, -1 );
        lua_Integer I;
        for ( I = 1; I <= N; I++ ) {
            int  Line = 0, Col = 0;
            const char *Sev = "warning", *Code = "", *Message = "";
            lua_rawgeti( L, -1, I );       /* issue table */
            if ( lua_istable( L, -1 ) ) {
                lua_getfield( L, -1, "line" );    Line = ( int )lua_tointeger( L, -1 ); lua_pop( L, 1 );
                lua_getfield( L, -1, "col" );     Col  = ( int )lua_tointeger( L, -1 ); lua_pop( L, 1 );
                lua_getfield( L, -1, "severity" );if ( lua_isstring( L, -1 ) ) Sev = lua_tostring( L, -1 ); lua_pop( L, 1 );
                lua_getfield( L, -1, "code" );    if ( lua_isstring( L, -1 ) ) Code = lua_tostring( L, -1 ); lua_pop( L, 1 );
                lua_getfield( L, -1, "message" ); if ( lua_isstring( L, -1 ) ) Message = lua_tostring( L, -1 ); lua_pop( L, 1 );

                {
                    /* Display category: --Werror promotes everything to error;
                       else lint "error" findings are advisory -> shown as
                       warnings so the label is truthful about whether the
                       build fails. Bracket the code (E001/W001) into the
                       message so the rustc-style header carries it. */
                    int        IsInfo   = ( strcmp( Sev, "info" ) == 0 );
                    const char *Cat     = Opts->WarningsAsErrors ? "error"
                                        : IsInfo                 ? "note"
                                                                 : "warning";
                    char        Buf[ 512 ];
                    const char *ShownMsg = Message;
                    if ( Code && Code[ 0 ] ) {
                        int W = snprintf( Buf, sizeof( Buf ), "[%s] %s", Code, Message );
                        if ( W > 0 ) { ShownMsg = Buf; }
                    }
                    PrintDiag( SourcePath, Line, Col, Cat, ShownMsg, Src );
                    Findings++;
                }
            }
            lua_pop( L, 1 );               /* issue */
        }
    }

    lua_close( L );
    free( Src );
    return Findings;
}
