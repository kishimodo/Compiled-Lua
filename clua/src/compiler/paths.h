/*!
 * @brief
 *  Module-name → file-path resolution with a search list.
 */

#ifndef LUAVM_COMPILER_PATHS_H
#define LUAVM_COMPILER_PATHS_H

#include <stddef.h>

typedef struct _PATHS_OPTS {
    const char  *BasePath;         /* primary fallback */
    const char **IncludeDirs;      /* NULL-terminated list, searched first */
} PATHS_OPTS_T, *PPATHS_OPTS_T;

int Paths_ModuleNameToFilePath( const char    *ModuleName,
                                PPATHS_OPTS_T  Opts,
                                char          *OutBuf,
                                size_t         OutBufSize );

/* 1 if Path is under the global installed-package store (third-party code), so
   callers can scope first-party-only behavior such as the lint/warning pass. */
int Paths_IsStorePath( const char *Path );

/* 1 if ModuleName is rover-installed in the global store. Installed packages
   SHADOW same-named in-tree builtins during resolve (an install is explicit
   user intent, and installed packages bundle into AOT exes today). */
int Paths_InstalledInStore( const char *ModuleName );

#endif /* LUAVM_COMPILER_PATHS_H */
