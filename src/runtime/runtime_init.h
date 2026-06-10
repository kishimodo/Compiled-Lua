/*!
 * @brief
 *  Runtime entry point used by every generated output.exe.
 *  In Plan 1 this is a banner-only stub; Task 13 wires it
 *  to the upstream Lua interpreter against the embedded blob.
 */

#ifndef LUAVM_RUNTIME_INIT_H
#define LUAVM_RUNTIME_INIT_H

int RuntimeMain( int Argc, char **Argv );

#endif /* LUAVM_RUNTIME_INIT_H */
