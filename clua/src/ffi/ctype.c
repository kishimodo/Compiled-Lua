/*!
 * @brief
 *  Global ctype table implementation + primitive type registration.
 */

#include "ffi/ctype.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Sized to hold the full cimgui surface comfortably: ~1300 fn typedefs
   + ~200 struct forward decls + ~85 enum int typedefs + primitives. */
#define CTYPE_TABLE_MAX 4096
#define ENUM_TABLE_MAX  8192

typedef struct {
    char       Name[ 64 ];
    PCType_T   Type;
    int        InUse;
} CTYPE_SLOT_T, *PCTYPE_SLOT_T;

typedef struct {
    char     Name[ 64 ];
    int64_t  Value;
    int      InUse;
} ENUM_SLOT_T;

static CTYPE_SLOT_T  g_Slots[ CTYPE_TABLE_MAX ];
static ENUM_SLOT_T   g_Enums[ ENUM_TABLE_MAX ];
/* Extern/global symbols declared in cdef (`extern T name;`). Kept in their own
   namespace -- NOT the type table -- so a global never shadows a type name. The
   FFI namespaces resolve these by GetProcAddress + marshal of the value. */
static CTYPE_SLOT_T  g_Externs[ CTYPE_TABLE_MAX ];
static int           g_Initialised = { 0 };

static PCType_T      g_AllTypes[ CTYPE_TABLE_MAX * 2 ];
static int           g_NumAllTypes = { 0 };

static unsigned HashName( const char *Name ) {
    unsigned H = { 5381 };
    while ( *Name ) {
        H = ( ( H << 5 ) + H ) + ( unsigned char )*Name;
        Name++;
    }
    return H;
}

PCType_T Ctype_New( void ) {
    /* refuse before allocating — untracked allocs would leak on Shutdown */
    if ( g_NumAllTypes >= ( int )( sizeof( g_AllTypes ) / sizeof( g_AllTypes[ 0 ] ) ) ) {
        return NULL;
    }
    PCType_T T = ( PCType_T )calloc( 1, sizeof( CType_T ) );
    if ( T == NULL ) return NULL;
    g_AllTypes[ g_NumAllTypes++ ] = T;
    return T;
}

PCType_T Ctype_PointerTo( PCType_T Elem ) {
    if ( Elem == NULL ) return NULL;
    if ( Elem->PtrTo != NULL ) return Elem->PtrTo;  /* interned hit */
    PCType_T P = Ctype_New( );
    if ( P == NULL ) return NULL;
    P->Kind     = CT_PTR;
    P->Size     = sizeof( void * );
    P->Align    = sizeof( void * );
    P->ElemType = Elem;
    Elem->PtrTo = P;
    return P;
}

int Ctype_Register( const char *Name, PCType_T Type ) {
    if ( Name == NULL || Type == NULL ) return 0;
    unsigned H = HashName( Name );
    int Start = ( int )( H % CTYPE_TABLE_MAX );
    int I = { 0 };
    for ( I = 0; I < CTYPE_TABLE_MAX; I++ ) {
        int Idx = ( Start + I ) % CTYPE_TABLE_MAX;
        if ( !g_Slots[ Idx ].InUse ) {
            strncpy( g_Slots[ Idx ].Name, Name, sizeof( g_Slots[ Idx ].Name ) - 1 );
            g_Slots[ Idx ].Name[ sizeof( g_Slots[ Idx ].Name ) - 1 ] = '\0';
            g_Slots[ Idx ].Type = Type;
            g_Slots[ Idx ].InUse = 1;
            return 1;
        }
        if ( strcmp( g_Slots[ Idx ].Name, Name ) == 0 ) {
            PCType_T Existing = g_Slots[ Idx ].Type;
            if ( Existing == Type ) return 1;
            /* Complete a forward-decl stub (size=0, no fields, struct/union) by
               filling the EXISTING object in place, not by repointing the slot
               to the new one. A `typedef struct _X X;` makes X alias the stub
               object; so do earlier `struct _X` references and self-referential
               fields (`struct _X *next`). Repointing the slot left all of those
               resolving to the still-empty stub, so sizeof(X) stayed 0 while
               sizeof(struct _X) was correct. Mutating the stub makes every alias
               observe the real layout. */
            if ( Existing->Kind == Type->Kind &&
                 Existing->Size == 0 && Existing->Fields == NULL &&
                 Type->Size > 0 ) {
                Existing->Size      = Type->Size;
                Existing->Align     = Type->Align;
                Existing->Fields    = Type->Fields;
                Existing->NumFields = Type->NumFields;
                /* The new wrapper handed its field list to the stub; clear it so
                   Ctype_Shutdown doesn't free the same list twice. */
                Type->Fields    = NULL;
                Type->NumFields = 0;
                return 1;
            }
            if ( Existing->Kind == Type->Kind &&
                 Existing->Size == Type->Size &&
                 Existing->Align == Type->Align ) {
                return 1;  /* compatible re-registration */
            }
            return 0;  /* incompatible */
        }
    }
    return 0;  /* table full */
}

PCType_T Ctype_Lookup( const char *Name ) {
    if ( Name == NULL ) return NULL;
    unsigned H = HashName( Name );
    int Start = ( int )( H % CTYPE_TABLE_MAX );
    int I = { 0 };
    for ( I = 0; I < CTYPE_TABLE_MAX; I++ ) {
        int Idx = ( Start + I ) % CTYPE_TABLE_MAX;
        if ( !g_Slots[ Idx ].InUse ) return NULL;
        if ( strcmp( g_Slots[ Idx ].Name, Name ) == 0 ) {
            return g_Slots[ Idx ].Type;
        }
    }
    return NULL;
}

void Ctype_AppendField( PCType_T Compound, const char *Name, PCType_T FieldType ) {
    if ( Compound == NULL || FieldType == NULL ) return;

    /* anonymous nested struct/union: promote its fields into Compound at a shared
       offset, instead of adding a single composite field. */
    int IsAnonNested =
        ( ( Name == NULL || Name[ 0 ] == '\0' ) &&
          ( FieldType->Kind == CT_STRUCT || FieldType->Kind == CT_UNION ) );

    if ( IsAnonNested ) {
        /* compute the placement offset for the nested compound itself */
        size_t BaseOff = 0;
        if ( Compound->Kind == CT_STRUCT ) {
            BaseOff = ( Compound->Size + FieldType->Align - 1 ) & ~( FieldType->Align - 1 );
        }
        PField_T Sub = FieldType->Fields;
        while ( Sub != NULL ) {
            PField_T NewF = ( PField_T )calloc( 1, sizeof( Field_T ) );
            if ( NewF == NULL ) return;
            memcpy( NewF->Name, Sub->Name, sizeof( NewF->Name ) - 1 );
            NewF->Name[ sizeof( NewF->Name ) - 1 ] = '\0';
            NewF->Type = Sub->Type;
            NewF->Offset = BaseOff + Sub->Offset;
            if ( Compound->Fields == NULL ) {
                Compound->Fields = NewF;
            } else {
                PField_T Tail = Compound->Fields;
                while ( Tail->Next != NULL ) Tail = Tail->Next;
                Tail->Next = NewF;
            }
            Compound->NumFields++;
            Sub = Sub->Next;
        }
        if ( Compound->Kind == CT_STRUCT ) {
            Compound->Size = BaseOff + FieldType->Size;
        } else {
            if ( FieldType->Size > Compound->Size ) Compound->Size = FieldType->Size;
        }
        if ( FieldType->Align > Compound->Align ) Compound->Align = FieldType->Align;
        return;
    }

    PField_T F = ( PField_T )calloc( 1, sizeof( Field_T ) );
    if ( F == NULL ) return;
    if ( Name != NULL ) {
        strncpy( F->Name, Name, sizeof( F->Name ) - 1 );
    }
    F->Type = FieldType;

    if ( Compound->Kind == CT_STRUCT ) {
        size_t Off = ( Compound->Size + FieldType->Align - 1 ) & ~( FieldType->Align - 1 );
        F->Offset = Off;
        Compound->Size = Off + FieldType->Size;
        if ( FieldType->Align > Compound->Align ) {
            Compound->Align = FieldType->Align;
        }
    } else if ( Compound->Kind == CT_UNION ) {
        F->Offset = 0;
        if ( FieldType->Size > Compound->Size ) Compound->Size = FieldType->Size;
        if ( FieldType->Align > Compound->Align ) Compound->Align = FieldType->Align;
    }

    if ( Compound->Fields == NULL ) {
        Compound->Fields = F;
    } else {
        PField_T Tail = Compound->Fields;
        while ( Tail->Next != NULL ) Tail = Tail->Next;
        Tail->Next = F;
    }
    Compound->NumFields++;
}

void Ctype_RegisterEnumConst( const char *Name, int64_t Value ) {
    if ( Name == NULL ) return;
    unsigned H     = HashName( Name );
    int      Start = ( int )( H % ENUM_TABLE_MAX );
    int      I     = { 0 };
    for ( I = 0; I < ENUM_TABLE_MAX; I++ ) {
        int Idx = ( Start + I ) % ENUM_TABLE_MAX;
        if ( !g_Enums[ Idx ].InUse ||
             strcmp( g_Enums[ Idx ].Name, Name ) == 0 ) {
            strncpy( g_Enums[ Idx ].Name, Name, sizeof( g_Enums[ Idx ].Name ) - 1 );
            g_Enums[ Idx ].Name[ sizeof( g_Enums[ Idx ].Name ) - 1 ] = '\0';
            g_Enums[ Idx ].Value = Value;
            g_Enums[ Idx ].InUse = 1;
            return;
        }
    }
}

int Ctype_LookupEnumConst( const char *Name, int64_t *OutValue ) {
    if ( Name == NULL ) return 0;
    unsigned H     = HashName( Name );
    int      Start = ( int )( H % ENUM_TABLE_MAX );
    int      I     = { 0 };
    for ( I = 0; I < ENUM_TABLE_MAX; I++ ) {
        int Idx = ( Start + I ) % ENUM_TABLE_MAX;
        if ( !g_Enums[ Idx ].InUse ) return 0;
        if ( strcmp( g_Enums[ Idx ].Name, Name ) == 0 ) {
            if ( OutValue != NULL ) *OutValue = g_Enums[ Idx ].Value;
            return 1;
        }
    }
    return 0;
}

void Ctype_RegisterExtern( const char *Name, PCType_T Type ) {
    if ( Name == NULL || Type == NULL ) return;
    unsigned H     = HashName( Name );
    int      Start = ( int )( H % CTYPE_TABLE_MAX );
    int      I     = { 0 };
    for ( I = 0; I < CTYPE_TABLE_MAX; I++ ) {
        int Idx = ( Start + I ) % CTYPE_TABLE_MAX;
        if ( !g_Externs[ Idx ].InUse ||
             strcmp( g_Externs[ Idx ].Name, Name ) == 0 ) {
            strncpy( g_Externs[ Idx ].Name, Name, sizeof( g_Externs[ Idx ].Name ) - 1 );
            g_Externs[ Idx ].Name[ sizeof( g_Externs[ Idx ].Name ) - 1 ] = '\0';
            g_Externs[ Idx ].Type  = Type;
            g_Externs[ Idx ].InUse = 1;
            return;
        }
    }
}

PCType_T Ctype_LookupExtern( const char *Name ) {
    if ( Name == NULL ) return NULL;
    unsigned H     = HashName( Name );
    int      Start = ( int )( H % CTYPE_TABLE_MAX );
    int      I     = { 0 };
    for ( I = 0; I < CTYPE_TABLE_MAX; I++ ) {
        int Idx = ( Start + I ) % CTYPE_TABLE_MAX;
        if ( !g_Externs[ Idx ].InUse ) return NULL;
        if ( strcmp( g_Externs[ Idx ].Name, Name ) == 0 ) {
            return g_Externs[ Idx ].Type;
        }
    }
    return NULL;
}

static void RegisterIntPrim( const char *Name, size_t Size, int Signed ) {
    PCType_T T = Ctype_New( );
    if ( T == NULL ) return;
    T->Kind = CT_INT;
    T->Size = Size;
    T->Align = Size;     /* primitive integers: align = size on x64 */
    T->IsSigned = Signed;
    Ctype_Register( Name, T );
}

static void RegisterPrimitives( void ) {
    PCType_T V = Ctype_New( );
    if ( V == NULL ) return;
    V->Kind = CT_VOID;
    V->Size = 0;
    V->Align = 1;
    Ctype_Register( "void", V );

    PCType_T B = Ctype_New( );
    if ( B == NULL ) return;
    B->Kind = CT_BOOL;
    B->Size = 1;
    B->Align = 1;
    Ctype_Register( "_Bool", B );

    RegisterIntPrim( "char",            1, 1 );
    RegisterIntPrim( "signed char",     1, 1 );
    RegisterIntPrim( "unsigned char",   1, 0 );
    RegisterIntPrim( "short",           2, 1 );
    RegisterIntPrim( "signed short",    2, 1 );
    RegisterIntPrim( "unsigned short",  2, 0 );
    RegisterIntPrim( "int",             4, 1 );
    RegisterIntPrim( "signed int",      4, 1 );
    RegisterIntPrim( "unsigned int",    4, 0 );
    RegisterIntPrim( "long",            4, 1 );    /* MSVC: long = 4 */
    RegisterIntPrim( "signed long",     4, 1 );
    RegisterIntPrim( "unsigned long",   4, 0 );
    RegisterIntPrim( "long long",       8, 1 );
    RegisterIntPrim( "signed long long",8, 1 );
    RegisterIntPrim( "unsigned long long",8, 0 );

    RegisterIntPrim( "int8_t",          1, 1 );
    RegisterIntPrim( "uint8_t",         1, 0 );
    RegisterIntPrim( "int16_t",         2, 1 );
    RegisterIntPrim( "uint16_t",        2, 0 );
    RegisterIntPrim( "int32_t",         4, 1 );
    RegisterIntPrim( "uint32_t",        4, 0 );
    RegisterIntPrim( "int64_t",         8, 1 );
    RegisterIntPrim( "uint64_t",        8, 0 );
    RegisterIntPrim( "size_t",          8, 0 );
    RegisterIntPrim( "ptrdiff_t",       8, 1 );
    RegisterIntPrim( "intptr_t",        8, 1 );
    RegisterIntPrim( "uintptr_t",       8, 0 );
    /* wchar_t on Windows is a 2-byte unsigned UTF-16 code unit (same as WCHAR,
       which win_types typedefs to unsigned short). Register it so cdefs that
       spell the C keyword `wchar_t` (e.g. the unicode package's
       NormalizeString/GetStringTypeW signatures) resolve instead of failing
       with "ffi.cdef: unknown type 'wchar_t'". */
    RegisterIntPrim( "wchar_t",         2, 0 );

    PCType_T F32 = Ctype_New( );
    if ( F32 == NULL ) return;
    F32->Kind = CT_FLOAT;
    F32->Size = 4;
    F32->Align = 4;
    Ctype_Register( "float", F32 );

    PCType_T F64 = Ctype_New( );
    if ( F64 == NULL ) return;
    F64->Kind = CT_FLOAT;
    F64->Size = 8;
    F64->Align = 8;
    Ctype_Register( "double", F64 );
}

void Ctype_Init( void ) {
    if ( g_Initialised ) return;
    memset( g_Slots, 0, sizeof( g_Slots ) );
    g_NumAllTypes = 0;
    g_Initialised = 1;
    RegisterPrimitives( );
}

void Ctype_Shutdown( void ) {
    int I = { 0 };
    for ( I = 0; I < g_NumAllTypes; I++ ) {
        PCType_T T = g_AllTypes[ I ];
        if ( T == NULL ) continue;
        PField_T F = T->Fields;
        while ( F != NULL ) {
            PField_T N = F->Next;
            free( F );
            F = N;
        }
        if ( T->ParamTypes != NULL ) free( T->ParamTypes );
        free( T );
    }
    memset( g_AllTypes, 0, ( size_t )g_NumAllTypes * sizeof( g_AllTypes[ 0 ] ) );
    g_NumAllTypes = 0;
    memset( g_Slots, 0, sizeof( g_Slots ) );
    memset( g_Enums, 0, sizeof( g_Enums ) );
    memset( g_Externs, 0, sizeof( g_Externs ) );
    g_Initialised = 0;
}
