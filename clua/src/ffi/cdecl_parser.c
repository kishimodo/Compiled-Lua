/*!
 * @brief
 *  Recursive-descent parser for cdef strings.
 */

#include "ffi/cdecl_parser.h"
#include "ffi/cdecl_lexer.h"
#include "ffi/ctype.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char g_ErrorBuf[ 256 ] = { 0 };

/* Parser state. Single-pass; tokens are buffered one ahead for LL(1) lookahead. */
typedef struct {
    LEXER_T   Lex;
    TOKEN_T   Cur;
    TOKEN_T   Next;
} PARSER_T, *PPARSER_T;

static int Advance( PPARSER_T P ) {
    P->Cur = P->Next;
    if ( !Lexer_Next( &P->Lex, &P->Next ) ) {
        snprintf( g_ErrorBuf, sizeof( g_ErrorBuf ), "%s", P->Lex.ErrorMsg );
        return 0;
    }
    return 1;
}

static int ErrorAt( PPARSER_T P, const char *Msg ) {
    snprintf( g_ErrorBuf, sizeof( g_ErrorBuf ), "%s at line %d col %d",
              Msg, P->Cur.Line, P->Cur.Col );
    return 0;
}

static int Expect( PPARSER_T P, TOKEN_TYPE_T T, const char *What ) {
    if ( P->Cur.Type != T ) {
        char Msg[ 128 ];
        snprintf( Msg, sizeof( Msg ), "expected %s", What );
        return ErrorAt( P, Msg );
    }
    return Advance( P );
}

/* Bit flags for decl-specifier composition. */
#define DSF_SIGNED    0x01
#define DSF_UNSIGNED  0x02
#define DSF_SHORT     0x04
#define DSF_LONG      0x08
#define DSF_LONG_LONG 0x10

/* forward declarations — ParseStructOrUnion and ParseEnum call both of these */
static PCType_T ParseDeclSpec( PPARSER_T P );
static PCType_T ParseDeclarator( PPARSER_T P, PCType_T BaseType, char *OutName, size_t NameCap );
static PCType_T ParseEnum( PPARSER_T P );

/* Skip any contiguous run of calling-convention modifiers (__stdcall, __cdecl,
   __fastcall, WINAPI, CALLBACK, ...). We don't model multiple calling
   conventions in v1 — on Win64 they all collapse to the System V / Microsoft
   x64 ABI anyway. Returns 1 on success (no lex error while advancing). */
static int SkipCallConv( PPARSER_T P ) {
    while ( P->Cur.Type == TOK_KW_CALLCONV ) {
        if ( !Advance( P ) ) return 0;
    }
    return 1;
}

/* Parse a struct or union body: NAME? { FIELD-LIST } and register it.
   Returns the resulting compound CType_T, or NULL on error. The TagKw
   parameter is the keyword token type already consumed (TOK_KW_STRUCT or
   TOK_KW_UNION). */
static PCType_T ParseStructOrUnion( PPARSER_T P, TOKEN_TYPE_T TagKw ) {
    char TagName[ 64 ] = { 0 };
    if ( P->Cur.Type == TOK_IDENT ) {
        int Len = ( int )strlen( P->Cur.Text );
        if ( Len >= ( int )sizeof( TagName ) ) Len = ( int )sizeof( TagName ) - 1;
        memcpy( TagName, P->Cur.Text, ( size_t )Len );
        TagName[ Len ] = '\0';
        if ( !Advance( P ) ) return NULL;
    }

    /* if no body, this is a "struct NAME" reference (forward decl / use). */
    if ( P->Cur.Type != TOK_LBRACE ) {
        if ( TagName[ 0 ] == '\0' ) {
            ErrorAt( P, "expected '{' after anonymous struct/union" );
            return NULL;
        }
        PCType_T Existing = Ctype_Lookup( TagName );
        if ( Existing != NULL ) return Existing;
        /* forward-decl: register an empty struct/union of size 0 */
        PCType_T Fwd = Ctype_New( );
        if ( Fwd == NULL ) { ErrorAt( P, "out of memory" ); return NULL; }
        Fwd->Kind  = ( TagKw == TOK_KW_UNION ) ? CT_UNION : CT_STRUCT;
        Fwd->Align = 1;
        Ctype_Register( TagName, Fwd );
        return Fwd;
    }

    /* body: consume '{', parse field list, consume '}'. */
    if ( !Advance( P ) ) return NULL;  /* past { */

    PCType_T Compound = Ctype_New( );
    if ( Compound == NULL ) { ErrorAt( P, "out of memory" ); return NULL; }
    Compound->Kind  = ( TagKw == TOK_KW_UNION ) ? CT_UNION : CT_STRUCT;
    Compound->Align = 1;

    while ( P->Cur.Type != TOK_RBRACE ) {
        PCType_T FieldBase = ParseDeclSpec( P );
        if ( FieldBase == NULL ) return NULL;
        /* support comma-separated declarators: `WORD a, b, c;` -- common in
           Win32 header structs (PROPVARIANT padding fields, ...). Each
           declarator reuses FieldBase but gets its own pointer/array layers. */
        for ( ;; ) {
            char FieldName[ 64 ] = { 0 };
            PCType_T FieldType = ParseDeclarator( P, FieldBase, FieldName, sizeof( FieldName ) );
            if ( FieldType == NULL ) return NULL;
            Ctype_AppendField( Compound, FieldName, FieldType );
            if ( P->Cur.Type != TOK_COMMA ) break;
            if ( !Advance( P ) ) return NULL;  /* past , */
        }
        if ( !Expect( P, TOK_SEMI, ";" ) ) return NULL;
    }
    if ( !Advance( P ) ) return NULL;  /* past } */

    /* round Compound->Size up to its own alignment */
    if ( Compound->Align > 1 ) {
        Compound->Size = ( Compound->Size + Compound->Align - 1 ) & ~( Compound->Align - 1 );
    }

    if ( TagName[ 0 ] != '\0' ) {
        Ctype_Register( TagName, Compound );
        /* If this body completed a forward-decl stub, Ctype_Register filled the
           stub in place and the canonical type for the tag is that stub (which
           the typedef and earlier references alias). Return it so a direct
           `struct _X { ... } var;` use sees the fields too. */
        PCType_T Canonical = Ctype_Lookup( TagName );
        if ( Canonical != NULL ) return Canonical;
    }
    return Compound;
}

/* Parse "enum NAME? { CONST, CONST = VAL, ... }" or "enum NAME". */
static PCType_T ParseEnum( PPARSER_T P ) {
    char TagName[ 64 ] = { 0 };
    if ( P->Cur.Type == TOK_IDENT ) {
        int Len = ( int )strlen( P->Cur.Text );
        if ( Len >= ( int )sizeof( TagName ) ) Len = ( int )sizeof( TagName ) - 1;
        memcpy( TagName, P->Cur.Text, ( size_t )Len );
        TagName[ Len ] = '\0';
        if ( !Advance( P ) ) return NULL;
    }

    /* always returns int-sized regardless of values */
    PCType_T T = Ctype_New( );
    if ( T == NULL ) { ErrorAt( P, "out of memory" ); return NULL; }
    T->Kind     = CT_ENUM;
    T->Size     = 4;
    T->Align    = 4;
    T->IsSigned = 1;

    if ( P->Cur.Type != TOK_LBRACE ) {
        if ( TagName[ 0 ] == '\0' ) {
            ErrorAt( P, "expected '{' after anonymous enum" );
            return NULL;
        }
        PCType_T Existing = Ctype_Lookup( TagName );
        return ( Existing != NULL ) ? Existing : T;
    }

    if ( !Advance( P ) ) return NULL;  /* past { */
    int64_t Next = { 0 };
    while ( P->Cur.Type != TOK_RBRACE ) {
        if ( P->Cur.Type != TOK_IDENT ) {
            ErrorAt( P, "expected enum constant name" );
            return NULL;
        }
        char ConstName[ 64 ] = { 0 };
        int Len = ( int )strlen( P->Cur.Text );
        if ( Len >= ( int )sizeof( ConstName ) ) Len = ( int )sizeof( ConstName ) - 1;
        memcpy( ConstName, P->Cur.Text, ( size_t )Len );
        ConstName[ Len ] = '\0';
        if ( !Advance( P ) ) return NULL;
        if ( P->Cur.Type == TOK_EQ ) {
            if ( !Advance( P ) ) return NULL;
            /* optional sign: enums commonly use negative sentinels
               (e.g. cairo's CAIRO_FORMAT_INVALID = -1). */
            int Neg = 0;
            if ( P->Cur.Type == TOK_MINUS || P->Cur.Type == TOK_PLUS ) {
                Neg = ( P->Cur.Type == TOK_MINUS );
                if ( !Advance( P ) ) return NULL;
            }
            if ( P->Cur.Type != TOK_INT_LIT ) {
                ErrorAt( P, "expected integer literal after '='" );
                return NULL;
            }
            Next = Neg ? -( int64_t )P->Cur.IntValue : P->Cur.IntValue;
            if ( !Advance( P ) ) return NULL;
        }
        Ctype_RegisterEnumConst( ConstName, Next );
        Next++;
        if ( P->Cur.Type == TOK_COMMA ) {
            if ( !Advance( P ) ) return NULL;
        }
    }
    if ( !Advance( P ) ) return NULL;  /* past } */

    if ( TagName[ 0 ] != '\0' ) {
        Ctype_Register( TagName, T );
    }
    return T;
}

/* Parse declaration-specifiers (type keywords + signed/unsigned/short/long + CV).
   Returns the base ctype on success, NULL on error. */
static PCType_T ParseDeclSpec( PPARSER_T P ) {
    unsigned Flags    = 0;
    int      HasInt   = 0;
    int      HasChar  = 0;
    int      HasVoid  = 0;
    int      HasBool  = 0;
    int      HasFloat  = 0;
    int      HasDouble = 0;
    char     UserTypeName[ 64 ] = { 0 };

    for ( ;; ) {
        TOKEN_TYPE_T T = P->Cur.Type;
        if ( T == TOK_KW_STRUCT || T == TOK_KW_UNION ) {
            TOKEN_TYPE_T TagKw = T;
            if ( !Advance( P ) ) return NULL;
            return ParseStructOrUnion( P, TagKw );
        }
        if ( T == TOK_KW_ENUM ) {
            if ( !Advance( P ) ) return NULL;
            return ParseEnum( P );
        }
        if ( T == TOK_KW_CONST || T == TOK_KW_VOLATILE || T == TOK_KW_RESTRICT ) {
            if ( !Advance( P ) ) return NULL;
            continue;
        }
        if ( T == TOK_KW_CALLCONV ) {
            /* `__stdcall HRESULT Foo(...)` -- modifier may appear before the
               return type. Silently consume. */
            if ( !Advance( P ) ) return NULL;
            continue;
        }
        if ( T == TOK_KW_STORAGE ) {
            /* `extern`/`static`/`inline`/... carry no type info for FFI; skip.
               This lets DLL-exported globals (`extern T name;`) parse as plain
               declarations, which ParseTopLevel then tolerates. */
            if ( !Advance( P ) ) return NULL;
            continue;
        }
        if ( T == TOK_KW_SIGNED )   { Flags |= DSF_SIGNED;   if ( !Advance( P ) ) return NULL; continue; }
        if ( T == TOK_KW_UNSIGNED ) { Flags |= DSF_UNSIGNED; if ( !Advance( P ) ) return NULL; continue; }
        if ( T == TOK_KW_SHORT )    { Flags |= DSF_SHORT;    if ( !Advance( P ) ) return NULL; continue; }
        if ( T == TOK_KW_LONG ) {
            if ( Flags & DSF_LONG ) { Flags = ( Flags & ~DSF_LONG ) | DSF_LONG_LONG; }
            else                    { Flags |= DSF_LONG; }
            if ( !Advance( P ) ) return NULL;
            continue;
        }
        if ( T == TOK_KW_INT )    { HasInt = 1;    if ( !Advance( P ) ) return NULL; continue; }
        if ( T == TOK_KW_CHAR )   { HasChar = 1;   if ( !Advance( P ) ) return NULL; continue; }
        if ( T == TOK_KW_VOID )   { HasVoid = 1;   if ( !Advance( P ) ) return NULL; continue; }
        if ( T == TOK_KW_BOOL )   { HasBool = 1;   if ( !Advance( P ) ) return NULL; continue; }
        if ( T == TOK_KW_FLOAT )  { HasFloat = 1;  if ( !Advance( P ) ) return NULL; continue; }
        if ( T == TOK_KW_DOUBLE ) { HasDouble = 1; if ( !Advance( P ) ) return NULL; continue; }
        if ( T == TOK_IDENT ) {
            /* user-defined type name (only if we haven't seen primitive keywords) */
            if ( Flags == 0 && !HasInt && !HasChar && !HasVoid && !HasBool && !HasFloat && !HasDouble ) {
                /* token text is 128 bytes; UserTypeName is 64 — truncate safely */
                int Len = ( int )strlen( P->Cur.Text );
                if ( Len >= ( int )sizeof( UserTypeName ) ) Len = ( int )sizeof( UserTypeName ) - 1;
                memcpy( UserTypeName, P->Cur.Text, ( size_t )Len );
                UserTypeName[ Len ] = '\0';
                if ( !Advance( P ) ) return NULL;
                /* absorb east-side CV-qualifiers: `int64_t volatile head;`
                   (the queue package uses this). Primitive types already
                   handle these via the loop's `continue`; the user-type path
                   breaks out, so consume them here. */
                while ( P->Cur.Type == TOK_KW_CONST || P->Cur.Type == TOK_KW_VOLATILE ||
                        P->Cur.Type == TOK_KW_RESTRICT ) {
                    if ( !Advance( P ) ) return NULL;
                }
            }
            break;
        }
        break;
    }

    /* user-defined type wins */
    if ( UserTypeName[ 0 ] != '\0' ) {
        PCType_T UserT = Ctype_Lookup( UserTypeName );
        if ( UserT == NULL ) {
            char Msg[ 128 ];
            snprintf( Msg, sizeof( Msg ), "unknown type '%s'", UserTypeName );
            ErrorAt( P, Msg );
            return NULL;
        }
        return UserT;
    }

    /* compose primitive */
    if ( HasVoid )   return Ctype_Lookup( "void" );
    if ( HasBool )   return Ctype_Lookup( "_Bool" );
    if ( HasFloat )  return Ctype_Lookup( "float" );
    if ( HasDouble ) return Ctype_Lookup( "double" );

    if ( HasChar ) {
        if ( Flags & DSF_UNSIGNED ) return Ctype_Lookup( "unsigned char" );
        if ( Flags & DSF_SIGNED )   return Ctype_Lookup( "signed char" );
        return Ctype_Lookup( "char" );
    }

    /* integer composition: signed|unsigned + short|long|long-long + (int) */
    int IsUnsigned = ( Flags & DSF_UNSIGNED ) ? 1 : 0;

    if ( Flags & DSF_LONG_LONG ) {
        return Ctype_Lookup( IsUnsigned ? "unsigned long long" : "long long" );
    }
    if ( Flags & DSF_LONG ) {
        return Ctype_Lookup( IsUnsigned ? "unsigned long" : "long" );
    }
    if ( Flags & DSF_SHORT ) {
        return Ctype_Lookup( IsUnsigned ? "unsigned short" : "short" );
    }
    if ( HasInt || ( Flags & ( DSF_SIGNED | DSF_UNSIGNED ) ) ) {
        return Ctype_Lookup( IsUnsigned ? "unsigned int" : "int" );
    }

    ErrorAt( P, "expected type specifier" );
    return NULL;
}

/*!
 * @brief
 *  Parse the parameter list of a function declaration or definition.
 *  Expects the opening '(' to already be consumed.
 *  Writes NumParams and ParamTypes into FuncType on success.
 *
 * @param P
 *  parser state (current token is first token inside the '(')
 *
 * @param FuncType
 *  CT_FUNC ctype to populate with parameter info
 *
 * @return
 *  1 on success, 0 on error
 */
static int ParseParamList( PPARSER_T P, PCType_T FuncType ) {
    PCType_T  Params[ 32 ] = { 0 };
    int       Count        = 0;

    /* empty arg list "()" means zero params */
    if ( P->Cur.Type == TOK_RPAREN ) {
        if ( !Advance( P ) ) return 0;
        FuncType->NumParams  = 0;
        FuncType->ParamTypes = NULL;
        return 1;
    }
    /* "(void)" sentinel — one void declspec with no declarator */
    if ( P->Cur.Type == TOK_KW_VOID && P->Next.Type == TOK_RPAREN ) {
        if ( !Advance( P ) ) return 0;  /* past void */
        if ( !Advance( P ) ) return 0;  /* past ) */
        FuncType->NumParams  = 0;
        FuncType->ParamTypes = NULL;
        return 1;
    }

    for ( ;; ) {
        /* "..." at param-list start would be K&R-style variadic with no fixed
           args; C requires at least one fixed arg before ',' '...'. Reject
           cleanly rather than silently misparsing. */
        if ( P->Cur.Type == TOK_ELLIPSIS ) {
            ErrorAt( P, "'...' requires at least one fixed parameter before it" );
            return 0;
        }
        /* tolerate `__stdcall` / `WINAPI` modifiers in parameter position
           (rare but allowed by SDK headers) */
        if ( !SkipCallConv( P ) ) return 0;
        PCType_T Base = ParseDeclSpec( P );
        if ( Base == NULL ) return 0;
        char     ParamName[ 64 ] = { 0 };
        PCType_T Pt = Base;
        /* leading * chain */
        while ( P->Cur.Type == TOK_STAR ) {
            if ( !Advance( P ) ) return 0;
            while ( P->Cur.Type == TOK_KW_CONST || P->Cur.Type == TOK_KW_VOLATILE || P->Cur.Type == TOK_KW_RESTRICT ) {
                if ( !Advance( P ) ) return 0;
            }
            PCType_T NewPtr = Ctype_New( );
            if ( NewPtr == NULL ) { ErrorAt( P, "out of memory" ); return 0; }
            NewPtr->Kind     = CT_PTR;
            NewPtr->Size     = 8;
            NewPtr->Align    = 8;
            NewPtr->ElemType = Pt;
            Pt = NewPtr;
        }
        /* function-pointer parameter: ( [callconv] * [name] ) ( inner-params )
           e.g. sqlite3_exec's `int (*callback)(void*,int,char**,char**)`. The
           inner name is optional in parameter position (unlike ParseDeclarator,
           which requires one). The current Pt (base + leading *s) is the
           function's return type. */
        if ( P->Cur.Type == TOK_LPAREN &&
             ( P->Next.Type == TOK_STAR || P->Next.Type == TOK_KW_CALLCONV ) ) {
            if ( !Advance( P ) ) return 0;                 /* past ( */
            while ( P->Cur.Type == TOK_KW_CALLCONV ) {     /* (__stdcall *name) */
                if ( !Advance( P ) ) return 0;
            }
            if ( P->Cur.Type != TOK_STAR ) {
                ErrorAt( P, "expected '*' in function-pointer parameter" );
                return 0;
            }
            while ( P->Cur.Type == TOK_STAR ) {
                if ( !Advance( P ) ) return 0;
                while ( P->Cur.Type == TOK_KW_CONST || P->Cur.Type == TOK_KW_VOLATILE ||
                        P->Cur.Type == TOK_KW_RESTRICT ) {
                    if ( !Advance( P ) ) return 0;
                }
            }
            if ( P->Cur.Type == TOK_IDENT ) {              /* optional name */
                strncpy( ParamName, P->Cur.Text, sizeof( ParamName ) - 1 );
                if ( !Advance( P ) ) return 0;
            }
            if ( !Expect( P, TOK_RPAREN, ")" ) ) return 0;
            if ( !Expect( P, TOK_LPAREN, "(" ) ) return 0; /* inner param list */
            PCType_T Fn = Ctype_New( );
            if ( Fn == NULL ) { ErrorAt( P, "out of memory" ); return 0; }
            Fn->Kind     = CT_FUNC;
            Fn->ElemType = Pt;                             /* return type */
            if ( !ParseParamList( P, Fn ) ) return 0;
            PCType_T FnPtr = Ctype_New( );
            if ( FnPtr == NULL ) { ErrorAt( P, "out of memory" ); return 0; }
            FnPtr->Kind       = CT_FUNCPTR;
            FnPtr->Size       = 8;
            FnPtr->Align      = 8;
            FnPtr->ElemType   = Pt;
            FnPtr->ParamTypes = Fn->ParamTypes;
            FnPtr->NumParams  = Fn->NumParams;
            Fn->ParamTypes = NULL;  /* transfer ownership to FnPtr */
            Fn->NumParams  = 0;
            Pt = FnPtr;
            /* the name (if any) and inner list are fully consumed; fall through
               to param-append. The name/array steps below no-op (next token is
               ',' or ')'). */
        }
        /* optional param name */
        if ( P->Cur.Type == TOK_IDENT ) {
            strncpy( ParamName, P->Cur.Text, sizeof( ParamName ) - 1 );
            if ( !Advance( P ) ) return 0;
        }
        /* arrays in param position decay to pointer */
        while ( P->Cur.Type == TOK_LBRACKET ) {
            if ( !Advance( P ) ) return 0;
            if ( P->Cur.Type == TOK_INT_LIT ) {
                if ( !Advance( P ) ) return 0;
            }
            if ( !Expect( P, TOK_RBRACKET, "]" ) ) return 0;
            PCType_T Decayed = Ctype_New( );
            if ( Decayed == NULL ) { ErrorAt( P, "out of memory" ); return 0; }
            Decayed->Kind     = CT_PTR;
            Decayed->Size     = 8;
            Decayed->Align    = 8;
            Decayed->ElemType = Pt;
            Pt = Decayed;
        }
        if ( Count >= 32 ) {
            ErrorAt( P, "too many parameters (max 32)" );
            return 0;
        }
        Params[ Count++ ] = Pt;
        if ( P->Cur.Type == TOK_COMMA ) {
            if ( !Advance( P ) ) return 0;
            /* trailing "..." marks function as variadic; no more params allowed */
            if ( P->Cur.Type == TOK_ELLIPSIS ) {
                if ( !Advance( P ) ) return 0;
                FuncType->HasVararg = 1;
                if ( P->Cur.Type != TOK_RPAREN ) {
                    ErrorAt( P, "expected ')' after '...'" );
                    return 0;
                }
                break;
            }
            continue;
        }
        break;
    }
    if ( !Expect( P, TOK_RPAREN, ")" ) ) return 0;

    FuncType->ParamTypes = ( PCType_T * )calloc( ( size_t )Count, sizeof( PCType_T ) );
    if ( FuncType->ParamTypes == NULL ) return 0;
    int K = { 0 };
    for ( K = 0; K < Count; K++ ) FuncType->ParamTypes[ K ] = Params[ K ];
    FuncType->NumParams = Count;
    return 1;
}

/*!
 * @brief
 *  Wrap BaseType in pointer/array layers as the declarator dictates.
 *  Writes the declarator's name to OutName (buffer of size NameCap).
 *  Returns the adjusted ctype, or NULL on error.
 *
 * @param P
 *  parser state (current token is the start of the declarator)
 *
 * @param BaseType
 *  the already-parsed decl-specifier type
 *
 * @param OutName
 *  receives the identifier name (NUL-terminated, truncated to NameCap-1)
 *
 * @param NameCap
 *  byte capacity of OutName including the NUL terminator
 *
/*!
 * @brief
 *  Parse a run of consecutive array suffixes (`[N]`, `[?]`, `[]`) and wrap
 *  ElemBase so the FIRST bracket is the OUTERMOST dimension -- C semantics:
 *  `int a[2][3]` is array-2-of-(array-3-of-int), laid out row-major. Building
 *  the wrappers left-to-right (innermost-first) reverses the nesting, which
 *  swaps the strides and makes a[i][j] alias the wrong element. Returns the
 *  nested array type, ElemBase unchanged if there were no `[`, or NULL on error.
 */
#define CDECL_MAX_ARRAY_DIMS 16
static PCType_T ParseArraySuffixes( PPARSER_T P, PCType_T ElemBase ) {
    int Dims[ CDECL_MAX_ARRAY_DIMS ];
    int Flex[ CDECL_MAX_ARRAY_DIMS ];
    int NDims = 0;
    while ( P->Cur.Type == TOK_LBRACKET ) {
        if ( NDims >= CDECL_MAX_ARRAY_DIMS ) {
            ErrorAt( P, "too many array dimensions" );
            return NULL;
        }
        if ( !Advance( P ) ) return NULL;
        int Len = -1, IsFlex = 0;
        if ( P->Cur.Type == TOK_QUESTION ) {
            IsFlex = 1;
            if ( !Advance( P ) ) return NULL;
        } else if ( P->Cur.Type == TOK_INT_LIT ) {
            Len = ( int )P->Cur.IntValue;
            if ( !Advance( P ) ) return NULL;
        }
        if ( !Expect( P, TOK_RBRACKET, "]" ) ) return NULL;
        Dims[ NDims ] = Len;
        Flex[ NDims ] = IsFlex;
        NDims++;
    }
    /* Wrap innermost (last) dimension first so the first bracket ends up
       outermost. */
    PCType_T Cur = ElemBase;
    for ( int D = NDims - 1; D >= 0; D-- ) {
        PCType_T Arr = Ctype_New( );
        if ( Arr == NULL ) { ErrorAt( P, "out of memory" ); return NULL; }
        Arr->Kind     = CT_ARRAY;
        Arr->ElemType = Cur;
        Arr->ArrayLen = Dims[ D ];
        Arr->IsFlex   = Flex[ D ];
        Arr->Align    = Cur->Align;
        Arr->Size     = ( Dims[ D ] < 0 ) ? 0 : ( size_t )Dims[ D ] * Cur->Size;
        Cur = Arr;
    }
    return Cur;
}

/*!
 * @return
 *  adjusted CType_T (with pointer/array wrappers), or NULL on error
 */
static PCType_T ParseDeclarator( PPARSER_T P, PCType_T BaseType, char *OutName, size_t NameCap ) {
    /* `RET __stdcall name(...)` -- modifier between return type and name */
    if ( !SkipCallConv( P ) ) return NULL;
    /* leading pointer chain: T *... */
    PCType_T Cur = BaseType;
    while ( P->Cur.Type == TOK_STAR ) {
        if ( !Advance( P ) ) return NULL;
        /* skip CV qualifiers after star */
        while ( P->Cur.Type == TOK_KW_CONST || P->Cur.Type == TOK_KW_VOLATILE || P->Cur.Type == TOK_KW_RESTRICT ) {
            if ( !Advance( P ) ) return NULL;
        }
        PCType_T Ptr = Ctype_New( );
        if ( Ptr == NULL ) { ErrorAt( P, "out of memory" ); return NULL; }
        Ptr->Kind     = CT_PTR;
        Ptr->Size     = 8;
        Ptr->Align    = 8;
        Ptr->ElemType = Cur;
        Cur = Ptr;
    }

    /* parenthesised inner declarator: e.g. `(*name)` or `(__stdcall *name)`
       for function pointers. The lookahead allows TOK_STAR directly after
       LPAREN, or a calling-convention modifier (winmd-gen emits
       `HRESULT (__stdcall *Foo)(...)` for every COM vtable slot). */
    if ( P->Cur.Type == TOK_LPAREN &&
         ( P->Next.Type == TOK_STAR || P->Next.Type == TOK_KW_CALLCONV ) ) {
        if ( !Advance( P ) ) return NULL;  /* past ( */
        if ( !SkipCallConv( P ) ) return NULL;
        PCType_T Inner = Cur;
        while ( P->Cur.Type == TOK_STAR ) {
            if ( !Advance( P ) ) return NULL;
            while ( P->Cur.Type == TOK_KW_CONST || P->Cur.Type == TOK_KW_VOLATILE || P->Cur.Type == TOK_KW_RESTRICT ) {
                if ( !Advance( P ) ) return NULL;
            }
        }
        if ( P->Cur.Type != TOK_IDENT ) {
            ErrorAt( P, "expected name in parenthesised declarator" );
            return NULL;
        }
        strncpy( OutName, P->Cur.Text, NameCap - 1 );
        OutName[ NameCap - 1 ] = '\0';
        if ( !Advance( P ) ) return NULL;
        if ( !Expect( P, TOK_RPAREN, ")" ) ) return NULL;
        if ( P->Cur.Type != TOK_LPAREN ) {
            ErrorAt( P, "expected function parameter list after (*name)" );
            return NULL;
        }
        if ( !Advance( P ) ) return NULL;  /* past ( */
        /* use a temporary CT_FUNC to collect param list, then build the fnptr */
        PCType_T Fn = Ctype_New( );
        if ( Fn == NULL ) { ErrorAt( P, "out of memory" ); return NULL; }
        Fn->Kind     = CT_FUNC;
        Fn->ElemType = Inner;
        if ( !ParseParamList( P, Fn ) ) return NULL;
        PCType_T FnPtr = Ctype_New( );
        if ( FnPtr == NULL ) { ErrorAt( P, "out of memory" ); return NULL; }
        FnPtr->Kind       = CT_FUNCPTR;
        FnPtr->Size       = 8;
        FnPtr->Align      = 8;
        /* ElemType = return type (Inner), mirrors CT_PTR convention for introspection */
        FnPtr->ElemType   = Inner;
        FnPtr->ParamTypes = Fn->ParamTypes;
        FnPtr->NumParams  = Fn->NumParams;
        /* transfer ownership of ParamTypes to FnPtr — prevent double-free on shutdown */
        Fn->ParamTypes = NULL;
        Fn->NumParams  = 0;
        return FnPtr;
    }

    /* identifier (optional for anonymous nested struct/union fields) */
    if ( P->Cur.Type != TOK_IDENT ) {
        if ( ( BaseType->Kind == CT_STRUCT || BaseType->Kind == CT_UNION ) &&
             P->Cur.Type == TOK_SEMI ) {
            OutName[ 0 ] = '\0';
            return Cur;
        }
        ErrorAt( P, "expected declarator identifier" );
        return NULL;
    }
    {
        /* token text is 128 bytes; OutName capacity may differ — truncate safely */
        int Len = ( int )strlen( P->Cur.Text );
        if ( Len >= ( int )NameCap ) Len = ( int )NameCap - 1;
        memcpy( OutName, P->Cur.Text, ( size_t )Len );
        OutName[ Len ] = '\0';
    }
    if ( !Advance( P ) ) return NULL;

    /* trailing suffixes: array `[N]...` or function `( PARAM-LIST )` */
    while ( P->Cur.Type == TOK_LBRACKET || P->Cur.Type == TOK_LPAREN ) {
        if ( P->Cur.Type == TOK_LBRACKET ) {
            /* Consume the whole run of dimensions at once so multi-dim arrays
               nest first-bracket-outermost (see ParseArraySuffixes). */
            Cur = ParseArraySuffixes( P, Cur );
            if ( Cur == NULL ) return NULL;
        } else {
            /* function declaration tail: build a CT_FUNC wrapping Cur as return type */
            if ( !Advance( P ) ) return NULL;  /* past ( */
            PCType_T Fn = Ctype_New( );
            if ( Fn == NULL ) { ErrorAt( P, "out of memory" ); return NULL; }
            Fn->Kind     = CT_FUNC;
            Fn->ElemType = Cur;
            if ( !ParseParamList( P, Fn ) ) return NULL;
            Cur = Fn;
        }
    }
    return Cur;
}

/* Parse a top-level declaration. Returns 1 on success, 0 on error. */
static int ParseTopLevel( PPARSER_T P ) {
    int IsTypedef = 0;
    if ( P->Cur.Type == TOK_KW_TYPEDEF ) {
        IsTypedef = 1;
        if ( !Advance( P ) ) return 0;
    }

    PCType_T Base = ParseDeclSpec( P );
    if ( Base == NULL ) return 0;

    /* if Base is a freshly-registered struct/union with no declarator, just consume
       the semicolon and return — but only for non-typedef declarations. */
    if ( P->Cur.Type == TOK_SEMI && !IsTypedef ) {
        if ( !Advance( P ) ) return 0;
        return 1;
    }

    /* Comma-separated declarators share one decl-specifier:
         typedef int A, B;
         int x, y;
       Each declarator gets registered independently. */
    for ( ;; ) {
        char DeclName[ 64 ] = { 0 };
        PCType_T Adjusted = ParseDeclarator( P, Base, DeclName, sizeof( DeclName ) );
        if ( Adjusted == NULL ) return 0;

        if ( IsTypedef ) {
            if ( !Ctype_Register( DeclName, Adjusted ) ) {
                char Msg[ 128 ];
                snprintf( Msg, sizeof( Msg ), "redefinition mismatch for '%s'", DeclName );
                return ErrorAt( P, Msg );
            }
        } else if ( Adjusted->Kind == CT_FUNC ) {
            /* function declaration: register by name so ffi.load / ffi.C can resolve */
            if ( !Ctype_Register( DeclName, Adjusted ) ) {
                char Msg[ 128 ];
                snprintf( Msg, sizeof( Msg ), "redefinition mismatch for '%s'", DeclName );
                return ErrorAt( P, Msg );
            }
        } else if ( DeclName[ 0 ] != '\0' ) {
            /* extern/global variable declaration (`extern T name;`): register so
               the ffi.load / ffi.C namespaces can resolve it by GetProcAddress
               and marshal the value -- e.g. oniguruma's OnigEncodingUTF8. */
            Ctype_RegisterExtern( DeclName, Adjusted );
        }

        if ( P->Cur.Type != TOK_COMMA ) break;
        if ( !Advance( P ) ) return 0;  /* past , */
    }
    if ( !Expect( P, TOK_SEMI, ";" ) ) return 0;
    return 1;
}

int Cdecl_Parse( const char *Source ) {
    PARSER_T P = { 0 };
    Lexer_Init( &P.Lex, Source );
    if ( !Lexer_Next( &P.Lex, &P.Next ) ) {
        snprintf( g_ErrorBuf, sizeof( g_ErrorBuf ), "%s", P.Lex.ErrorMsg );
        return 0;
    }
    if ( !Advance( &P ) ) return 0;

    while ( P.Cur.Type != TOK_EOF ) {
        if ( !ParseTopLevel( &P ) ) return 0;
    }
    return 1;
}

const char *Cdecl_LastError( void ) {
    return g_ErrorBuf;
}

PCType_T Cdecl_ParseTypeExpr( const char *Source ) {
    PARSER_T P = { 0 };
    Lexer_Init( &P.Lex, Source );
    if ( !Lexer_Next( &P.Lex, &P.Next ) ) {
        snprintf( g_ErrorBuf, sizeof( g_ErrorBuf ), "%s", P.Lex.ErrorMsg );
        return NULL;
    }
    if ( !Advance( &P ) ) return NULL;

    PCType_T Base = ParseDeclSpec( &P );
    if ( Base == NULL ) return NULL;

    /* leading pointer chain */
    PCType_T Cur = Base;
    while ( P.Cur.Type == TOK_STAR ) {
        if ( !Advance( &P ) ) return NULL;
        while ( P.Cur.Type == TOK_KW_CONST || P.Cur.Type == TOK_KW_VOLATILE || P.Cur.Type == TOK_KW_RESTRICT ) {
            if ( !Advance( &P ) ) return NULL;
        }
        PCType_T Ptr = Ctype_New( );
        if ( Ptr == NULL ) { ErrorAt( &P, "out of memory" ); return NULL; }
        Ptr->Kind = CT_PTR;
        Ptr->Size = 8;
        Ptr->Align = 8;
        Ptr->ElemType = Cur;
        Cur = Ptr;
    }

    /* function-pointer type expression: ( [callconv] * [name] ) ( params )
       e.g. ffi.cast("void (*)(void *)", ...). The declarator is abstract (no
       name) in a type expression. Cur (base + leading *s) is the return type. */
    if ( P.Cur.Type == TOK_LPAREN &&
         ( P.Next.Type == TOK_STAR || P.Next.Type == TOK_KW_CALLCONV ) ) {
        if ( !Advance( &P ) ) return NULL;               /* past ( */
        while ( P.Cur.Type == TOK_KW_CALLCONV ) {
            if ( !Advance( &P ) ) return NULL;
        }
        if ( P.Cur.Type != TOK_STAR ) {
            ErrorAt( &P, "expected '*' in function-pointer type" );
            return NULL;
        }
        while ( P.Cur.Type == TOK_STAR ) {
            if ( !Advance( &P ) ) return NULL;
            while ( P.Cur.Type == TOK_KW_CONST || P.Cur.Type == TOK_KW_VOLATILE ||
                    P.Cur.Type == TOK_KW_RESTRICT ) {
                if ( !Advance( &P ) ) return NULL;
            }
        }
        if ( P.Cur.Type == TOK_IDENT ) {                 /* optional name, ignored */
            if ( !Advance( &P ) ) return NULL;
        }
        if ( !Expect( &P, TOK_RPAREN, ")" ) ) return NULL;
        if ( !Expect( &P, TOK_LPAREN, "(" ) ) return NULL;
        PCType_T Fn = Ctype_New( );
        if ( Fn == NULL ) { ErrorAt( &P, "out of memory" ); return NULL; }
        Fn->Kind     = CT_FUNC;
        Fn->ElemType = Cur;
        if ( !ParseParamList( &P, Fn ) ) return NULL;
        PCType_T FnPtr = Ctype_New( );
        if ( FnPtr == NULL ) { ErrorAt( &P, "out of memory" ); return NULL; }
        FnPtr->Kind       = CT_FUNCPTR;
        FnPtr->Size       = 8;
        FnPtr->Align      = 8;
        FnPtr->ElemType   = Cur;
        FnPtr->ParamTypes = Fn->ParamTypes;
        FnPtr->NumParams  = Fn->NumParams;
        Fn->ParamTypes = NULL;  /* transfer ownership to FnPtr */
        Fn->NumParams  = 0;
        Cur = FnPtr;
    }

    /* trailing array suffixes (first bracket outermost; see ParseArraySuffixes) */
    if ( P.Cur.Type == TOK_LBRACKET ) {
        Cur = ParseArraySuffixes( &P, Cur );
        if ( Cur == NULL ) return NULL;
    }

    if ( P.Cur.Type != TOK_EOF ) {
        ErrorAt( &P, "unexpected token in type expression" );
        return NULL;
    }
    return Cur;
}
