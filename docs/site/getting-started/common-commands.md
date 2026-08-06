# common commands

the four commands you will use every day. every one of them has its own
reference page under the cli section with the full flag list, exit codes,
and examples.

## build

compile a program to a native exe.

```
clua build main.lua
clua build main.lua -o out\app.exe
clua build main.lua -O3
```

the default optimization level is `-O2`. today `-O2` emits the same bytes as
`-O1`; the passes that would make it different are stubs. `-O0` is the
boxed, unoptimised baseline that the differential oracle mirrors. `-O3`
enables scalar replacement of non-escaping constant-key tables.

## run

compile and execute in one step. the intermediate exe lives in the temp
directory and is removed on exit.

```
clua run main.lua
clua run main.lua -- arg1 arg2
```

## check

run only the front end and the closed-world check. no code is generated,
no exe is written. this is the fastest way to see whether a change still
parses.

```
clua check main.lua
```

## help

print the top-level usage message with every command and every build flag.

```
clua help
clua version
```

`clua version` prints the version string on its own, which is what a script
should shell out to when it wants to make sure the toolchain on the path is
recent enough.
