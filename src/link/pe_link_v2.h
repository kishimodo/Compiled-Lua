/*
** pe_link_v2.h — native link glue for the CLua AOT driver.
**
** Takes the codegen COFF object (which carries the luac_fn_<i> bodies PLUS
** the .rdata$L ProtoInit blob + relocated fn table) and links a standard
** console PE in ONE step against the precompiled aot_entry.o and the
** runtime-aot/lua archives. aot_entry.o supplies main() and the closed-world
** stubs (so neither the v1 blob runtime nor the Lua front-end is pulled);
** LuacProgram_BuildEntry lives in the runtime archive (protoinit_rt.o) and
** reads the blob — no generated C, no compile step at user-build time.
**
** Resource discovery (archives, aot_entry.o, include dirs for the cold-tree
** fallback) is relocatable: CLUA_HOME env var -> exe-relative dist layout
** (<exe>\..\lib, <exe>\lib) -> exe-relative repo layout (<exe> = build\bin)
** -> CWD repo layout (the historical behavior, keeps tests working no matter
** where the binaries were copied).
*/
#ifndef LUAC_LINK_PE_LINK_V2_H
#define LUAC_LINK_PE_LINK_V2_H

#include <stddef.h>

/* Link the program. Returns 1 on success, 0 + message in `err`.
**   userObj — the codegen COFF .o (luac_fn_<i> bodies + .rdata$L blob)
**   outExe  — output PE path
*/
int LuacLink_LinkProgram( const char *userObj, const char *outExe,
                          char *err, size_t errlen );

#endif /* LUAC_LINK_PE_LINK_V2_H */
