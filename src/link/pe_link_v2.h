/*
** pe_link_v2.h — native link glue for the LuaC AOT driver (M0).
**
** Takes the codegen COFF object (luac_user_<pid>.o, the luac_fn_<i> bodies) and
** the generated ProtoInit C source, compiles the ProtoInit C + src/runtime/
** aot_entry.c with MinGW gcc, then links a standard console PE against the
** embedded runtime/lua archives. aot_entry.c supplies main(), so the blob-
** coupled runtime_entry.o / runtime_init.o are NOT pulled.
*/
#ifndef LUAC_LINK_PE_LINK_V2_H
#define LUAC_LINK_PE_LINK_V2_H

#include <stddef.h>

/* Compile + link the program. Returns 1 on success, 0 + message in `err`.
**   userObj     — the codegen COFF .o (luac_fn_<i> bodies)
**   protoInitC  — the generated ProtoInit C source
**   outExe      — output PE path
*/
int LuacLink_LinkProgram( const char *userObj, const char *protoInitC,
                          const char *outExe, char *err, size_t errlen );

#endif /* LUAC_LINK_PE_LINK_V2_H */
