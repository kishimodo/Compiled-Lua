# clua run

compiles a lua source program and executes it in one step. the intermediate
exe is written to the temp directory and removed after the program exits.

## syntax

```
clua run <main.lua> [build options] [-- <program args...>]
```

## parameters

**main.lua**

path to the top-level lua source file. same rules as `clua build`.

**build options**

any option accepted by `clua build` may appear before the `--` separator.
see the [clua build](clua-build.md) page for the full list. `-o` is
accepted but ignored: `clua run` always writes to a temp file it controls.

**--**

separator between clua flags and program arguments. everything after `--`
is passed to the program as `arg[1]`, `arg[2]`, and so on.

## return codes

- exit code of the compiled program if the compile succeeded and the
  program ran to completion.
- `1`: internal error, or the program could not be spawned.
- `2`: argument parse error, or a front-end / closed-world error in the
  source.

## examples

compile and run with defaults:

```
clua run main.lua
```

pass arguments to the program:

```
clua run main.lua -- --input data.txt --verbose
```

run at a specific optimization level:

```
clua run bench.lua -O3 -- 1000000
```

## remarks

`clua run` is the fastest way to iterate on a program during development.
because the temp exe is removed on exit, it does not leave build products
in the working directory.

program stdout appears after the compile banner. flushing between them is
handled by the driver.

## related commands

- [clua build](clua-build.md)
- [clua check](clua-check.md)
