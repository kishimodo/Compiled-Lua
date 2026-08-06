/*
** argexpand.h -- response-file (@file) expansion for the CLua drivers.
**
** GCC / clang / MSVC all accept `@<path>` on the command line: the file
** is read and its whitespace-separated tokens are spliced into argv at
** that position. This lets a long link/build command (hundreds of -I,
** -L, package names) escape Windows' 8191-char command-line limit and
** live in a file the user's build system generates.
**
** One level of expansion is supported (a nested `@` inside a response
** file is left as a literal token; recursion opens a footgun). Windows
** CR/LF line endings and simple `"quoted tokens with spaces"` are
** understood.
*/
#ifndef LUAC_DRIVER_ARGEXPAND_H
#define LUAC_DRIVER_ARGEXPAND_H

/* Scan argv and, for every argument that starts with '@', replace it with
** the tokens read out of the referenced file. Returns a newly allocated
** argv (heap-owned; caller frees with LcArg_FreeExpanded), with `*out_argc`
** set to the new count. Every returned entry is a heap-owned string. On
** any I/O error, prints a message to stderr and returns NULL.
**
** When no argv element starts with '@', still allocates a fresh copy (the
** caller can free unconditionally). */
char **LcArg_Expand( int argc, char **argv, int *out_argc );

/* Free an argv returned by LcArg_Expand. Safe on NULL. */
void LcArg_FreeExpanded( int argc, char **argv );

#endif /* LUAC_DRIVER_ARGEXPAND_H */
