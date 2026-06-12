/*!
 * @brief
 *  Marshal helpers — Lua TValue ↔ C value conversions used by both the
 *  generic call dispatcher (6d) and the JIT-inlined trampoline (6e).
 *  This file currently covers primitives only; strings (Task 3), cdata
 *  unwrap (Task 4), and C → Lua boxing (Task 5) extend it.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include "ffi/marshal.h"
#include "ffi/ctype.h"
#include "ffi/cdata.h"

#include "lauxlib.h"

#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

static int PushErrorf( lua_State *L, const char *Fmt, ... ) {
    va_list Ap;
    char Buf[ 192 ];
    va_start( Ap, Fmt );
    vsnprintf( Buf, sizeof( Buf ), Fmt, Ap );
    va_end( Ap );
    lua_pushstring( L, Buf );
    return 0;
}

/* Write an integer value of TargetSize bytes (1/2/4/8) at Dst. Truncates
   to the low TargetSize bytes via casting. */
static int WriteInt( void *Dst, size_t TargetSize, int64_t Value ) {
    if ( TargetSize == 1 ) { *( int8_t  * )Dst = ( int8_t  )Value; return 1; }
    if ( TargetSize == 2 ) { *( int16_t * )Dst = ( int16_t )Value; return 2; }
    if ( TargetSize == 4 ) { *( int32_t * )Dst = ( int32_t )Value; return 4; }
    if ( TargetSize == 8 ) { *( int64_t * )Dst = Value; return 8; }
    return 0;
}

static int WriteFloat( void *Dst, size_t TargetSize, double Value ) {
    if ( TargetSize == 4 ) { *( float  * )Dst = ( float )Value; return 4; }
    if ( TargetSize == 8 ) { *( double * )Dst = Value; return 8; }
    return 0;
}

int Marshal_LuaToC( lua_State *L, int StackIdx, PCType_T TargetType, void *Dst ) {
    if ( TargetType == NULL || Dst == NULL ) return 0;
    int LuaType = lua_type( L, StackIdx );

    /* nil → any pointer = NULL */
    if ( LuaType == LUA_TNIL ) {
        if ( TargetType->Kind == CT_PTR || TargetType->Kind == CT_FUNCPTR ) {
            *( void ** )Dst = NULL;
            return 8;
        }
        return PushErrorf( L, "ffi: cannot convert nil to non-pointer type" );
    }

    /* boolean → int / BOOL */
    if ( LuaType == LUA_TBOOLEAN ) {
        if ( TargetType->Kind == CT_BOOL || TargetType->Kind == CT_INT ) {
            return WriteInt( Dst, TargetType->Size, lua_toboolean( L, StackIdx ) ? 1 : 0 );
        }
        return PushErrorf( L, "ffi: cannot convert boolean to non-integer type" );
    }

    /* integer → CT_INT (truncate to target width) */
    if ( LuaType == LUA_TNUMBER ) {
        if ( lua_isinteger( L, StackIdx ) ) {
            int64_t V = ( int64_t )lua_tointeger( L, StackIdx );
            if ( TargetType->Kind == CT_INT || TargetType->Kind == CT_BOOL || TargetType->Kind == CT_ENUM ) {
                return WriteInt( Dst, TargetType->Size, V );
            }
            if ( TargetType->Kind == CT_FLOAT ) {
                return WriteFloat( Dst, TargetType->Size, ( double )V );
            }
            return PushErrorf( L, "ffi: cannot convert integer to %d-kind type", TargetType->Kind );
        }
        /* float */
        double N = ( double )lua_tonumber( L, StackIdx );
        if ( TargetType->Kind == CT_FLOAT ) {
            return WriteFloat( Dst, TargetType->Size, N );
        }
        if ( TargetType->Kind == CT_INT || TargetType->Kind == CT_BOOL || TargetType->Kind == CT_ENUM ) {
            /* Truncate toward zero, like a C cast `(int)d` (and LuaJIT): floor()
               rounds toward -infinity, so -2.7 stored -3 instead of -2. */
            int64_t V = ( int64_t )N;
            return WriteInt( Dst, TargetType->Size, V );
        }
        return PushErrorf( L, "ffi: cannot convert number to %d-kind type", TargetType->Kind );
    }

    /* string → char* (direct) or wchar_t* (transcoded) */
    if ( LuaType == LUA_TSTRING ) {
        if ( TargetType->Kind != CT_PTR ) {
            return PushErrorf( L, "ffi: cannot convert string to non-pointer type" );
        }
        PCType_T Elem = TargetType->ElemType;
        if ( Elem == NULL ) {
            return PushErrorf( L, "ffi: pointer has no element type" );
        }
        /* char* / const char* — direct pointer to Lua string interior */
        if ( Elem->Kind == CT_INT && Elem->Size == 1 ) {
            const char *S = lua_tolstring( L, StackIdx, NULL );
            *( const char ** )Dst = S;
            return 8;
        }
        /* wchar_t* / WCHAR* — UTF-8 → UTF-16 via MultiByteToWideChar.
           Scratch buffer pushed as a userdata on L's stack; caller keeps
           it alive across the call. */
        if ( Elem->Kind == CT_INT && Elem->Size == 2 ) {
            size_t SrcLen = 0;
            const char *S = lua_tolstring( L, StackIdx, &SrcLen );
            int Needed = MultiByteToWideChar( CP_UTF8, 0, S, ( int )SrcLen, NULL, 0 );
            if ( Needed <= 0 && SrcLen > 0 ) {
                return PushErrorf( L, "ffi: UTF-8 → UTF-16 conversion failed (size query)" );
            }
            size_t BufBytes = ( ( size_t )Needed + 1 ) * sizeof( wchar_t );
            wchar_t *Buf = ( wchar_t * )lua_newuserdatauv( L, BufBytes, 0 );
            int Wrote = MultiByteToWideChar( CP_UTF8, 0, S, ( int )SrcLen, Buf, Needed );
            if ( Wrote <= 0 && SrcLen > 0 ) {
                lua_pop( L, 1 );
                return PushErrorf( L, "ffi: UTF-8 → UTF-16 conversion failed" );
            }
            Buf[ Wrote ] = 0;     /* NUL-terminate */
            *( const wchar_t ** )Dst = Buf;
            return 8;
        }
        return PushErrorf( L, "ffi: string can only convert to char* or wchar_t*" );
    }

    /* cdata → matching type or void* */
    if ( LuaType == LUA_TUSERDATA ) {
        PCData_T Cd = FfiGetCData( L, StackIdx );
        if ( Cd == NULL ) {
            return PushErrorf( L, "ffi: userdata is not a cdata" );
        }
        PCType_T SrcType = Cd->Type;

        /* any-pointer cdata → void* */
        if ( TargetType->Kind == CT_PTR && TargetType->ElemType != NULL &&
             TargetType->ElemType->Kind == CT_VOID &&
             ( SrcType->Kind == CT_PTR || SrcType->Kind == CT_FUNCPTR ) ) {
            *( void ** )Dst = Cd->Ptr;
            return 8;
        }

        /* struct/union/array cdata → any pointer: pass address of inline
           buffer (or the borrowed storage if this cdata is a sub-object). */
        if ( TargetType->Kind == CT_PTR &&
             ( SrcType->Kind == CT_STRUCT || SrcType->Kind == CT_UNION ||
               SrcType->Kind == CT_ARRAY ) ) {
            *( void ** )Dst = Cdata_Storage( Cd );
            return 8;
        }

        /* same kind: extract payload appropriately */
        if ( TargetType->Kind == SrcType->Kind ) {
            switch ( TargetType->Kind ) {
                case CT_INT:
                case CT_BOOL:
                case CT_ENUM:
                    return WriteInt( Dst, TargetType->Size, Cd->I64 );
                case CT_FLOAT:
                    return WriteFloat( Dst, TargetType->Size, Cd->F64 );
                case CT_PTR:
                case CT_FUNCPTR:
                    *( void ** )Dst = Cd->Ptr;
                    return 8;
                case CT_STRUCT:
                case CT_UNION:
                case CT_ARRAY:
                    if ( SrcType->Size < TargetType->Size ) {
                        return PushErrorf( L, "ffi: source cdata too small for target" );
                    }
                    memcpy( Dst, Cdata_Storage( Cd ), TargetType->Size );
                    return ( int )TargetType->Size;
                default:
                    break;
            }
        }
        return PushErrorf( L, "ffi: cdata kind %d does not match target kind %d",
                           SrcType->Kind, TargetType->Kind );
    }

    return PushErrorf( L, "ffi: cannot convert %s to ctype (kind %d)",
                       lua_typename( L, LuaType ), TargetType->Kind );
}

int Marshal_CToLua( lua_State *L, PCType_T SourceType, const void *Src ) {
    if ( SourceType == NULL ) return 0;

    switch ( SourceType->Kind ) {
        case CT_VOID:
            return 0;
        case CT_BOOL: {
            /* Push as Lua boolean so `if cfn() then ... end` works
               naturally. Pushing as integer 0/1 would always be truthy
               in Lua (since 0 is truthy too), which breaks every
               `if BeginChild()`-style API call. */
            lua_pushboolean( L, *( const uint8_t * )Src != 0 );
            return 1;
        }
        case CT_INT:
        case CT_ENUM: {
            /* widths up to 4 bytes: push as Lua integer. wider widths (8 bytes)
               always boxed as cdata since lua_Integer is 64-bit signed and
               unsigned 64 would surface as negative. */
            int64_t V = 0;
            if ( SourceType->Size == 1 ) V = ( int64_t )( SourceType->IsSigned
                                                          ? ( int64_t )*( const int8_t  * )Src
                                                          : ( int64_t )*( const uint8_t  * )Src );
            else if ( SourceType->Size == 2 ) V = SourceType->IsSigned
                                                       ? ( int64_t )*( const int16_t * )Src
                                                       : ( int64_t )*( const uint16_t * )Src;
            else if ( SourceType->Size == 4 ) V = SourceType->IsSigned
                                                       ? ( int64_t )*( const int32_t * )Src
                                                       : ( int64_t )*( const uint32_t * )Src;
            else if ( SourceType->Size == 8 ) {
                /* For SIGNED 64-bit, push directly as lua_Integer -- it
                   already fits without loss. For UNSIGNED 64-bit, box as
                   cdata so values > INT64_MAX survive round-tripping
                   without aliasing to negatives in Lua. */
                if ( SourceType->IsSigned ) {
                    lua_pushinteger( L, ( lua_Integer )*( const int64_t * )Src );
                    return 1;
                }
                PCData_T Cd = FfiNewCData( L, SourceType );
                if ( Cd == NULL ) return 0;
                Cd->I64 = *( const int64_t * )Src;
                return 1;
            }
            else return 0;
            lua_pushinteger( L, ( lua_Integer )V );
            return 1;
        }
        case CT_FLOAT: {
            if ( SourceType->Size == 4 ) {
                lua_pushnumber( L, ( lua_Number )*( const float * )Src );
            } else if ( SourceType->Size == 8 ) {
                lua_pushnumber( L, ( lua_Number )*( const double * )Src );
            } else {
                return 0;
            }
            return 1;
        }
        case CT_PTR:
        case CT_FUNCPTR: {
            PCData_T Cd = FfiNewCData( L, SourceType );
            if ( Cd == NULL ) return 0;
            Cd->Ptr = *( void ** )Src;
            return 1;
        }
        case CT_STRUCT:
        case CT_UNION:
        case CT_ARRAY: {
            PCData_T Cd = FfiNewCData( L, SourceType );
            if ( Cd == NULL ) return 0;
            memcpy( Cd->Inline, Src, SourceType->Size );
            return 1;
        }
        default:
            return 0;
    }
}
