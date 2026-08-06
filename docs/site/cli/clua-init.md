# clua init

scaffolds a new project in the current directory. writes a runnable
`main.lua`, a `rover.toml` manifest for the package manager, and a
`.gitignore`. existing files are never overwritten.

## syntax

```
clua init [name]
```

## parameters

**name**

optional project name. used as the `[project].name` field in
`rover.toml`. if omitted, the name of the current directory is used, or
`my-project` if the directory name cannot be determined.

## return codes

- `0`: the scaffold ran. any file that already existed was kept as is.
- other non-zero on internal error.

## examples

scaffold in the current directory, using the directory name:

```
mkdir hello
cd hello
clua init
```

scaffold with an explicit project name:

```
clua init widgets
```

## remarks

the generated `main.lua` prints a greeting so the project is runnable
immediately with `clua run main.lua`.

the generated `rover.toml` is empty of dependencies; add them with
`rover add <name>` or by editing the `[dependencies]` table.

the generated `.gitignore` excludes `*.exe` and `rover.lock`.

no file is overwritten. if `main.lua` already exists, the existing file
is kept and a note is printed.

## related commands

- [rover init](rover-init.md)
- [clua build](clua-build.md)
