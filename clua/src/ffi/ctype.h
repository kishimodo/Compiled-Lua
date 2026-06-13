/*!
 * @brief
 *  FFI ctype table. A per-VM hash mapping a C type name (or anonymous tag)
 *  to a CType_T record describing the type's kind, size, alignment, and
 *  (for compound types) field layout.
 */

#ifndef CLUA_FFI_CTYPE_H
#define CLUA_FFI_CTYPE_H

#include <stddef.h>
#include <stdint.h>

typedef enum {
    CT_VOID,
    CT_BOOL,
    CT_INT,
    CT_FLOAT,
    CT_PTR,
    CT_ARRAY,
    CT_STRUCT,
    CT_UNION,
    CT_ENUM,
    CT_FUNC,
    CT_FUNCPTR,
    CT_LIB
} CTYPE_KIND_T;

typedef struct _CType_T  CType_T,  *PCType_T;
typedef struct _Field_T  Field_T,  *PField_T;

struct _Field_T {
    char       Name[ 64 ];   /* "" for anonymous nested */
    PCType_T   Type;
    size_t     Offset;       /* bytes from struct/union base */
    PField_T   Next;
};

struct _CType_T {
    CTYPE_KIND_T   Kind;
    size_t         Size;
    size_t         Align;
    int            IsSigned;       /* CT_INT only */
    int            IsFlex;         /* CT_ARRAY: 1 if `T[?]` — size determined at ffi.new time */
    PCType_T       ElemType;       /* CT_PTR.target, CT_ARRAY.element, CT_FUNC.return */
    int            ArrayLen;       /* CT_ARRAY: N, or -1 for flex */
    PCType_T      *ParamTypes;     /* CT_FUNC / CT_FUNCPTR: arg types (heap-allocated array) */
    int            NumParams;
    int            HasVararg;
    PField_T       Fields;         /* CT_STRUCT / CT_UNION: linked list */
    int            NumFields;
    void          *NativeAddr;     /* CT_FUNC: resolved via GetProcAddress (set in 6d) */
    void          *NativeLib;      /* CT_FUNC: HMODULE the symbol came from (set in 6d) */
    PCType_T       PtrTo;          /* interned CT_PTR-to-this-type, lazily filled by Ctype_PointerTo */
};

void Ctype_Init( void );
void Ctype_Shutdown( void );
PCType_T Ctype_New( void );

/*!
 * @brief
 *  Return an interned CT_PTR type whose target is Elem, creating it once and
 *  caching it on Elem->PtrTo. Used for array->pointer decay (`arr + n`) and
 *  anywhere a pointer-to-T is needed without a named typedef. Bounded: at
 *  most one pointer type per distinct element type. Returns NULL on failure.
 */
PCType_T Ctype_PointerTo( PCType_T Elem );

int Ctype_Register( const char *Name, PCType_T Type );
PCType_T Ctype_Lookup( const char *Name );
void Ctype_AppendField( PCType_T Compound, const char *Name, PCType_T FieldType );

/*!
 * @brief
 *  Register an enum value constant. Stored in a separate name→int64 table
 *  that the FFI library (6d) mirrors into ffi.C.
 */
void Ctype_RegisterEnumConst( const char *Name, int64_t Value );

/*!
 * @brief
 *  Look up an enum constant by name. Returns 1 with *OutValue set on hit,
 *  0 if not found.
 */
int Ctype_LookupEnumConst( const char *Name, int64_t *OutValue );

/*!
 * @brief
 *  Register an extern/global symbol declared in cdef (`extern T name;`). Kept
 *  in a namespace separate from types so a global cannot shadow a type name.
 */
void Ctype_RegisterExtern( const char *Name, PCType_T Type );

/*!
 * @brief
 *  Look up an extern/global symbol's declared type by name. Returns the type
 *  on hit, NULL if not found. The FFI namespaces resolve the symbol's address
 *  (GetProcAddress) and marshal the value at that address on access.
 */
PCType_T Ctype_LookupExtern( const char *Name );

#endif /* CLUA_FFI_CTYPE_H */
