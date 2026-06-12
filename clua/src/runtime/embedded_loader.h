/*!
 * @brief
 *  Installs an embedded-blob loader into package.searchers[1] so that
 *  require("foo.bar") resolves to a bytecode chunk inside the blob.
 */

#ifndef LUAVM_RUNTIME_EMBEDDED_LOADER_H
#define LUAVM_RUNTIME_EMBEDDED_LOADER_H

#include "lua.h"
#include "runtime/blob_reader.h"

/*!
 * @brief
 *  Register the loader. Stores Reader in the Lua registry under a private key.
 */
void EmbeddedLoader_Install( lua_State *L, PBLOB_READER_T Reader );

#endif /* LUAVM_RUNTIME_EMBEDDED_LOADER_H */
