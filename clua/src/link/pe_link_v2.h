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

/* Forward: names of DLL exports discovered by Resolve_Walk. The link stage
   copies each into an output-owned buffer while emitting the PE, so the
   caller may free its RESOLVED_EXPORT_T array immediately after the call. */
struct _RESOLVED_EXPORT;   /* full type in compiler/resolve.h                */

#include <stdint.h>

/* Resource inputs handed to the linker to embed in an .rsrc PE section.
** Every field is optional; a zero-initialised struct produces the pre-.rsrc
** byte layout (no section, no data-directory entry). String fields are UTF-8
** and NUL-terminated; any missing value gets a documented default (see
** clua/src/link/rsrc_versioninfo.c). */
typedef struct LuacRsrcInputs {
    /* If nonzero, embed VS_VERSION_INFO built from these fields. */
    int         want_versioninfo;
    const char *product_name;         /* default "CLua Compiled Program"    */
    const char *product_version;      /* default = derived from FileVersion */
    const char *file_version;         /* default = CLUA_VERSION_STRING       */
    const char *file_description;     /* default = product name              */
    const char *company_name;         /* default empty                       */
    const char *legal_copyright;      /* default empty                       */
    const char *original_filename;    /* default = basename(out_path)         */

    /* If nonzero, embed the default RT_MANIFEST unless manifest_xml is set. */
    int            want_manifest;
    const uint8_t *manifest_xml;      /* NULL = use default template         */
    uint32_t       manifest_xml_len;

    /* If nonzero, embed an application icon from raw .ico bytes. */
    const uint8_t *icon_bytes;
    uint32_t       icon_bytes_len;
} LuacRsrcInputs;

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
**   require_coro — nonzero when the program could reach the coroutine table
**               (lc_module_uses_coroutine): the link force-pulls Coro_OpenLib
**               so aot_entry's weak call installs the fiber-based coroutine
**               library. Zero drops coro.o (~3 KB on rover's hello.exe) via
**               --gc-sections.
**   shared_rt — nonzero links against clua-rt.dll (via libclua-rt.dll.a +
**               the per-exe protoinit_rt.o) instead of the static archives:
**               ~30 KB exes that need clua-rt.dll beside them (or on PATH)
**               at run time. Zero (the default) keeps the fully static
**               single-file link, byte-for-byte as before.
**   ld_internal — link selection: -1 = honor %CLUA_LD% then DEFAULT
**               (internal when the CRT sysroot is discoverable, else gcc with
**               a one-line note), 0 = force the gcc/ld path, 1 = force the
**               built-in COFF->PE64 linker (LcPe_Link; needs the CRT sysroot
**               under lib\sysroot, no gcc). Ignored under shared_rt (the DLL
**               path stays gcc-only).
**   no_gc_sections — nonzero disables the built-in linker's --gc-sections
**               dead-code elimination (debug escape hatch). Zero (default)
**               sweeps unreachable function/data sections. No effect on the
**               gcc path (it always passes -Wl,--gc-sections).
*/
/*   output_kind — LC_OUTPUT_EXE (0, default) or LC_OUTPUT_DLL (1). DLL sets
**               IMAGE_FILE_DLL in the PE FileHeader, points the entry symbol
**               at Rt_DllMain (aot_entry_dll.o), and synthesizes an
**               IMAGE_EXPORT_DIRECTORY entry per name in exports[].
**   exports    — pointer to the caller's RESOLVED_EXPORT_T array (opaque here;
**               concrete type in compiler/resolve.h). NULL when there are no
**               exports or output_kind != LC_OUTPUT_DLL.
**   nexports   — number of entries in exports[].
**   rsrc       — optional. When non-NULL and any of its `want_*` / icon fields
**               is set, the internal linker emits a .rsrc section carrying the
**               requested VS_VERSION_INFO / RT_MANIFEST / RT_ICON resources.
**               NULL, or an all-zero struct, yields a resource-less output
**               (byte-identical to the pre-.rsrc code path). Only honored by
**               the internal linker; the gcc/ld path ignores it for now (needs
**               windres to be genuinely useful).
*/
int LuacLink_LinkProgram( const char *userObj, const char *outExe,
                          int no_interp, int require_ffi, int require_coro,
                          unsigned used_libs,
                          int shared_rt, int ld_internal, int no_gc_sections,
                          int output_kind,
                          struct _RESOLVED_EXPORT *exports, size_t nexports,
                          int strip_mode,
                          const LuacRsrcInputs *rsrc,
                          char *err, size_t errlen );

/* Emit the .DEF module-definition file that describes a DLL build's exports.
** Call AFTER LuacLink_LinkProgram has published the .dll so the .def can be
** written next to a real, complete DLL (matches what downstream toolchains
** expect: MSVC `link /def:foo.def /dll` or MinGW
** `dlltool -d foo.def -D foo.dll -l foo.lib`). Never called for .exe builds.
**
**   outDll    — path to the .dll the .def describes (used only for its
**               basename in the LIBRARY directive and to derive the default
**               def_path).
**   def_path  — where to write the .def. NULL/empty = derive
**               `<outDll-without-ext>.def` in the same directory.
**   exports   — array of exported symbol names (as they will appear from
**               `dumpbin /exports foo.dll`), one per entry.
**   nexports  — length of exports[]. Zero is legal (empty EXPORTS section).
**
** Returns 1 on success, 0 + message in `err` on failure. Deterministic: the
** same (outDll basename, exports) input produces the same bytes on every
** rebuild -- the .def is a stable interface descriptor. */
int LuacLink_EmitDllDef( const char *outDll, const char *def_path,
                         const char *const *exports, size_t nexports,
                         char *err, size_t errlen );

#endif /* LUAC_LINK_PE_LINK_V2_H */
