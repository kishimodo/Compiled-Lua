/*
** ar_write.h -- write a GNU-form `ar` archive that wraps a single COFF object.
**
** Backs `clua build --output=lib`. See ar_write.c for the on-disk layout, the
** MinGW-vs-MSVC consumability note, and the symbol-inclusion rule.
*/
#ifndef LUAC_LINK_AR_WRITE_H
#define LUAC_LINK_AR_WRITE_H

#include <stddef.h>

/* Read the COFF at `obj_path`, enumerate its public defined symbols, and
** write a GNU-form ar archive at `out_lib_path` containing:
**   - "!<arch>\n" magic
**   - a "/" symbol-table member (SysV/GNU big-endian form) whose entries all
**     point at the single COFF member
**   - one "obj.o" member carrying the COFF bytes byte-for-byte
**
** Returns 1 on success, 0 + a message in err[] (which may be NULL) on failure.
** The output is deterministic: mtime/uid/gid/mode are fixed to zero. */
int LcArWrite_SingleMemberObject( const char *obj_path,
                                  const char *out_lib_path,
                                  char *err, size_t errlen );

#endif /* LUAC_LINK_AR_WRITE_H */
