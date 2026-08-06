# install

clua ships as a single zip on the github releases page. the zip unpacks into
a self-contained toolchain folder: `clua.exe`, `rover.exe`, a `lib` directory
with the runtime archives and a crt sysroot snapshot, and a short readme.
there is no installer.

## download

grab the latest release archive from the project releases page:

```
https://github.com/kishimodo/Compiled-Lua/releases
```

pick the file named `clua-<version>-windows-x64.zip`.

## extract

unpack the zip anywhere you like. a typical layout after extraction:

```
C:\tools\clua\
    clua.exe
    rover.exe
    lib\
        runtime-aot.a
        sysroot\
    README.md
```

the toolchain finds its runtime libraries by looking beside `clua.exe`, or
by consulting the `CLUA_HOME` environment variable if you set one. moving
the folder as a unit is fine. moving `clua.exe` out of the folder without
setting `CLUA_HOME` is not.

## add to path

open the system properties dialog, edit the `Path` variable for your user,
and add the directory that contains `clua.exe` (for the example above that
is `C:\tools\clua`). open a fresh terminal and check:

```
clua version
```

that should print the version string. if it does not, the path change is
not visible in the terminal yet; close and reopen the terminal or log out
and back in.

## no external toolchain needed

the default build uses the built-in coff to pe64 linker and the shipped
sysroot snapshot. you do not need mingw, msvc, or any other compiler on the
path to build lua programs with clua. gcc is only required if you pass
`--ld=gcc`, `--shared-rt`, or compile a program cold enough to need a full
c front-end.
