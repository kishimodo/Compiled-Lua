/*!
 * @brief
 *  Runtime entry point used by every generated output.exe.
 *  In Plan 1 this is a banner-only stub; Task 13 wires it
 *  to the upstream Lua interpreter against the embedded blob.
 */

#ifndef CLUA_RUNTIME_INIT_H
#define CLUA_RUNTIME_INIT_H

int RuntimeMain( int Argc, char **Argv );

#endif /* CLUA_RUNTIME_INIT_H */
