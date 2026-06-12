/*!
 * @brief
 *  CData_T allocation, metatable registration, GC hooks.
 *  Metamethods __tostring / __eq / __index / __newindex are added in
 *  Tasks 9 and 10. This file's __gc is a no-op (the inline payload dies
 *  with the userdata; pointer-owned memory is user-managed in v1).
 */

#include "ffi/cdata.h"
#include "ffi/ctype.h"
#include "ffi/marshal.h"
#include "ffi/ffi_load.h"
#include "ffi/ffi_call.h"
#include "ffi/ffi_callback.h"

#include "lauxlib.h"

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static int Cdata_Gc( lua_State *L ) {
    /* Dispatch any finalizer attached via ffi.gc(cd, fn). The finalizer
       table (registry[CDATA_GC_REGISTRY_KEY]) is keyed by the cdata's
       userdata address so it never keeps the cdata alive; the entry is
       cleared after firing so a reused address can't see a stale finalizer.
       metatype-installed __gc is handled in 6f via a separate per-type
       metatable that shadows this one. */
    void *Key = lua_touserdata( L, 1 );
    if ( Key == NULL ) return 0;
    lua_getfield( L, LUA_REGISTRYINDEX, CDATA_GC_REGISTRY_KEY );  /* [reg] */
    if ( !lua_istable( L, -1 ) ) { lua_pop( L, 1 ); return 0; }
    lua_pushlightuserdata( L, Key );                              /* [reg, key] */
    lua_rawget( L, -2 );                                          /* [reg, fn?] */
    if ( !lua_isnil( L, -1 ) ) {
        /* Finalizer is a Lua function or a callable cdata (C funcptr); both
           invoke as fn(cd). pcall contains any error so the GC isn't
           disturbed. */
        lua_pushvalue( L, 1 );                                   /* [reg, fn, cd] */
        if ( lua_pcall( L, 1, 0, 0 ) != LUA_OK ) {
            lua_pop( L, 1 );           /* discard finalizer error -> [reg] */
        }
        lua_pushlightuserdata( L, Key );                         /* [reg, key] */
        lua_pushnil( L );                                        /* [reg, key, nil] */
        lua_rawset( L, -3 );           /* table[key] = nil       -> [reg] */
    } else {
        lua_pop( L, 1 );               /* pop nil                -> [reg] */
    }
    lua_pop( L, 1 );                   /* pop registry table     -> [] */
    return 0;
}

void *Cdata_Storage( PCData_T Cd ) {
    if ( Cd == NULL ) return NULL;
    return ( Cd->Flags & CDATA_FLAG_BORROWED ) ? Cd->Ptr : ( void * )Cd->Inline;
}

static int Cdata_Tostring( lua_State *L ) {
    PCData_T Cd = FfiGetCData( L, 1 );
    if ( Cd == NULL ) { lua_pushstring( L, "(invalid cdata)" ); return 1; }
    char Buf[ 128 ];
    PCType_T T = Cd->Type;
    /* best-effort textual kind name for the type */
    const char *KindName = "T";
    switch ( T->Kind ) {
        case CT_INT:     KindName = T->IsSigned ? "int" : "uint"; break;
        case CT_FLOAT:   KindName = ( T->Size == 4 ) ? "float" : "double"; break;
        case CT_PTR:     KindName = "ptr";     break;
        case CT_STRUCT:  KindName = "struct";  break;
        case CT_UNION:   KindName = "union";   break;
        case CT_ARRAY:   KindName = "array";   break;
        case CT_FUNCPTR: KindName = "funcptr"; break;
        case CT_ENUM:    KindName = "enum";    break;
        case CT_BOOL:    KindName = "bool";    break;
        case CT_VOID:    KindName = "void";    break;
        case CT_LIB:     KindName = "ptr";     break;   /* compat: tests/users grep "ptr" */
        default: break;
    }
    /* Print the VALUE for primitives (way more useful than the cdata
       address when debugging); for pointers print the pointed-to address;
       for aggregates fall back to the cdata's storage address. */
    switch ( T->Kind ) {
        case CT_BOOL: {
            uint8_t V = *( const uint8_t * )Cdata_Storage( Cd );
            snprintf( Buf, sizeof( Buf ), "cdata<%s>: %s",
                      KindName, V != 0 ? "true" : "false" );
            break;
        }
        case CT_INT:
        case CT_ENUM: {
            /* Use the union slot for own values; storage-deref for borrowed.
               For borrowed we don't actually know which integer width to
               read without consulting Type->Size, so handle that. */
            int64_t V = 0;
            const void *Src = Cdata_Storage( Cd );
            if ( ( Cd->Flags & CDATA_FLAG_BORROWED ) || T->Kind == CT_ENUM ) {
                if ( T->Size == 1 ) V = T->IsSigned ? *( const int8_t  * )Src : *( const uint8_t  * )Src;
                else if ( T->Size == 2 ) V = T->IsSigned ? *( const int16_t * )Src : *( const uint16_t * )Src;
                else if ( T->Size == 4 ) V = T->IsSigned ? *( const int32_t * )Src : ( int64_t )*( const uint32_t * )Src;
                else if ( T->Size == 8 ) V = *( const int64_t * )Src;
            } else {
                V = Cd->I64;
            }
            if ( T->IsSigned ) {
                snprintf( Buf, sizeof( Buf ), "cdata<%s>: %lld",
                          KindName, ( long long )V );
            } else {
                snprintf( Buf, sizeof( Buf ), "cdata<%s>: %llu (0x%llX)",
                          KindName, ( unsigned long long )V,
                          ( unsigned long long )V );
            }
            break;
        }
        case CT_FLOAT: {
            double V;
            if ( Cd->Flags & CDATA_FLAG_BORROWED ) {
                V = ( T->Size == 4 )
                    ? ( double )*( const float * )Cdata_Storage( Cd )
                    :          *( const double * )Cdata_Storage( Cd );
            } else {
                V = Cd->F64;
            }
            snprintf( Buf, sizeof( Buf ), "cdata<%s>: %g", KindName, V );
            break;
        }
        case CT_PTR:
        case CT_FUNCPTR: {
            snprintf( Buf, sizeof( Buf ), "cdata<%s>: 0x%016llX",
                      KindName, ( unsigned long long )( uintptr_t )Cd->Ptr );
            break;
        }
        default: {
            snprintf( Buf, sizeof( Buf ), "cdata<%s>: 0x%016llX",
                      KindName,
                      ( unsigned long long )( uintptr_t )Cdata_Storage( Cd ) );
            break;
        }
    }
    lua_pushstring( L, Buf );
    return 1;
}

static int Cdata_Eq( lua_State *L ) {
    PCData_T A = FfiGetCData( L, 1 );
    PCData_T B = FfiGetCData( L, 2 );
    /* LuaJIT compat: null-pointer cdata == nil (or any non-cdata) is true;
       non-null pointer cdata == nil is false. */
    if ( A == NULL || B == NULL ) {
        PCData_T P = ( A != NULL ) ? A : B;
        if ( P == NULL ) { lua_pushboolean( L, 0 ); return 1; }
        int IsNullPtr = ( P->Type->Kind == CT_PTR || P->Type->Kind == CT_FUNCPTR )
                        && P->Ptr == NULL;
        lua_pushboolean( L, IsNullPtr );
        return 1;
    }
    if ( A->Type->Kind != B->Type->Kind ) { lua_pushboolean( L, 0 ); return 1; }
    int Eq = 0;
    if ( A->Type->Kind == CT_PTR || A->Type->Kind == CT_FUNCPTR ) {
        Eq = ( A->Ptr == B->Ptr );
    } else if ( A->Type->Kind == CT_INT || A->Type->Kind == CT_BOOL || A->Type->Kind == CT_ENUM ) {
        Eq = ( A->I64 == B->I64 );
    } else if ( A->Type->Kind == CT_FLOAT ) {
        Eq = ( A->F64 == B->F64 );
    } else if ( A->Type->Kind == CT_STRUCT || A->Type->Kind == CT_UNION || A->Type->Kind == CT_ARRAY ) {
        Eq = ( A->Type->Size == B->Type->Size ) &&
             ( memcmp( Cdata_Storage( A ), Cdata_Storage( B ),
                       A->Type->Size ) == 0 );
    }
    lua_pushboolean( L, Eq );
    return 1;
}

static PField_T FindFieldByName( PCType_T T, const char *Name ) {
    if ( T == NULL || Name == NULL ) return NULL;
    PField_T F = T->Fields;
    while ( F != NULL ) {
        if ( strcmp( F->Name, Name ) == 0 ) return F;
        F = F->Next;
    }
    return NULL;
}

/* Is K an aggregate kind (struct/union/array)? Aggregate sub-objects
   returned from __index need to be BORROWED cdata so that writes to
   their own sub-fields persist back to the parent's bytes -- the
   memcpy-into-fresh-cdata path that Marshal_CToLua uses for aggregates
   would discard those writes. */
static int IsAggregateKind( int Kind ) {
    return Kind == CT_STRUCT || Kind == CT_UNION || Kind == CT_ARRAY;
}

/* Push a sub-object (struct field / array element) onto the stack.
   - For aggregates: a BORROWED cdata pointing at FieldAddr, anchored
     to the parent cdata at ParentAbsIdx (so the parent stays alive).
   - For primitives: a fresh value cdata via Marshal_CToLua. */
static int PushSubObject( lua_State *L, PCType_T SubType,
                          const void *FieldAddr, int ParentAbsIdx ) {
    if ( IsAggregateKind( SubType->Kind ) ) {
        PCData_T Sub = FfiNewBorrowedCData( L, SubType,
                                            ( void * )FieldAddr,
                                            ParentAbsIdx );
        if ( Sub == NULL ) return luaL_error( L, "ffi: out of memory" );
        return 1;
    }
    return Marshal_CToLua( L, SubType, FieldAddr );
}

/* cb:free() -- release a Lua-function-backed callback's stub slot and its
   registry ref (LuaJIT compat). Only valid on cdata whose Ptr came from
   Ffi_AllocCallback; a plain cast'd native funcptr raises. The Ptr is
   NULLed so a later call through this cdata fails loudly ("function
   pointer not resolved") instead of jumping into a recycled stub. */
static int CdataFn_CallbackFree( lua_State *L ) {
    PCData_T Cd = FfiGetCData( L, 1 );
    if ( Cd == NULL || Cd->Type->Kind != CT_FUNCPTR ) {
        return luaL_error( L, "ffi: callback:free() on non-callback cdata" );
    }
    if ( Cd->Ptr == NULL || !Ffi_FreeCallback( L, Cd->Ptr ) ) {
        return luaL_error( L, "ffi: callback:free(): not a live callback" );
    }
    Cd->Ptr = NULL;
    return 0;
}

/* cb:set(fn) -- swap the Lua function a live callback invokes without
   changing the native stub address (LuaJIT compat). */
static int CdataFn_CallbackSet( lua_State *L ) {
    PCData_T Cd = FfiGetCData( L, 1 );
    luaL_checktype( L, 2, LUA_TFUNCTION );
    if ( Cd == NULL || Cd->Type->Kind != CT_FUNCPTR || Cd->Ptr == NULL ) {
        return luaL_error( L, "ffi: callback:set() on non-callback cdata" );
    }
    lua_pushvalue( L, 2 );
    if ( !Ffi_SetCallback( L, Cd->Ptr ) ) {
        return luaL_error( L, "ffi: callback:set(): not a live callback" );
    }
    return 0;
}

static int Cdata_Index( lua_State *L ) {
    PCData_T Cd = FfiGetCData( L, 1 );
    if ( Cd == NULL ) return luaL_error( L, "ffi: __index on non-cdata" );
    PCType_T T = Cd->Type;
    int ParentAbs = lua_absindex( L, 1 );

    /* CT_LIB: indexed by string symbol name → resolve via GetProcAddress */
    if ( T->Kind == CT_LIB && lua_isstring( L, 2 ) ) {
        const char *Sym = lua_tostring( L, 2 );
        if ( !Ffi_ResolveSymbol( L, Cd, Sym ) ) {
            return luaL_error( L, "%s", lua_tostring( L, -1 ) );
        }
        return 1;
    }

    /* struct / union: indexed by string field name (direct value, OR
       borrowed for aggregate sub-fields) */
    if ( ( T->Kind == CT_STRUCT || T->Kind == CT_UNION ) && lua_isstring( L, 2 ) ) {
        const char *Name = lua_tostring( L, 2 );
        PField_T F = FindFieldByName( T, Name );
        if ( F == NULL ) {
            return luaL_error( L, "ffi: no field '%s' in struct/union", Name );
        }
        const void *FieldAddr =
            ( const char * )Cdata_Storage( Cd ) + F->Offset;
        return PushSubObject( L, F->Type, FieldAddr, ParentAbs );
    }

    /* pointer to struct/union, indexed by string (NOT number): auto-deref.
       Mirrors C's ptr->field syntax. Without this `dos.e_magic` on an
       `IMAGE_DOS_HEADER *` would surface as "cannot index cdata of kind 4
       (CT_PTR)". Note: lua_isstring is true for numbers too (because Lua
       auto-converts), so we must use lua_type to distinguish. */
    if ( T->Kind == CT_PTR && lua_type( L, 2 ) == LUA_TSTRING ) {
        PCType_T Elem = T->ElemType;
        if ( Elem != NULL && ( Elem->Kind == CT_STRUCT || Elem->Kind == CT_UNION ) ) {
            const char *Name = lua_tostring( L, 2 );
            PField_T F = FindFieldByName( Elem, Name );
            if ( F == NULL ) {
                return luaL_error( L, "ffi: no field '%s' in struct/union", Name );
            }
            if ( Cd->Ptr == NULL ) {
                return luaL_error( L, "ffi: field '%s' through NULL pointer", Name );
            }
            const void *FieldAddr = ( const char * )Cd->Ptr + F->Offset;
            return PushSubObject( L, F->Type, FieldAddr, ParentAbs );
        }
    }

    /* pointer or array: indexed by integer. Lua-number → integer
       coercion is accepted when the value rounds cleanly; this softens
       the earlier strict lua_isinteger gate which sometimes rejected
       JIT-flowed integer locals. */
    if ( T->Kind == CT_PTR || T->Kind == CT_ARRAY ) {
        lua_Integer Idx;
        int HaveInt = 0;
        if ( lua_isinteger( L, 2 ) ) {
            Idx = lua_tointeger( L, 2 );
            HaveInt = 1;
        } else if ( lua_type( L, 2 ) == LUA_TNUMBER ) {
            lua_Number N = lua_tonumber( L, 2 );
            lua_Integer Trunc = ( lua_Integer )N;
            if ( ( lua_Number )Trunc == N ) {
                Idx = Trunc;
                HaveInt = 1;
            }
        }
        if ( HaveInt ) {
            PCType_T Elem = T->ElemType;
            if ( Elem == NULL ) return luaL_error( L, "ffi: pointer/array has no element type" );
            const void *Base = ( T->Kind == CT_PTR ) ? Cd->Ptr : Cdata_Storage( Cd );
            if ( Base == NULL ) return luaL_error( L, "ffi: indexing NULL pointer" );
            const void *Slot = ( const char * )Base + Idx * ( lua_Integer )Elem->Size;
            return PushSubObject( L, Elem, Slot, ParentAbs );
        }
    }

    /* function-pointer cdata: LuaJIT-compat callback methods. The methods
       themselves validate that the cdata is a live registered callback, so
       indexing a plain cast'd native funcptr still yields the method but
       calling it raises. */
    if ( T->Kind == CT_FUNCPTR && lua_type( L, 2 ) == LUA_TSTRING ) {
        const char *Name = lua_tostring( L, 2 );
        if ( strcmp( Name, "free" ) == 0 ) {
            lua_pushcfunction( L, CdataFn_CallbackFree );
            return 1;
        }
        if ( strcmp( Name, "set" ) == 0 ) {
            lua_pushcfunction( L, CdataFn_CallbackSet );
            return 1;
        }
    }

    return luaL_error( L, "ffi: cannot index cdata of kind %d", T->Kind );
}

static int Cdata_Newindex( lua_State *L ) {
    PCData_T Cd = FfiGetCData( L, 1 );
    if ( Cd == NULL ) return luaL_error( L, "ffi: __newindex on non-cdata" );
    PCType_T T = Cd->Type;

    /* struct / union: indexed by string field name (direct value).
       Uses Cdata_Storage so writes through a BORROWED sub-cdata also
       hit the original parent's bytes. */
    if ( ( T->Kind == CT_STRUCT || T->Kind == CT_UNION ) && lua_isstring( L, 2 ) ) {
        const char *Name = lua_tostring( L, 2 );
        PField_T F = FindFieldByName( T, Name );
        if ( F == NULL ) {
            return luaL_error( L, "ffi: no field '%s' in struct/union", Name );
        }
        void *Slot = ( char * )Cdata_Storage( Cd ) + F->Offset;
        if ( Marshal_LuaToC( L, 3, F->Type, Slot ) == 0 ) {
            return luaL_error( L, "ffi: %s", lua_tostring( L, -1 ) );
        }
        return 0;
    }

    /* pointer to struct/union, indexed by string (NOT number): auto-deref.
       Mirrors Cdata_Index's struct-ptr handling so `ptr.field = value`
       works. Same lua_type guard as the __index side. */
    if ( T->Kind == CT_PTR && lua_type( L, 2 ) == LUA_TSTRING ) {
        PCType_T Elem = T->ElemType;
        if ( Elem != NULL && ( Elem->Kind == CT_STRUCT || Elem->Kind == CT_UNION ) ) {
            const char *Name = lua_tostring( L, 2 );
            PField_T F = FindFieldByName( Elem, Name );
            if ( F == NULL ) {
                return luaL_error( L, "ffi: no field '%s' in struct/union", Name );
            }
            if ( Cd->Ptr == NULL ) {
                return luaL_error( L, "ffi: assigning to '%s' through NULL pointer", Name );
            }
            void *Slot = ( void * )( ( char * )Cd->Ptr + F->Offset );
            if ( Marshal_LuaToC( L, 3, F->Type, Slot ) == 0 ) {
                return luaL_error( L, "ffi: %s", lua_tostring( L, -1 ) );
            }
            return 0;
        }
    }

    /* pointer or array: indexed by integer. Accept whole-number floats
       (`arr[1.0]`) too -- the strict lua_isinteger gate rejected JIT-
       flowed integer values that had been cast to/from float along the
       way, even though the value rounded cleanly. */
    if ( T->Kind == CT_PTR || T->Kind == CT_ARRAY ) {
        lua_Integer Idx;
        int HaveInt = 0;
        if ( lua_isinteger( L, 2 ) ) {
            Idx = lua_tointeger( L, 2 );
            HaveInt = 1;
        } else if ( lua_type( L, 2 ) == LUA_TNUMBER ) {
            lua_Number N = lua_tonumber( L, 2 );
            lua_Integer Trunc = ( lua_Integer )N;
            if ( ( lua_Number )Trunc == N ) { Idx = Trunc; HaveInt = 1; }
        }
        if ( HaveInt ) {
            PCType_T Elem = T->ElemType;
            if ( Elem == NULL ) return luaL_error( L, "ffi: pointer/array has no element type" );
            void *Base = ( T->Kind == CT_PTR ) ? Cd->Ptr : Cdata_Storage( Cd );
            if ( Base == NULL ) return luaL_error( L, "ffi: writing to NULL pointer" );
            void *Slot = ( char * )Base + Idx * ( lua_Integer )Elem->Size;
            if ( Marshal_LuaToC( L, 3, Elem, Slot ) == 0 ) {
                return luaL_error( L, "ffi: %s", lua_tostring( L, -1 ) );
            }
            return 0;
        }
    }

    return luaL_error( L, "ffi: cannot assign to cdata of kind %d", T->Kind );
}

/* __add / __sub: pointer arithmetic. `ptr + n` for a typed pointer
   advances by n * sizeof(elem). Either operand may be the cdata; the
   other must be an integer-convertible Lua value.
   Whole-number floats (e.g. `ptr + 4.0`, or an upvalue that flowed through
   JIT's float path) are accepted as long as they round to an integer
   exactly -- the previous strict lua_isinteger gate had surfaced false
   "pointer arithmetic requires integer offset" errors for genuinely
   integer-valued numbers. */
static int Cdata_AddSub( lua_State *L, int Sign ) {
    PCData_T Cd = FfiGetCData( L, 1 );
    int      OffsetIdx;
    if ( Cd == NULL ) {
        /* operand order swapped: number + ptr */
        Cd = FfiGetCData( L, 2 );
        if ( Cd == NULL ) {
            return luaL_error( L, "ffi: arithmetic on non-cdata" );
        }
        OffsetIdx = 1;
    } else {
        OffsetIdx = 2;
    }
    lua_Integer N = 0;
    if ( lua_isinteger( L, OffsetIdx ) ) {
        N = lua_tointeger( L, OffsetIdx );
    } else if ( lua_type( L, OffsetIdx ) == LUA_TNUMBER ) {
        lua_Number Num = lua_tonumber( L, OffsetIdx );
        lua_Integer Trunc = ( lua_Integer )Num;
        if ( ( lua_Number )Trunc != Num ) {
            return luaL_error( L,
                "ffi: pointer arithmetic offset must be integer-valued "
                "(got non-integer %g)", Num );
        }
        N = Trunc;
    } else {
        return luaL_error( L,
            "ffi: pointer arithmetic requires a numeric integer offset" );
    }
    PCType_T T = Cd->Type;
    void    *Base;
    PCType_T ResultType;
    if ( T->Kind == CT_PTR ) {
        Base       = Cd->Ptr;
        ResultType = T;
    } else if ( T->Kind == CT_ARRAY ) {
        /* Array decays to a pointer to its first element (C semantics): the
           base is the array's inline storage and the result is a CT_PTR to
           the element type, so `arr + n` (and the chained `(arr + n)[i]`)
           work without an explicit ffi.cast("T*", arr). The result points
           into the array's storage, so the caller must keep the array alive
           for the pointer's lifetime -- same contract as ffi.cast. */
        Base       = Cdata_Storage( Cd );
        ResultType = Ctype_PointerTo( T->ElemType );
        if ( ResultType == NULL ) {
            return luaL_error( L, "ffi: cannot form pointer to array element type" );
        }
    } else {
        return luaL_error( L, "ffi: arithmetic only valid for pointer or array cdata" );
    }
    if ( Base == NULL ) return luaL_error( L, "ffi: arithmetic on NULL pointer" );
    PCType_T Elem = ResultType->ElemType;
    size_t   Step = ( Elem != NULL && Elem->Size > 0 ) ? Elem->Size : 1;
    void    *New  = ( void * )( ( char * )Base + ( ptrdiff_t )Sign * N * ( ptrdiff_t )Step );

    PCData_T Out = FfiNewCData( L, ResultType );
    if ( Out == NULL ) return luaL_error( L, "ffi: out of memory" );
    Out->Ptr   = New;
    Out->Flags &= ~CDATA_FLAG_OWNS_MEMORY;  /* arithmetic result never owns */
    return 1;
}

static int Cdata_Add( lua_State *L ) { return Cdata_AddSub( L,  1 ); }
static int Cdata_Sub( lua_State *L ) { return Cdata_AddSub( L, -1 ); }

void Cdata_RegisterMetatable( lua_State *L ) {
    if ( luaL_newmetatable( L, CDATA_METATABLE_NAME ) ) {
        /* fresh metatable on top of stack */
        lua_pushcfunction( L, Cdata_Gc );
        lua_setfield( L, -2, "__gc" );
        lua_pushcfunction( L, Cdata_Tostring );
        lua_setfield( L, -2, "__tostring" );
        lua_pushcfunction( L, Cdata_Eq );
        lua_setfield( L, -2, "__eq" );
        lua_pushcfunction( L, Cdata_Index );
        lua_setfield( L, -2, "__index" );
        lua_pushcfunction( L, Cdata_Newindex );
        lua_setfield( L, -2, "__newindex" );
        lua_pushcfunction( L, Cdata_Call );
        lua_setfield( L, -2, "__call" );
        lua_pushcfunction( L, Cdata_Add );
        lua_setfield( L, -2, "__add" );
        lua_pushcfunction( L, Cdata_Sub );
        lua_setfield( L, -2, "__sub" );
    }
    lua_pop( L, 1 );
}

PCData_T FfiNewCDataN( lua_State *L, PCType_T Type, int PayloadBytes ) {
    if ( Type == NULL ) return NULL;
    if ( PayloadBytes < 0 ) PayloadBytes = 0;
    /* For scalars we need at least 8 bytes (the size of the union's largest
       non-Inline member). For compound / VLA payloads the caller dictates. */
    size_t Payload = ( Type->Kind == CT_STRUCT ||
                       Type->Kind == CT_UNION  ||
                       Type->Kind == CT_ARRAY )
                       ? ( size_t )PayloadBytes
                       : sizeof( int64_t );   /* scalar: union slot is 8 bytes */
    size_t UdataSize = offsetof( CData_T, Inline ) + Payload;
    PCData_T Cd = ( PCData_T )lua_newuserdatauv( L, UdataSize, 0 );
    if ( Cd == NULL ) return NULL;
    memset( Cd, 0, UdataSize );
    Cd->Type = Type;
    Cd->Flags = CDATA_FLAG_OWNS_MEMORY;
    luaL_setmetatable( L, CDATA_METATABLE_NAME );
    return Cd;
}

PCData_T FfiNewCData( lua_State *L, PCType_T Type ) {
    if ( Type == NULL ) return NULL;
    return FfiNewCDataN( L, Type, ( int )Type->Size );
}

PCData_T FfiNewBorrowedCData( lua_State *L, PCType_T Type, void *Storage,
                              int ParentIdx ) {
    if ( Type == NULL ) return NULL;
    /* Borrowed cdata carries no inline payload -- the actual bytes live
       inside the parent cdata. Allocate just the header PLUS the union
       slot (8 bytes, the largest of Ptr / I64 / F64 / Inline[1]), so
       writing `Cd->Ptr = Storage` lands inside the userdata. Reserve one
       user-value slot to anchor the parent (lua_setiuservalue keeps the
       parent reachable from this cdata, so the GC doesn't free the parent
       while we hold a pointer into its storage). */
    size_t UdataSize = offsetof( CData_T, Inline ) + sizeof( int64_t );
    PCData_T Cd = ( PCData_T )lua_newuserdatauv( L, UdataSize, 1 );
    if ( Cd == NULL ) return NULL;
    memset( Cd, 0, UdataSize );
    Cd->Type  = Type;
    Cd->Flags = CDATA_FLAG_BORROWED;   /* explicitly NOT CDATA_FLAG_OWNS_MEMORY */
    Cd->Ptr   = Storage;
    luaL_setmetatable( L, CDATA_METATABLE_NAME );
    if ( ParentIdx != 0 ) {
        int Abs = lua_absindex( L, ParentIdx );
        lua_pushvalue( L, Abs );
        lua_setiuservalue( L, -2, 1 );   /* anchor parent */
    }
    return Cd;
}

PCData_T FfiNewAnchoredPtr( lua_State *L, PCType_T Type, void *Ptr, int SourceIdx ) {
    if ( Type == NULL ) return NULL;
    /* A plain pointer-valued cdata (.Ptr = Ptr) that ALSO anchors the object
       at SourceIdx in uservalue slot 1, so the GC keeps that source alive
       while this pointer references its bytes. Used for ffi.cast(string ->
       char* / wchar_t* ) so the derived pointer cannot dangle. Header + the
       8-byte union slot, one user value. */
    int Abs = ( SourceIdx != 0 ) ? lua_absindex( L, SourceIdx ) : 0;
    size_t UdataSize = offsetof( CData_T, Inline ) + sizeof( int64_t );
    PCData_T Cd = ( PCData_T )lua_newuserdatauv( L, UdataSize, 1 );
    if ( Cd == NULL ) return NULL;
    memset( Cd, 0, UdataSize );
    Cd->Type  = Type;
    Cd->Flags = 0;            /* a pointer value: owns nothing external, not borrowed */
    Cd->Ptr   = Ptr;
    luaL_setmetatable( L, CDATA_METATABLE_NAME );
    if ( Abs != 0 ) {
        lua_pushvalue( L, Abs );
        lua_setiuservalue( L, -2, 1 );   /* anchor source */
    }
    return Cd;
}

PCData_T FfiGetCData( lua_State *L, int Idx ) {
    return ( PCData_T )luaL_testudata( L, Idx, CDATA_METATABLE_NAME );
}

int FfiIsCData( lua_State *L, int Idx ) {
    return luaL_testudata( L, Idx, CDATA_METATABLE_NAME ) != NULL;
}
