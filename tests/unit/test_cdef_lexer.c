/* test_cdef_lexer.c -- tokenisation of C declaration strings via cdecl_lexer.
 * Exercises: keywords, identifiers, punctuation, integer literals (decimal +
 * hex), comment skipping, line/col tracking, calling-convention and storage-
 * class tokens, the ellipsis token, and unknown-character error paths. */

#include "test_harness.h"
#include "ffi/cdecl_lexer.h"

/* Helper: advance the lexer and check the token type + optional text. */
static int NextIs(PLEXER_T Lex, TOKEN_TYPE_T Expect, const char *Text) {
    TOKEN_T Tok;
    Tok.Type = TOK_EOF;
    Tok.Text[0] = '\0';
    Tok.IntValue = 0;
    Tok.Line = 0;
    Tok.Col = 0;
    if (!Lexer_Next(Lex, &Tok)) return 0;
    if (Tok.Type != Expect) return 0;
    if (Text != NULL && Tok.Text[0] != '\0') {
        /* only compare Text when the caller supplied a non-NULL reference */
        if (strcmp(Tok.Text, Text) != 0) return 0;
    }
    return 1;
}

int main(void) {
    TEST_BEGIN("cdef_lexer");

    LEXER_T Lex;
    TOKEN_T Tok;

    /* --- keywords + ident + semicolon --- */
    Lexer_Init(&Lex, "typedef int MyInt;");
    CHECK(NextIs(&Lex, TOK_KW_TYPEDEF, NULL));
    CHECK(NextIs(&Lex, TOK_KW_INT,     NULL));
    CHECK(NextIs(&Lex, TOK_IDENT,      "MyInt"));
    CHECK(NextIs(&Lex, TOK_SEMI,       NULL));
    CHECK(NextIs(&Lex, TOK_EOF,        NULL));

    /* --- all punctuation tokens --- */
    Lexer_Init(&Lex, "{ } ( ) [ ] * , ; = ? - + ...");
    CHECK(NextIs(&Lex, TOK_LBRACE,    NULL));
    CHECK(NextIs(&Lex, TOK_RBRACE,    NULL));
    CHECK(NextIs(&Lex, TOK_LPAREN,    NULL));
    CHECK(NextIs(&Lex, TOK_RPAREN,    NULL));
    CHECK(NextIs(&Lex, TOK_LBRACKET,  NULL));
    CHECK(NextIs(&Lex, TOK_RBRACKET,  NULL));
    CHECK(NextIs(&Lex, TOK_STAR,      NULL));
    CHECK(NextIs(&Lex, TOK_COMMA,     NULL));
    CHECK(NextIs(&Lex, TOK_SEMI,      NULL));
    CHECK(NextIs(&Lex, TOK_EQ,        NULL));
    CHECK(NextIs(&Lex, TOK_QUESTION,  NULL));
    CHECK(NextIs(&Lex, TOK_MINUS,     NULL));
    CHECK(NextIs(&Lex, TOK_PLUS,      NULL));
    CHECK(NextIs(&Lex, TOK_ELLIPSIS,  NULL));
    CHECK(NextIs(&Lex, TOK_EOF,       NULL));

    /* --- integer literals: decimal, zero, hex --- */
    Lexer_Init(&Lex, "256 0 0x10 0xff");
    Tok.Type = TOK_EOF; Tok.IntValue = 0;
    CHECK(Lexer_Next(&Lex, &Tok));
    CHECK_EQ_INT(Tok.Type,     TOK_INT_LIT);
    CHECK_EQ_INT(Tok.IntValue, 256);

    Tok.IntValue = -1;
    CHECK(Lexer_Next(&Lex, &Tok));
    CHECK_EQ_INT(Tok.IntValue, 0);

    CHECK(Lexer_Next(&Lex, &Tok));
    CHECK_EQ_INT(Tok.IntValue, 16);

    CHECK(Lexer_Next(&Lex, &Tok));
    CHECK_EQ_INT(Tok.IntValue, 255);

    /* --- C-block comment and C++-line comment are skipped --- */
    Lexer_Init(&Lex, "int /* skip */ x; // line comment\nfloat");
    CHECK(NextIs(&Lex, TOK_KW_INT,   NULL));
    CHECK(NextIs(&Lex, TOK_IDENT,    "x"));
    CHECK(NextIs(&Lex, TOK_SEMI,     NULL));
    CHECK(NextIs(&Lex, TOK_KW_FLOAT, NULL));
    CHECK(NextIs(&Lex, TOK_EOF,      NULL));

    /* --- line / col tracking --- */
    Lexer_Init(&Lex, "int\n  short");
    Tok.Line = 0;
    CHECK(Lexer_Next(&Lex, &Tok));
    CHECK_EQ_INT(Tok.Type, TOK_KW_INT);
    CHECK_EQ_INT(Tok.Line, 1);

    Tok.Line = 0; Tok.Col = 0;
    CHECK(Lexer_Next(&Lex, &Tok));
    CHECK_EQ_INT(Tok.Type, TOK_KW_SHORT);
    CHECK_EQ_INT(Tok.Line, 2);
    CHECK_EQ_INT(Tok.Col,  3);

    /* --- all type keywords --- */
    Lexer_Init(&Lex,
        "void _Bool char short int long "
        "signed unsigned float double "
        "struct union enum typedef const volatile restrict");
    CHECK(NextIs(&Lex, TOK_KW_VOID,      NULL));
    CHECK(NextIs(&Lex, TOK_KW_BOOL,      NULL));
    CHECK(NextIs(&Lex, TOK_KW_CHAR,      NULL));
    CHECK(NextIs(&Lex, TOK_KW_SHORT,     NULL));
    CHECK(NextIs(&Lex, TOK_KW_INT,       NULL));
    CHECK(NextIs(&Lex, TOK_KW_LONG,      NULL));
    CHECK(NextIs(&Lex, TOK_KW_SIGNED,    NULL));
    CHECK(NextIs(&Lex, TOK_KW_UNSIGNED,  NULL));
    CHECK(NextIs(&Lex, TOK_KW_FLOAT,     NULL));
    CHECK(NextIs(&Lex, TOK_KW_DOUBLE,    NULL));
    CHECK(NextIs(&Lex, TOK_KW_STRUCT,    NULL));
    CHECK(NextIs(&Lex, TOK_KW_UNION,     NULL));
    CHECK(NextIs(&Lex, TOK_KW_ENUM,      NULL));
    CHECK(NextIs(&Lex, TOK_KW_TYPEDEF,   NULL));
    CHECK(NextIs(&Lex, TOK_KW_CONST,     NULL));
    CHECK(NextIs(&Lex, TOK_KW_VOLATILE,  NULL));
    CHECK(NextIs(&Lex, TOK_KW_RESTRICT,  NULL));

    /* --- calling-convention tokens: all map to TOK_KW_CALLCONV --- */
    Lexer_Init(&Lex, "__stdcall __cdecl __fastcall __thiscall WINAPI CALLBACK NTAPI");
    CHECK(NextIs(&Lex, TOK_KW_CALLCONV, NULL));
    CHECK(NextIs(&Lex, TOK_KW_CALLCONV, NULL));
    CHECK(NextIs(&Lex, TOK_KW_CALLCONV, NULL));
    CHECK(NextIs(&Lex, TOK_KW_CALLCONV, NULL));
    CHECK(NextIs(&Lex, TOK_KW_CALLCONV, NULL));
    CHECK(NextIs(&Lex, TOK_KW_CALLCONV, NULL));
    CHECK(NextIs(&Lex, TOK_KW_CALLCONV, NULL));

    /* --- storage-class / inline tokens: all map to TOK_KW_STORAGE --- */
    Lexer_Init(&Lex, "extern static inline __forceinline");
    CHECK(NextIs(&Lex, TOK_KW_STORAGE, NULL));
    CHECK(NextIs(&Lex, TOK_KW_STORAGE, NULL));
    CHECK(NextIs(&Lex, TOK_KW_STORAGE, NULL));
    CHECK(NextIs(&Lex, TOK_KW_STORAGE, NULL));

    /* --- unknown character produces TOK_ERROR and Lexer_Next returns 0 --- */
    Lexer_Init(&Lex, "int @ float");
    CHECK(NextIs(&Lex, TOK_KW_INT, NULL));
    {
        int Ok = Lexer_Next(&Lex, &Tok);
        CHECK(!Ok);
        CHECK_EQ_INT(Tok.Type, TOK_ERROR);
    }

    TEST_END();
}
