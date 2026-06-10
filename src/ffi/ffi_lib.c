/*!
 * @brief
 *  ffi Lua library — registers ffi.cdef, ffi.new, ffi.sizeof, ffi.alignof,
 *  ffi.offsetof, ffi.cast, ffi.typeof, ffi.string, ffi.fill, ffi.copy.
 *  Other surface (ffi.load, ffi.C, ffi.metatype, ffi.errno) lands in 6d/6f.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "ffi/ffi_lib.h"
#include "ffi/ffi_load.h"
#include "ffi/ctype.h"
#include "ffi/cdata.h"
#include "ffi/cdecl_parser.h"
#include "ffi/marshal.h"
#include "ffi/ffi_callback.h"

#include "lauxlib.h"

#include <stdint.h>
#include <string.h>

/* String-keyed cache of parsed type expressions. Without this, every
   ffi.new("...") / ffi.cast("...") / ffi.sizeof("...") allocates a fresh
   ctype object via Cdecl_ParseTypeExpr; in a loop those allocations hit
   the global ctype table cap (1024 entries) within a few hundred iterations
   and the next ffi.new fails with "out of memory".
   Capacity 256 covers any realistic program's distinct type expressions. */
#define TYPE_EXPR_CACHE_SIZE 256

typedef struct {
    char       Src[ 96 ];   /* source string (truncated if longer) */
    PCType_T   Type;
} TYPE_EXPR_CACHE_ENTRY_T;

static TYPE_EXPR_CACHE_ENTRY_T g_TypeExprCache[ TYPE_EXPR_CACHE_SIZE ];
static int                     g_TypeExprCacheCount = 0;

static PCType_T TypeExprCacheLookup( const char *S ) {
    int I = 0;
    for ( I = 0; I < g_TypeExprCacheCount; I++ ) {
        if ( strcmp( g_TypeExprCache[ I ].Src, S ) == 0 ) {
            return g_TypeExprCache[ I ].Type;
        }
    }
    return NULL;
}

static void TypeExprCacheInsert( const char *S, PCType_T T ) {
    /* Don't cache strings that wouldn't fit (rare; falls back to re-parse). */
    if ( strlen( S ) >= sizeof( g_TypeExprCache[ 0 ].Src ) ) return;
    if ( g_TypeExprCacheCount >= TYPE_EXPR_CACHE_SIZE ) return;
    int I = g_TypeExprCacheCount++;
    strncpy( g_TypeExprCache[ I ].Src, S, sizeof( g_TypeExprCache[ 0 ].Src ) - 1 );
    g_TypeExprCache[ I ].Src[ sizeof( g_TypeExprCache[ 0 ].Src ) - 1 ] = '\0';
    g_TypeExprCache[ I ].Type = T;
}

/* Resolve the 1st argument to a PCType_T.
   Accepts either a string ctype expression OR a cdata typeof handle. */
static PCType_T ArgToType( lua_State *L, int Idx ) {
    if ( lua_isstring( L, Idx ) ) {
        const char *S = lua_tostring( L, Idx );
        PCType_T    T = TypeExprCacheLookup( S );
        if ( T != NULL ) return T;
        T = Cdecl_ParseTypeExpr( S );
        if ( T == NULL ) {
            luaL_error( L, "ffi: %s", Cdecl_LastError( ) );
            return NULL;
        }
        TypeExprCacheInsert( S, T );
        return T;
    }
    if ( FfiIsCData( L, Idx ) ) {
        PCData_T Cd = FfiGetCData( L, Idx );
        if ( Cd->Flags & CDATA_FLAG_IS_TYPEOF ) return Cd->Type;
        /* a regular cdata's type is also usable */
        return Cd->Type;
    }
    luaL_error( L, "ffi: expected ctype (string or ffi.typeof handle)" );
    return NULL;
}

static int LuaFn_Cdef( lua_State *L ) {
    const char *Src = luaL_checkstring( L, 1 );
    if ( !Cdecl_Parse( Src ) ) {
        return luaL_error( L, "ffi.cdef: %s", Cdecl_LastError( ) );
    }
    return 0;
}

static int LuaFn_New( lua_State *L ) {
    /* capture arg count before any stack pushes */
    int NArgs = lua_gettop( L );
    PCType_T T = ArgToType( L, 1 );

    /* VLA path: T[?] takes a runtime count as arg 2 and sizes the payload to it */
    int FlexN       = 0;
    int IsFlex      = ( T != NULL && T->Kind == CT_ARRAY && T->IsFlex );
    int PayloadSize = ( T != NULL ) ? ( int )T->Size : 0;
    if ( IsFlex ) {
        if ( NArgs < 2 || !lua_isnumber( L, 2 ) ) {
            return luaL_error( L, "ffi.new: variable-length array requires count" );
        }
        FlexN = ( int )lua_tointeger( L, 2 );
        if ( FlexN < 0 ) {
            return luaL_error( L, "ffi.new: array count must be >= 0" );
        }
        if ( T->ElemType == NULL ) {
            return luaL_error( L, "ffi.new: flex array missing element type" );
        }
        PayloadSize = FlexN * ( int )T->ElemType->Size;
    }

    PCData_T Cd = FfiNewCDataN( L, T, PayloadSize );
    if ( Cd == NULL ) return luaL_error( L, "ffi.new: allocation failed" );
    Cd->FlexN = FlexN;

    /* apply per-type metatype if one is registered */
    lua_pushlightuserdata( L, ( void * )T );
    lua_rawget( L, LUA_REGISTRYINDEX );
    if ( lua_istable( L, -1 ) ) {
        lua_setmetatable( L, -2 );   /* sets cdata's metatable = user's table; pops the table */
    } else {
        lua_pop( L, 1 );             /* pop nil */
    }

    /* optional init: if present, marshal arg 2 into the cdata's payload.
       For VLA, arg 2 is the count (consumed above) — skip init unless a
       3rd init arg is provided. */
    int InitIdx = IsFlex ? 3 : 2;
    if ( NArgs >= InitIdx && !lua_isnil( L, InitIdx ) ) {
        /* A scalar / pointer initializer for an ARRAY initializes element [0]
           with the ELEMENT type -- e.g. ffi.new("HANDLE[1]", h). Marshalling it
           against the array type itself rejected the element as a kind mismatch
           ("cdata kind 4 does not match target kind 5"). A whole-aggregate cdata
           initializer (array/struct/union) still takes the memcpy path below. */
        int InitIsAggregate = 0;
        if ( FfiIsCData( L, InitIdx ) ) {
            PCData_T Src = FfiGetCData( L, InitIdx );
            InitIsAggregate = ( Src != NULL && Src->Type != NULL &&
                                ( Src->Type->Kind == CT_ARRAY ||
                                  Src->Type->Kind == CT_STRUCT ||
                                  Src->Type->Kind == CT_UNION ) );
        }
        if ( T->Kind == CT_ARRAY && T->ElemType != NULL &&
             !lua_istable( L, InitIdx ) && !InitIsAggregate ) {
            if ( Marshal_LuaToC( L, InitIdx, T->ElemType, Cdata_Storage( Cd ) ) == 0 ) {
                return luaL_error( L, "ffi.new init: %s", lua_tostring( L, -1 ) );
            }
        } else {
            void *Dst = ( T->Kind == CT_STRUCT || T->Kind == CT_UNION || T->Kind == CT_ARRAY )
                          ? Cdata_Storage( Cd )
                          : ( void * )&Cd->I64;
            if ( Marshal_LuaToC( L, InitIdx, T, Dst ) == 0 ) {
                return luaL_error( L, "ffi.new init: %s", lua_tostring( L, -1 ) );
            }
        }
    }
    return 1;
}

static int LuaFn_Sizeof( lua_State *L ) {
    PCType_T T = ArgToType( L, 1 );
    int N = ( int )luaL_optinteger( L, 2, 1 );
    lua_pushinteger( L, ( lua_Integer )( T->Size * ( size_t )N ) );
    return 1;
}

static int LuaFn_Alignof( lua_State *L ) {
    PCType_T T = ArgToType( L, 1 );
    lua_pushinteger( L, ( lua_Integer )T->Align );
    return 1;
}

static int LuaFn_Offsetof( lua_State *L ) {
    PCType_T T = ArgToType( L, 1 );
    const char *FieldName = luaL_checkstring( L, 2 );
    if ( T->Kind != CT_STRUCT && T->Kind != CT_UNION ) {
        return luaL_error( L, "ffi.offsetof: not a struct or union" );
    }
    PField_T F = T->Fields;
    while ( F != NULL ) {
        if ( strcmp( F->Name, FieldName ) == 0 ) {
            lua_pushinteger( L, ( lua_Integer )F->Offset );
            return 1;
        }
        F = F->Next;
    }
    return luaL_error( L, "ffi.offsetof: no field '%s'", FieldName );
}

static int LuaFn_Typeof( lua_State *L ) {
    PCType_T T  = ArgToType( L, 1 );
    PCData_T Cd = FfiNewCData( L, T );
    if ( Cd == NULL ) return luaL_error( L, "ffi.typeof: allocation failed" );
    Cd->Flags |= CDATA_FLAG_IS_TYPEOF;
    Cd->Flags &= ~CDATA_FLAG_OWNS_MEMORY;
    return 1;
}

/* Truncate a 64-bit integer to a narrower C integer width, sign- or
   zero-extending back to 64 bits per the target's signedness -- exactly what a
   C cast `(T)v` does. The primitive-cdata read path (Cdata_Tostring/Cdata_Eq)
   reads Cd->I64 verbatim, so the boxed value must already be width-correct;
   without this, `ffi.cast("unsigned int", -1)` stored 0xFFFFFFFFFFFFFFFF and
   printed 18446744073709551615 instead of 4294967295. The struct-field write
   path (WriteInt) already truncates this way; this brings the cast path in line. */
static int64_t Ffi_NarrowInt( int64_t V, size_t Size, int IsSigned ) {
    if ( Size == 0 || Size >= 8 ) return V;
    uint64_t Mask = ( ( uint64_t )1 << ( Size * 8 ) ) - 1u;
    uint64_t U    = ( uint64_t )V & Mask;
    if ( IsSigned && ( U & ( ( uint64_t )1 << ( Size * 8 - 1 ) ) ) ) {
        U |= ~Mask;  /* sign-extend the top bit */
    }
    return ( int64_t )U;
}

static int LuaFn_Cast( lua_State *L ) {
    PCType_T T   = ArgToType( L, 1 );
    PCData_T Out = FfiNewCData( L, T );
    if ( Out == NULL ) return luaL_error( L, "ffi.cast: allocation failed" );

    if ( lua_isfunction( L, 2 ) && T->Kind == CT_FUNCPTR ) {
        /* dup the function to the top; Ffi_AllocCallback consumes it via luaL_ref */
        lua_pushvalue( L, 2 );
        void *Stub = Ffi_AllocCallback( L, T );
        if ( Stub == NULL ) return luaL_error( L, "ffi.cast: callback alloc failed" );
        Out->Ptr = Stub;
        Out->Flags &= ~CDATA_FLAG_OWNS_MEMORY;  /* stub owned by g_Callbacks */
        return 1;
    }
    if ( FfiIsCData( L, 2 ) ) {
        PCData_T Src = FfiGetCData( L, 2 );
        /* reinterpret the source payload as the target type */
        if ( T->Kind == CT_PTR || T->Kind == CT_FUNCPTR ) {
            /* When source is a struct/union/array cdata, its payload lives
               at Src->Inline (Src->Ptr is 0). Casting it to a pointer type
               should produce a pointer to that inline storage -- which is
               the C-equivalent of `(T *)&value` for a value-typed cdata. */
            if ( Src->Type->Kind == CT_STRUCT ||
                 Src->Type->Kind == CT_UNION  ||
                 Src->Type->Kind == CT_ARRAY ) {
                Out->Ptr = Cdata_Storage( Src );
            } else {
                Out->Ptr = Src->Ptr;
            }
        } else if ( T->Kind == CT_INT || T->Kind == CT_ENUM || T->Kind == CT_BOOL ) {
            if ( Src->Type->Kind == CT_STRUCT || Src->Type->Kind == CT_UNION ||
                 Src->Type->Kind == CT_ARRAY ) {
                /* array/struct/union → integer: address of inline storage, not value */
                Out->I64 = Ffi_NarrowInt( (int64_t)(intptr_t)Cdata_Storage( Src ), T->Size, T->IsSigned );
            } else {
                Out->I64 = Ffi_NarrowInt( Src->I64, T->Size, T->IsSigned );
            }
        } else if ( T->Kind == CT_FLOAT ) {
            Out->F64 = Src->F64;
        } else if ( T->Kind == CT_STRUCT || T->Kind == CT_UNION || T->Kind == CT_ARRAY ) {
            size_t N = ( Src->Type->Size < T->Size ) ? Src->Type->Size : T->Size;
            memcpy( Cdata_Storage( Out ), Cdata_Storage( Src ), N );
        }
        return 1;
    }
    if ( lua_isnumber( L, 2 ) ) {
        int64_t V = ( int64_t )lua_tointeger( L, 2 );
        if ( T->Kind == CT_PTR || T->Kind == CT_FUNCPTR ) {
            Out->Ptr = ( void * )( intptr_t )V;
        } else if ( T->Kind == CT_INT || T->Kind == CT_ENUM || T->Kind == CT_BOOL ) {
            Out->I64 = Ffi_NarrowInt( V, T->Size, T->IsSigned );
        } else if ( T->Kind == CT_FLOAT ) {
            Out->F64 = ( double )V;
        }
        return 1;
    }
    if ( lua_isnil( L, 2 ) ) {
        if ( T->Kind != CT_PTR && T->Kind != CT_FUNCPTR ) {
            return luaL_error( L, "ffi.cast: cannot cast nil to non-pointer type" );
        }
        Out->Ptr = NULL;
        return 1;
    }
    /* Cast a Lua string to a pointer. Checked as LUA_TSTRING explicitly so
       lua_tolstring never coerces a number in place. The result anchors its
       source in a uservalue slot (FfiNewAnchoredPtr) so the derived pointer
       can't dangle if the caller drops the source -- a safety improvement on
       the raw LuaJIT `ffi.cast("void*", s)` contract. `Out` was pre-allocated
       at the top of this function; we replace it with the anchored cdata. */
    if ( lua_type( L, 2 ) == LUA_TSTRING ) {
        if ( T->Kind != CT_PTR && T->Kind != CT_FUNCPTR ) {
            return luaL_error( L, "ffi.cast: cannot cast string to non-pointer type" );
        }
        int      OutIdx = lua_gettop( L );   /* Out is on top */
        PCType_T Elem   = T->ElemType;
        /* wchar_t* / WCHAR* / unsigned short*: transcode UTF-8 -> UTF-16 into
           an owned Lua-userdata buffer and anchor that buffer on the result. */
        if ( Elem != NULL && Elem->Kind == CT_INT && Elem->Size == 2 ) {
            size_t      SrcLen = 0;
            const char *S      = lua_tolstring( L, 2, &SrcLen );
            int Needed = MultiByteToWideChar( CP_UTF8, 0, S, ( int )SrcLen, NULL, 0 );
            if ( Needed < 0 || ( Needed == 0 && SrcLen > 0 ) ) {
                return luaL_error( L, "ffi.cast: UTF-8 -> UTF-16 conversion failed" );
            }
            size_t   BufBytes = ( ( size_t )Needed + 1 ) * sizeof( wchar_t );
            wchar_t *Buf = ( wchar_t * )lua_newuserdatauv( L, BufBytes, 0 ); /* buffer on top */
            if ( SrcLen > 0 ) {
                MultiByteToWideChar( CP_UTF8, 0, S, ( int )SrcLen, Buf, Needed );
            }
            Buf[ Needed ] = 0;                 /* NUL-terminate */
            if ( FfiNewAnchoredPtr( L, T, Buf, lua_gettop( L ) ) == NULL ) {
                return luaL_error( L, "ffi.cast: allocation failed" );
            }
            lua_replace( L, OutIdx );          /* anchored cdata -> Out slot, pop */
            lua_pop( L, 1 );                   /* drop the buffer (now anchored)  */
            return 1;
        }
        /* char* / void* / other byte pointers: point at the string interior,
           anchoring the source string. */
        if ( FfiNewAnchoredPtr( L, T, ( void * )lua_tolstring( L, 2, NULL ), 2 ) == NULL ) {
            return luaL_error( L, "ffi.cast: allocation failed" );
        }
        lua_replace( L, OutIdx );              /* drop the pre-created Out */
        return 1;
    }
    return luaL_error( L, "ffi.cast: cannot cast %s", luaL_typename( L, 2 ) );
}

/* resolve a cdata arg to its underlying buffer address */
static void *ArgToBufPtr( lua_State *L, int Idx ) {
    if ( !FfiIsCData( L, Idx ) ) {
        luaL_error( L, "ffi: expected cdata buffer at arg %d", Idx );
        return NULL;
    }
    PCData_T Cd = FfiGetCData( L, Idx );
    /* pointers store target in Ptr; arrays/structs/unions store payload inline */
    if ( Cd->Type->Kind == CT_PTR || Cd->Type->Kind == CT_FUNCPTR ) {
        if ( Cd->Ptr == NULL ) {
            luaL_error( L, "ffi: NULL pointer dereference" );
            return NULL;
        }
        return Cd->Ptr;
    }
    return Cdata_Storage( Cd );
}

static int LuaFn_String( lua_State *L ) {
    void *Buf = ArgToBufPtr( L, 1 );
    if ( lua_gettop( L ) >= 2 && lua_isinteger( L, 2 ) ) {
        size_t N = ( size_t )lua_tointeger( L, 2 );
        lua_pushlstring( L, ( const char * )Buf, N );
    } else {
        lua_pushstring( L, ( const char * )Buf );
    }
    return 1;
}

static int LuaFn_Fill( lua_State *L ) {
    void  *Buf = ArgToBufPtr( L, 1 );
    size_t N   = ( size_t )luaL_checkinteger( L, 2 );
    int    C   = ( int )luaL_optinteger( L, 3, 0 );
    memset( Buf, C, N );
    return 0;
}

static int LuaFn_Copy( lua_State *L ) {
    void        *Dst    = ArgToBufPtr( L, 1 );
    size_t       N      = 0;
    const void  *Src    = NULL;
    if ( lua_isstring( L, 2 ) ) {
        size_t SrcLen = 0;
        Src = lua_tolstring( L, 2, &SrcLen );
        /* if no count given for string source, default to len + 1 (include NUL) */
        N = ( lua_gettop( L ) >= 3 && lua_isinteger( L, 3 ) )
              ? ( size_t )lua_tointeger( L, 3 )
              : SrcLen + 1;
    } else if ( FfiIsCData( L, 2 ) ) {
        Src = ArgToBufPtr( L, 2 );
        N   = ( size_t )luaL_checkinteger( L, 3 );
    } else {
        return luaL_error( L, "ffi.copy: source must be cdata or string" );
    }
    memcpy( Dst, Src, N );
    return 0;
}

static int LuaFn_Errno( lua_State *L ) {
    DWORD Prev = GetLastError( );
    if ( lua_gettop( L ) >= 1 && !lua_isnil( L, 1 ) ) {
        DWORD New = ( DWORD )luaL_checkinteger( L, 1 );
        SetLastError( New );
    }
    lua_pushinteger( L, ( lua_Integer )Prev );
    return 1;
}

static int LuaFn_Abi( lua_State *L ) {
    const char *Param = luaL_checkstring( L, 1 );
    int Ok = ( strcmp( Param, "win"   ) == 0 ) ||
             ( strcmp( Param, "64bit" ) == 0 ) ||
             ( strcmp( Param, "le"    ) == 0 ) ||
             ( strcmp( Param, "fpu"   ) == 0 );
    lua_pushboolean( L, Ok );
    return 1;
}

static int LuaFn_Metatype( lua_State *L ) {
    PCType_T T = ArgToType( L, 1 );
    luaL_checktype( L, 2, LUA_TTABLE );

    /* store the metatable in the registry, keyed by ctype pointer */
    lua_pushlightuserdata( L, ( void * )T );
    lua_pushvalue( L, 2 );           /* dup mt */
    lua_rawset( L, LUA_REGISTRYINDEX );

    /* return a ctype handle (same shape as ffi.typeof result) */
    PCData_T Cd = FfiNewCData( L, T );
    if ( Cd == NULL ) return luaL_error( L, "ffi.metatype: cdata alloc failed" );
    Cd->Flags |= CDATA_FLAG_IS_TYPEOF;
    Cd->Flags &= ~CDATA_FLAG_OWNS_MEMORY;

    return 1;
}

/*!
 * @brief
 *  ffi.gc(cdata, finalizer) -- attach a GC finalizer to a cdata. When the
 *  cdata is collected (or at lua_close), finalizer(cdata) is invoked exactly
 *  once. Passing nil for finalizer detaches any previously attached one
 *  (used before manual destruction to avoid a double free). Returns the
 *  cdata so the allocation can be wrapped inline:
 *      local p = ffi.gc(ffi.cast("T*", malloc(n)), free)
 *  Matches the LuaJIT ffi.gc contract relied on by the bundled packages.
 */
static int LuaFn_Gc( lua_State *L ) {
    PCData_T Cd = FfiGetCData( L, 1 );
    if ( Cd == NULL ) return luaL_error( L, "ffi.gc: first argument must be a cdata" );
    /* The finalizer may be a Lua function OR a callable cdata (a C function
       pointer, e.g. ffi.C.free) -- LuaJIT accepts both, and the bundled
       packages pass the latter (ffi.gc(h, ffi.C.BCryptDestroyHash)). nil
       detaches. Reject anything else up front for a clear error. */
    if ( !lua_isnoneornil( L, 2 ) &&
         lua_type( L, 2 ) != LUA_TFUNCTION &&
         !FfiIsCData( L, 2 ) ) {
        return luaL_error( L, "ffi.gc: finalizer must be a function or callable cdata" );
    }
    /* registry[CDATA_GC_REGISTRY_KEY] = { [lightuserdata(udata)] = finalizer }.
       The key is the cdata's address, so it does NOT pin the cdata. Created
       lazily on first use. */
    lua_getfield( L, LUA_REGISTRYINDEX, CDATA_GC_REGISTRY_KEY );
    if ( !lua_istable( L, -1 ) ) {
        lua_pop( L, 1 );
        lua_newtable( L );
        lua_pushvalue( L, -1 );
        lua_setfield( L, LUA_REGISTRYINDEX, CDATA_GC_REGISTRY_KEY );
    }
    lua_pushlightuserdata( L, lua_touserdata( L, 1 ) );  /* key */
    if ( lua_isnoneornil( L, 2 ) ) {
        lua_pushnil( L );
    } else {
        lua_pushvalue( L, 2 );                           /* finalizer */
    }
    lua_rawset( L, -3 );          /* table[key] = finalizer-or-nil */
    lua_pop( L, 1 );              /* pop the registry table */
    lua_pushvalue( L, 1 );        /* return the cdata unchanged */
    return 1;
}

/*!
 * @brief
 *  Release a callback's stub slot and unbind its Lua function.
 *  The caller passes the funcptr cdata previously returned by ffi.cast.
 *  Null pointers are a no-op (matches double-free safety).
 */
static int LuaFn_CallbackFree( lua_State *L ) {
    PCData_T Cd = FfiGetCData( L, 1 );
    if ( Cd == NULL ) return luaL_error( L, "ffi.callback_free: not a cdata" );
    if ( Cd->Type->Kind != CT_FUNCPTR ) {
        return luaL_error( L, "ffi.callback_free: not a function pointer cdata" );
    }
    if ( Cd->Ptr == NULL ) return 0;  /* no-op for null */
    int Ok = Ffi_FreeCallback( L, Cd->Ptr );
    if ( !Ok ) return luaL_error( L, "ffi.callback_free: pointer is not a known callback" );
    Cd->Ptr = NULL;
    return 0;
}

static const luaL_Reg g_FfiFuncs[ ] = {
    { "cdef",     LuaFn_Cdef     },
    { "new",      LuaFn_New      },
    { "sizeof",   LuaFn_Sizeof   },
    { "alignof",  LuaFn_Alignof  },
    { "offsetof", LuaFn_Offsetof },
    { "cast",     LuaFn_Cast     },
    { "typeof",   LuaFn_Typeof   },
    { "string",   LuaFn_String   },
    { "fill",     LuaFn_Fill     },
    { "copy",     LuaFn_Copy     },
    { "abi",       LuaFn_Abi       },
    { "errno",     LuaFn_Errno     },
    { "metatype",  LuaFn_Metatype  },
    { "gc",        LuaFn_Gc        },
    { "callback_free", LuaFn_CallbackFree },
    { NULL, NULL }
};

/* Cdata-aware tonumber: returns the underlying numeric value for cdata
   of integer, float, or pointer kind; falls back to the original tonumber
   for everything else (numbers, strings, bools). Without this, the LuaJIT
   pattern `tonumber(ffi.cast("intptr_t", handle))` returns nil because
   the standard tonumber doesn't recognize userdata. */
static int CdataAwareToNumber( lua_State *L ) {
    if ( FfiIsCData( L, 1 ) ) {
        PCData_T Cd = FfiGetCData( L, 1 );
        switch ( Cd->Type->Kind ) {
            case CT_INT:
            case CT_BOOL:
            case CT_ENUM:
                lua_pushinteger( L, ( lua_Integer )Cd->I64 );
                return 1;
            case CT_FLOAT:
                lua_pushnumber( L, ( lua_Number )Cd->F64 );
                return 1;
            case CT_PTR:
            case CT_FUNCPTR:
                lua_pushinteger( L, ( lua_Integer )( intptr_t )Cd->Ptr );
                return 1;
            default:
                lua_pushnil( L );
                return 1;
        }
    }
    /* Fallback: call the original tonumber stashed in the registry. */
    lua_getfield( L, LUA_REGISTRYINDEX, "ffi:orig_tonumber" );
    lua_insert( L, 1 );  /* move it before the args */
    lua_call( L, lua_gettop( L ) - 1, 1 );
    return 1;
}

void Ffi_OpenLib( lua_State *L ) {
    Cdata_RegisterMetatable( L );
    luaL_newlib( L, g_FfiFuncs );
    /* string constants: ffi.os, ffi.arch */
    lua_pushstring( L, "Windows" );
    lua_setfield( L, -2, "os" );
    lua_pushstring( L, "x64" );
    lua_setfield( L, -2, "arch" );
    Ffi_OpenLoad( L );
    lua_setglobal( L, "ffi" );

    /* Hook tonumber to handle cdata. Store the original under a registry
       key so CdataAwareToNumber can chain to it for non-cdata args. */
    lua_getglobal( L, "tonumber" );
    lua_setfield( L, LUA_REGISTRYINDEX, "ffi:orig_tonumber" );
    lua_pushcfunction( L, CdataAwareToNumber );
    lua_setglobal( L, "tonumber" );
}
