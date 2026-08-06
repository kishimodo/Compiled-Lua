/*
** import_lib.h — emit a Microsoft .DEF module-definition file for a DLL build.
**
** A .def is a small text descriptor of a DLL's public surface (LIBRARY name +
** EXPORTS list) that both MSVC (`link /def:foo.def /dll`) and MinGW dlltool
** (`dlltool -d foo.def -l libfoo.a` / `dlltool -d foo.def -D foo.dll -l foo.lib`)
** consume to synthesize the matching import library. Emitting the .def next to
** every DLL build is the smallest change that lets downstream C consumers link
** against a CLua-produced DLL without any CLua-side archive plumbing:
**
**     clua build foo.lua --output=dll -o foo.dll   # emits foo.dll + foo.def
**     dlltool -d foo.def -D foo.dll -l foo.lib     # user's one-liner if wanted
**
** LcEmit_DefFile writes the exact bytes:
**
**     LIBRARY "<basename>"
**     EXPORTS
**         <name_0>
**         <name_1>
**         ...
**
** No ordinals or NONAME hints are emitted -- the DLL uses name-based imports so
** every consumer (MSVC, gcc, LoadLibrary+GetProcAddress) sees a stable ABI even
** if a future rebuild reorders the export table.
**
** The writer stages the file next to the destination and moves it into place
** atomically (same directory as the DLL), matching pe_link_v2.c's stage+publish
** discipline: a failed emit never corrupts a prior good .def.
*/
#ifndef LUAC_LINK_IMPORT_LIB_H
#define LUAC_LINK_IMPORT_LIB_H

#include <stddef.h>

/* Emit a .def file listing `nexports` exports for `dll_path`.
**
**   dll_path  — path to the .dll the .def describes; only the BASENAME
**               (last path component) is written into the LIBRARY directive,
**               matching the Windows loader's DLL name resolution.
**   def_path  — path to write the .def to. Overwrites atomically.
**   exports   — array of nul-terminated C strings, one per exported symbol.
**               NULL entries are skipped; duplicate names are written verbatim
**               (the .def spec forbids duplicates -- the caller enforces it).
**   nexports  — length of exports[]. Zero is legal: an EXPORTS section with no
**               entries is a valid, if useless, .def.
**
** Returns 1 on success, 0 + human-readable message in `err` on failure.
*/
int LcEmit_DefFile( const char *dll_path, const char *def_path,
                    const char *const *exports, size_t nexports,
                    char *err, size_t errlen );

/* Convenience: derive `<dll_path_without_ext>.def` into `out` (size = out_size),
** returning 1 on success. Trims a trailing ".dll"/".DLL" if present; otherwise
** appends ".def" verbatim. Returns 0 if the buffer is too small. */
int LcEmit_DeriveDefPath( const char *dll_path, char *out, size_t out_size );

#endif /* LUAC_LINK_IMPORT_LIB_H */
