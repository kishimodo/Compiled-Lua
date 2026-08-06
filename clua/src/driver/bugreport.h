/*
** bugreport.h -- clua bug-report collector.
**
** Writes a Markdown file describing the local toolchain state (version,
** target triple, CLUA_* env vars, OS/CWD, git SHA, .cluarc tail) so a
** user can drop the file into an issue report and a maintainer has the
** basics without a back-and-forth. Never touches the network.
*/
#ifndef LUAC_DRIVER_BUGREPORT_H
#define LUAC_DRIVER_BUGREPORT_H

#include <stddef.h>

/* Write a bug report to `user_out`; NULL/"" -> derive
** `clua-bug-report-YYYYMMDD-HHMMSS.md` in the CWD. Copies the actual
** written path into `actual_out` (size = actual_out_size); on error
** returns 0 and puts a human-readable message in `err`. */
int LcBugreport_Write( const char *user_out, char *actual_out,
                       size_t actual_out_size, char *err, size_t errlen );

/* The fixed target triple this compiler targets. Value: the same string
** clang -print-target-triple would print for a build compiling for MSVC
** on native x64 Windows. */
const char *LcBugreport_TargetTriple( void );

#endif /* LUAC_DRIVER_BUGREPORT_H */
