/*!
 * @brief
 *  Generic call dispatcher. Marshals args, then invokes the per-signature
 *  thunk (which handles Win64 ABI placement: GPRs/XMMs for args 0-3 by
 *  position+type, stack for args 4+, RAX or XMM0 for return).
 */

#include "ffi/ffi_call.h"
#include "ffi/cdata.h"
#include "ffi/ctype.h"
#include "ffi/marshal.h"
#include "ffi/ffi_thunk.h"

#include "lauxlib.h"

#include <stdint.h>
#include <string.h>

int Ffi_GenericCall( lua_State *L, PCData_T FnCd, int BaseIdx ) {
    if ( FnCd == NULL ) {
        return luaL_error( L, "ffi: not a callable cdata" );
    }
    /* Accept both CT_FUNC (from ffi.C.<sym> lookup) and CT_FUNCPTR (from
       ffi.cast("FnType *", addr) or a struct field of function-pointer
       type). The cdecl parser flattens NumParams/ParamTypes onto the
       CT_FUNCPTR itself (M7 fix), so the dispatch works identically. */
    if ( FnCd->Type->Kind != CT_FUNC && FnCd->Type->Kind != CT_FUNCPTR ) {
        return luaL_error( L, "ffi: not a callable cdata (kind=%d)",
                           FnCd->Type->Kind );
    }
    if ( FnCd->Ptr == NULL ) {
        return luaL_error( L, "ffi: function pointer not resolved" );
    }

    PCType_T FuncT = FnCd->Type;
    /* reject variadic up-front: the per-signature thunk can't pack varargs
       per Win64 ABI, and silently calling would smash registers. */
    if ( FuncT->HasVararg ) {
        return luaL_error( L,
            "ffi: variadic functions are not callable in v1; use Lua-side "
            "formatting (string.format) and pass the result as a fixed arg" );
    }
    int      ExpectedArgs = FuncT->NumParams;
    int      GivenArgs    = lua_gettop( L ) - BaseIdx + 1;
    if ( GivenArgs != ExpectedArgs ) {
        return luaL_error( L, "ffi: function expects %d args, got %d",
                           ExpectedArgs, GivenArgs );
    }
    if ( ExpectedArgs > 16 ) {
        return luaL_error( L, "ffi: dispatcher supports max 16 args (function has %d)",
                           ExpectedArgs );
    }

    FFI_THUNK_T Thunk = Ffi_GetSignatureThunk( FuncT );
    if ( Thunk == NULL ) {
        return luaL_error( L, "ffi: signature not supported by current ABI thunk" );
    }

    uint64_t Args[ 16 ] = { 0 };
    int      I          = { 0 };
    for ( I = 0; I < ExpectedArgs; I++ ) {
        PCType_T PT = FuncT->ParamTypes[ I ];
        if ( Marshal_LuaToC( L, BaseIdx + I, PT, &Args[ I ] ) == 0 ) {
            return luaL_error( L, "ffi: %s", lua_tostring( L, -1 ) );
        }
    }

    uint64_t Result = 0;
    Thunk( FnCd->Ptr, Args, &Result );

    PCType_T RT = FuncT->ElemType;
    if ( RT == NULL || RT->Kind == CT_VOID ) return 0;
    return Marshal_CToLua( L, RT, &Result );
}

int Cdata_Call( lua_State *L ) {
    PCData_T Cd = FfiGetCData( L, 1 );
    if ( Cd == NULL ) {
        return luaL_error( L, "ffi: __call on non-cdata" );
    }
    if ( Cd->Type->Kind != CT_FUNC && Cd->Type->Kind != CT_FUNCPTR ) {
        return luaL_error( L, "ffi: cdata of kind %d is not callable", Cd->Type->Kind );
    }
    /* Args start at L's stack index 2 (idx 1 is the cdata itself). */
    return Ffi_GenericCall( L, Cd, 2 );
}
