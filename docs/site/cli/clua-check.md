# clua check

runs the front end and the closed-world check on a source program without
generating code or writing an exe. this is the fastest way to see whether a
program parses and can be compiled.

## syntax

```
clua check <main.lua>
```

## parameters

**main.lua**

path to the top-level lua source file. every module reachable through
`require "literal"` is checked, exactly as `clua build` would check them.

## return codes

- `0`: the source parses, resolves, and passes the closed-world gate.
- `1`: internal error.
- `2`: a front-end or closed-world error was reported.

## examples

check a single file:

```
clua check main.lua
```

use in an editor save hook to surface errors quickly:

```
clua check %f
```

## remarks

no code is generated and no exe is written. an editor plugin can call
this on every save without producing build artefacts.

## related commands

- [clua build](clua-build.md)
- [clua run](clua-run.md)
