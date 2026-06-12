#ifndef LUAC_CODEGEN_PROTOINIT_EMIT_H
#define LUAC_CODEGEN_PROTOINIT_EMIT_H
#include <stddef.h>
#include "ir/ir.h"
/* Emit a C source file defining ProtoInit_<i>() per reachable function and a
 * Proto *LuacProgram_BuildEntry(lua_State*) that runs them (children before
 * parents) and returns the entry Proto. Returns 1 on success, 0 + err. */
int LcEmitProtoInitC( const char *path, LcModule *m, char *err, size_t errlen );
#endif
