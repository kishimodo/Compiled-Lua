-- aot_multimod.lua - multi-module program with enough startup Proto
-- reconstruction volume to complete a GC cycle mid-build: guards
-- AOT-MULTIMOD-001 (unanchored Protos swept during LuacProgram_BuildEntry;
-- fixed by stopping the GC across the build, like upstream f_luaopen).
-- The path prepend serves the interpreter oracle (CWD = repo root); the
-- compiled exe satisfies the require from package.preload.
package.path = "tests\\differential\\?.lua;" .. package.path
local p = require "multimod_payload"
print(p.f1(10))
print(p.f75(20))
print(p.f150(30))
print(p.sum(150))
local ok = pcall(p.f42, 0)
print("callable", ok)
