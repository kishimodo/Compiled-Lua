CLua — Lua 5.4, ahead-of-time compiled to native Windows x64
=============================================================

Contents
  clua.exe     the toolchain: compile Lua 5.4 to a native .exe
  rover.exe    the package manager (itself a CLua-compiled program)
  lib\         the runtime libraries clua links into your programs

Quick start
  clua build app.lua            -> app.exe   (optimized, -O1)
  clua run app.lua -- arg1      compile + run in one step
  clua check app.lua            front-end + closed-world check only
  clua help                     all options

Shared runtime (optional)
  clua build app.lua --shared-rt links a ~30 KB exe against lib\clua-rt.dll
  instead of the static runtime — handy when shipping many small tools.
  Copy clua-rt.dll next to your exe (or put it on PATH). The default build
  stays fully static and single-file.

  rover init                    start a project (luavm.toml)
  rover add <package>           add a dependency
  rover install                 reproducible install from the lockfile

Requirements
  A MinGW-w64 gcc (x86_64-w64-mingw32-gcc) on PATH for the final native
  link — everything else happens inside clua.exe. Override the linker
  driver with the CLUA_GCC environment variable if yours is named
  differently.

Layout rules
  clua.exe finds lib\ next to itself (or under %CLUA_HOME%). Keep this
  directory together, or set CLUA_HOME to its location and put clua.exe
  on PATH.

Closed world
  load / loadstring / dofile / string.dump / dynamic require are compile
  errors: a CLua program ships as machine code only — no bytecode, no
  embedded compiler, no JIT.
