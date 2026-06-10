/*!
 * @brief
 *  Hand-rolled tokenizer for cdef strings.
 */

#include "ffi/cdecl_lexer.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const char  *Word;
    TOKEN_TYPE_T Tok;
} KEYWORD_T;

static const KEYWORD_T g_Keywords[ ] = {
    { "void",     TOK_KW_VOID     },
    { "_Bool",    TOK_KW_BOOL     },
    { "char",     TOK_KW_CHAR     },
    { "short",    TOK_KW_SHORT    },
    { "int",      TOK_KW_INT      },
    { "long",     TOK_KW_LONG     },
    { "signed",   TOK_KW_SIGNED   },
    { "unsigned", TOK_KW_UNSIGNED },
    { "float",    TOK_KW_FLOAT    },
    { "double",   TOK_KW_DOUBLE   },
    { "struct",   TOK_KW_STRUCT   },
    { "union",    TOK_KW_UNION    },
    { "enum",     TOK_KW_ENUM     },
    { "typedef",  TOK_KW_TYPEDEF  },
    { "const",    TOK_KW_CONST    },
    { "volatile", TOK_KW_VOLATILE },
    { "restrict", TOK_KW_RESTRICT },
    /* MSVC / MinGW calling-convention modifiers. We don't model multiple
       calling conventions; the parser silently consumes these so cdef text
       generated from Windows SDK headers (where every COM vtable entry is
       __stdcall) loads cleanly. */
    { "__stdcall",   TOK_KW_CALLCONV },
    { "__cdecl",     TOK_KW_CALLCONV },
    { "__fastcall",  TOK_KW_CALLCONV },
    { "__thiscall",  TOK_KW_CALLCONV },
    { "__vectorcall",TOK_KW_CALLCONV },
    { "WINAPI",      TOK_KW_CALLCONV },
    { "CALLBACK",    TOK_KW_CALLCONV },
    { "APIENTRY",    TOK_KW_CALLCONV },
    { "NTAPI",       TOK_KW_CALLCONV },
    /* Storage-class / function specifiers. For an FFI declaration parser the
       storage class carries no type information, so these are silently
       consumed. `extern <type> <name>;` is how a DLL-exported global (e.g.
       oniguruma's OnigEncodingUTF8) is declared — it parses as an ordinary
       declaration once the keyword is skipped. */
    { "extern",      TOK_KW_STORAGE  },
    { "static",      TOK_KW_STORAGE  },
    { "register",    TOK_KW_STORAGE  },
    { "auto",        TOK_KW_STORAGE  },
    { "inline",      TOK_KW_STORAGE  },
    { "__inline",    TOK_KW_STORAGE  },
    { "__forceinline", TOK_KW_STORAGE },
    /* C11 atomic qualifier: `_Atomic int x;`. Carries no layout info for FFI
       (we access atomics as plain memory), so skip it like a CV-qualifier.
       The `_Atomic(T)` type-specifier form is not handled (no bundled user). */
    { "_Atomic",     TOK_KW_STORAGE  }
};
#define NUM_KEYWORDS ( sizeof( g_Keywords ) / sizeof( g_Keywords[ 0 ] ) )

void Lexer_Init( PLEXER_T Lex, const char *Source ) {
    memset( Lex, 0, sizeof( *Lex ) );
    Lex->Source = Source;
    Lex->Pos    = 0;
    Lex->Line   = 1;
    Lex->Col    = 1;
}

static int Peek( PLEXER_T L, int Ahead ) {
    return ( unsigned char )L->Source[ L->Pos + Ahead ];
}

static void Advance( PLEXER_T L ) {
    char C = L->Source[ L->Pos ];
    if ( C == '\0' ) return;
    L->Pos++;
    if ( C == '\n' ) {
        L->Line++;
        L->Col = 1;
    } else {
        L->Col++;
    }
}

static void SkipWhitespaceAndComments( PLEXER_T L ) {
    for ( ;; ) {
        int C = Peek( L, 0 );
        if ( C == ' ' || C == '\t' || C == '\r' || C == '\n' ) {
            Advance( L );
        } else if ( C == '/' && Peek( L, 1 ) == '/' ) {
            while ( Peek( L, 0 ) != '\n' && Peek( L, 0 ) != 0 ) Advance( L );
        } else if ( C == '/' && Peek( L, 1 ) == '*' ) {
            Advance( L ); Advance( L );
            while ( Peek( L, 0 ) != 0 && !( Peek( L, 0 ) == '*' && Peek( L, 1 ) == '/' ) ) {
                Advance( L );
            }
            if ( Peek( L, 0 ) == '*' ) { Advance( L ); Advance( L ); }
        } else {
            break;
        }
    }
}

static int IsIdentStart( int C ) {
    return ( C >= 'a' && C <= 'z' ) || ( C >= 'A' && C <= 'Z' ) || C == '_';
}

static int IsIdentCont( int C ) {
    return IsIdentStart( C ) || ( C >= '0' && C <= '9' );
}

static int LookupKeyword( const char *Text, TOKEN_TYPE_T *Out ) {
    size_t I = { 0 };
    for ( I = 0; I < NUM_KEYWORDS; I++ ) {
        if ( strcmp( g_Keywords[ I ].Word, Text ) == 0 ) {
            *Out = g_Keywords[ I ].Tok;
            return 1;
        }
    }
    return 0;
}

int Lexer_Next( PLEXER_T Lex, PTOKEN_T Out ) {
    memset( Out, 0, sizeof( *Out ) );
    SkipWhitespaceAndComments( Lex );

    int StartLine = Lex->Line;
    int StartCol  = Lex->Col;
    int C         = Peek( Lex, 0 );

    Out->Line = StartLine;
    Out->Col  = StartCol;

    if ( C == 0 ) {
        Out->Type = TOK_EOF;
        return 1;
    }

    /* identifier or keyword */
    if ( IsIdentStart( C ) ) {
        int N = 0;
        while ( IsIdentCont( Peek( Lex, 0 ) ) && N < ( int )sizeof( Out->Text ) - 1 ) {
            Out->Text[ N++ ] = ( char )Peek( Lex, 0 );
            Advance( Lex );
        }
        Out->Text[ N ] = '\0';
        TOKEN_TYPE_T Kw = TOK_IDENT;
        if ( LookupKeyword( Out->Text, &Kw ) ) {
            Out->Type = Kw;
        } else {
            Out->Type = TOK_IDENT;
        }
        return 1;
    }

    /* integer literal */
    if ( C >= '0' && C <= '9' ) {
        int N    = 0;
        int Base = 10;
        if ( C == '0' && ( Peek( Lex, 1 ) == 'x' || Peek( Lex, 1 ) == 'X' ) ) {
            Out->Text[ N++ ] = '0';
            Out->Text[ N++ ] = 'x';
            Advance( Lex ); Advance( Lex );
            Base = 16;
        }
        while ( N < ( int )sizeof( Out->Text ) - 1 ) {
            int D      = Peek( Lex, 0 );
            int IsDigit = 0;
            if ( Base == 10 && D >= '0' && D <= '9' ) IsDigit = 1;
            else if ( Base == 16 && ( ( D >= '0' && D <= '9' ) || ( D >= 'a' && D <= 'f' ) || ( D >= 'A' && D <= 'F' ) ) ) IsDigit = 1;
            if ( !IsDigit ) break;
            Out->Text[ N++ ] = ( char )D;
            Advance( Lex );
        }
        Out->Text[ N ] = '\0';
        Out->Type      = TOK_INT_LIT;
        Out->IntValue  = ( int64_t )strtoll( Out->Text, NULL, Base == 16 ? 16 : 10 );
        return 1;
    }

    /* punctuation */
    switch ( C ) {
    case '{':  Advance( Lex ); Out->Type = TOK_LBRACE;   return 1;
    case '}':  Advance( Lex ); Out->Type = TOK_RBRACE;   return 1;
    case '(':  Advance( Lex ); Out->Type = TOK_LPAREN;   return 1;
    case ')':  Advance( Lex ); Out->Type = TOK_RPAREN;   return 1;
    case '[':  Advance( Lex ); Out->Type = TOK_LBRACKET; return 1;
    case ']':  Advance( Lex ); Out->Type = TOK_RBRACKET; return 1;
    case ';':  Advance( Lex ); Out->Type = TOK_SEMI;     return 1;
    case ',':  Advance( Lex ); Out->Type = TOK_COMMA;    return 1;
    case '*':  Advance( Lex ); Out->Type = TOK_STAR;     return 1;
    case '=':  Advance( Lex ); Out->Type = TOK_EQ;       return 1;
    case '?':  Advance( Lex ); Out->Type = TOK_QUESTION; return 1;
    case '-':  Advance( Lex ); Out->Type = TOK_MINUS;    return 1;
    case '+':  Advance( Lex ); Out->Type = TOK_PLUS;     return 1;
    case '.':
        /* "..." C variadic marker -- only valid form starting with '.' */
        if ( Peek( Lex, 1 ) == '.' && Peek( Lex, 2 ) == '.' ) {
            Advance( Lex ); Advance( Lex ); Advance( Lex );
            Out->Type = TOK_ELLIPSIS;
            return 1;
        }
        break;
    }

    snprintf( Lex->ErrorMsg, sizeof( Lex->ErrorMsg ),
              "unexpected character '%c' (0x%02X) at line %d col %d",
              ( char )C, C, StartLine, StartCol );
    Out->Type = TOK_ERROR;
    Advance( Lex );  /* consume to avoid infinite loop on retry */
    return 0;
}
