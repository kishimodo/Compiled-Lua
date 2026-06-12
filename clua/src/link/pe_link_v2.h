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
**   userObj   — the codegen COFF .o (luac_fn_<i> bodies + .rdata$L blob)
**   outExe    — output PE path
**   no_interp — nonzero when the closed-world scan proved the program never
**               references "debug": the link substitutes lvm_nointerp.o for
**               the Lua archive's lvm.o, dropping the unreachable bytecode
**               interpreter loop (~15 KB) from the exe. Ignored under
**               shared_rt (the DLL carries the full lvm).
**   require_ffi — nonzero when the program references the ffi/bit globals:
**               the link force-pulls the Clua_OpenFfi anchor (ffi_anchor.o
**               in runtime-aot.a, exported by clua-rt.dll) so aot_entry's
**               weak call opens the FFI.
**   shared_rt — nonzero links against clua-rt.dll (via libclua-rt.dll.a +
**               the per-exe protoinit_rt.o) instead of the static archives:
**               ~30 KB exes that need clua-rt.dll beside them (or on PATH)
**               at run time. Zero (the default) keeps the fully static
**               single-file link, byte-for-byte as before.
*/
int LuacLink_LinkProgram( const char *userObj, const char *outExe,
                          int no_interp, int require_ffi, int shared_rt,
                          char *err, size_t errlen );

#endif /* LUAC_LINK_PE_LINK_V2_H */
