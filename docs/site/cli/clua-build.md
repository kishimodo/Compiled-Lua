# clua build

compiles a lua 5.4 source program to a native x64 pe executable.

## syntax

```
clua build <main.lua> [options]
```

`clua <main.lua>` (with no subcommand) is a shortcut for `clua build
<main.lua>` when the argument ends in `.lua`.

## parameters

**main.lua**

path to the top-level lua source file. every module reachable from this
file through `require "literal"` calls is bundled into the output. paths
may be relative or absolute; the compiler resolves modules relative to
this file.

**-o out.exe**

output path for the exe. if omitted, the compiler derives the output
name from the input by stripping the directory and replacing the `.lua`
extension with `.exe`, then writing to the current directory.

**-O0 | -O1 | -O2 | -O3**

optimization level. default is `-O2`. what each level does today:

- `-O0`: no optimizer passes. faithful boxed baseline; easy to debug.
- `-O1`: type inference, tag-check elision, integer forloop, loop
  register residency, and interprocedural type propagation.
- `-O2`: the same bytes as `-O1` today. the passes gated on `-O2` are
  stubs. the default is `-O2` so a future release that implements those
  passes does not need a flag change.
- `-O3`: `-O2` plus scalar replacement of non-escaping constant-key
  tables. real, but narrow surface.

`-Os` and `-Oz` are rejected, not silently accepted.

**-L pkg** (or **--link pkg**)

force the linker to include a package by name, even if the reachability
scan did not pull it in. useful when a c package is referenced only
through the ffi. may be given multiple times.

**--keep-temps**

keep the intermediate coff object file after the link.

**--shared-rt**

link against `clua-rt.dll` instead of the static runtime archives. the
resulting exe is about thirty kilobytes but depends on `clua-rt.dll`
being beside it (or on `PATH`) at run time.

**--ld=internal**

force the built-in coff to pe64 linker. this is the default when the
sysroot ships next to `clua.exe`.

**--ld=gcc**

force the mingw gcc/ld link. requires a mingw `gcc` on the path or in
`CLUA_GCC`.

**--no-gc-sections-internal**

disable the built-in linker's dead-code sweep. the resulting exe is
larger. use this only when debugging the linker.

## return codes

- `0`: build succeeded, the exe is on disk.
- `1`: internal error (out of memory, io failure during link).
- `2`: argument parse error, or a front-end / closed-world error in the
  source.

## examples

compile with defaults:

```
clua build main.lua
```

compile to a specific path with maximum optimization:

```
clua build src\main.lua -o dist\app.exe -O3
```

link a package the reachability scan cannot find:

```
clua build main.lua -L ffi -L mypkg
```

use the shared runtime for a smaller exe:

```
clua build main.lua --shared-rt
```

## remarks

the compiler finds its runtime libraries relative to `clua.exe`. moving
the exe out of its toolchain directory will break the build unless
`CLUA_HOME` is set to point at the toolchain root.

## related commands

- [clua run](clua-run.md)
- [clua check](clua-check.md)
- [clua version](clua-version.md)
