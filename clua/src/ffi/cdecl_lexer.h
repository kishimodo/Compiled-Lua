/*!
 * @brief
 *  Tokenizer for cdef strings. Hand-rolled; consumes a NUL-terminated
 *  C source fragment and yields tokens one at a time via Lexer_Next.
 *  Tracks line + column for error reporting.
 */

#ifndef CLUA_FFI_CDECL_LEXER_H
#define CLUA_FFI_CDECL_LEXER_H

#include <stdint.h>

typedef enum {
    TOK_EOF,
    TOK_IDENT,
    TOK_INT_LIT,
    TOK_LBRACE,    TOK_RBRACE,    /* { } */
    TOK_LPAREN,    TOK_RPAREN,    /* ( ) */
    TOK_LBRACKET,  TOK_RBRACKET,  /* [ ] */
    TOK_SEMI,                     /* ; */
    TOK_COMMA,                    /* , */
    TOK_STAR,                     /* * */
    TOK_EQ,                       /* = */
    TOK_QUESTION,                 /* ? (VLA marker: T[?]) */
    TOK_MINUS,                    /* - (sign in enum values: FOO = -1) */
    TOK_PLUS,                     /* + (explicit positive sign) */
    TOK_ELLIPSIS,                 /* ... (C variadic marker) */
    TOK_KW_VOID,
    TOK_KW_BOOL,        /* _Bool */
    TOK_KW_CHAR,
    TOK_KW_SHORT,
    TOK_KW_INT,
    TOK_KW_LONG,
    TOK_KW_SIGNED,
    TOK_KW_UNSIGNED,
    TOK_KW_FLOAT,
    TOK_KW_DOUBLE,
    TOK_KW_STRUCT,
    TOK_KW_UNION,
    TOK_KW_ENUM,
    TOK_KW_TYPEDEF,
    TOK_KW_CONST,
    TOK_KW_VOLATILE,
    TOK_KW_RESTRICT,
    TOK_KW_CALLCONV,    /* __stdcall, __cdecl, __fastcall, __thiscall — ignored */
    TOK_KW_STORAGE,     /* extern, static, register, auto, inline — ignored */
    TOK_ERROR
} TOKEN_TYPE_T;

typedef struct {
    TOKEN_TYPE_T  Type;
    char          Text[ 128 ];    /* IDENT or INT_LIT text; "" for punctuation */
    int64_t       IntValue;       /* TOK_INT_LIT: numeric value */
    int           Line;
    int           Col;
} TOKEN_T, *PTOKEN_T;

typedef struct {
    const char   *Source;
    int           Pos;
    int           Line;
    int           Col;
    char          ErrorMsg[ 128 ];
} LEXER_T, *PLEXER_T;

void Lexer_Init( PLEXER_T Lex, const char *Source );
int Lexer_Next( PLEXER_T Lex, PTOKEN_T Out );

#endif /* CLUA_FFI_CDECL_LEXER_H */
