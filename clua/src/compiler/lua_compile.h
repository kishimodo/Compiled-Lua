/*!
 * @brief
 *  Compile a Lua source file to bytecode using the upstream Lua 5.4
 *  parser + dumper (luaL_loadfile + lua_dump).
 */

#ifndef CLUA_COMPILER_LUA_COMPILE_H
#define CLUA_COMPILER_LUA_COMPILE_H

#include <stddef.h>

typedef struct _LUA_COMPILE_RESULT {
    unsigned char *Bytes;    /* malloc'd; caller frees */
    size_t         BytesLen;
    char          *ErrMsg;   /* malloc'd; NULL on success */
} LUA_COMPILE_RESULT_T, *PLUA_COMPILE_RESULT_T;

/*!
 * @brief
 *  Read SourcePath, compile it, populate Result.
 *
 * @param Strip
 *  When non-zero, debug info (line numbers, local variable names,
 *  upvalue names, source file path) is dropped from the dumped
 *  bytecode -- equivalent to luac's -s flag. Stack traces from the
 *  resulting binary will lack file/line attribution.
 *
 * @return
 *  1 on success, 0 on failure (Result->ErrMsg populated)
 */
int LuaCompile_File( const char *SourcePath, int Strip, PLUA_COMPILE_RESULT_T Result );

void LuaCompile_FreeResult( PLUA_COMPILE_RESULT_T Result );

#endif /* CLUA_COMPILER_LUA_COMPILE_H */
