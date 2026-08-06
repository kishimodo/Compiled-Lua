# rover init

rover is the package manager for clua projects and ships as a separate
binary. `rover.exe` lives in the same toolchain folder as `clua.exe` and
is itself a clua-compiled program. this page is a stub reference for
`rover init`; the authoritative source of truth for rover flags lives in
the rover repository at `github.com/kishimodo/Rover`.

## syntax

```
rover init [name]
```

## parameters

**name**

optional project name. used as the `[project].name` field in the
generated `rover.toml`. if omitted, rover derives the name from the
current directory.

## return codes

- `0`: the scaffold ran.
- non-zero on io error or an invalid name.

## examples

initialise a new rover project in the current directory:

```
mkdir my-app
cd my-app
rover init
```

## remarks

rover is documented in its own repository. this page exists so the cli
reference index in this site is not misleading about what commands are
available in the shipped toolchain. see the rover repository for the
full command list, lockfile format, and registry protocol:

```
https://github.com/kishimodo/Rover
```

`clua init` and `rover init` are similar but not identical. `clua init`
also writes a runnable `main.lua` and a `.gitignore` so the project can
be built and run right after scaffolding.

## related commands

- [clua init](clua-init.md)
