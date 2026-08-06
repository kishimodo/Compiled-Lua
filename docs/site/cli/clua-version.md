# clua version

prints the clua toolchain version string.

## syntax

```
clua version
clua --version
clua -v
```

all three forms are equivalent.

## parameters

none.

## return codes

- `0`: always. the version string is written to stdout.

## examples

```
clua version
```

sample output:

```
clua 0.3.0-beta.2 (lua 5.4, x86-64 windows)
```

## remarks

scripts that need to gate on the toolchain version should shell out to
`clua version` and parse the first token after `clua `. the version
string follows semver and is the single source of truth for the
toolchain build.

## related commands

- [clua build](clua-build.md)
