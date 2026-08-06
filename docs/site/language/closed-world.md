# closed world

clua compiles the whole program at once, and it needs the whole program to
be visible before code generation starts. this property is called the
closed-world assumption. it is the single biggest difference between clua
and a stock lua runtime, and it is the reason the compiler can produce a
static exe with no interpreter inside it.

## what closed world means

- every `require` call must use a string literal, so the compiler can walk
  the import graph statically and bundle the transitive modules into the
  output.
- there is no way to introduce new code at run time. `load`, `loadstring`,
  and `dofile` would need a compiler embedded in every output binary; they
  do not exist in the emitted programs, and calling them is a compile
  error.
- `string.dump` cannot round trip because there is no bytecode inside the
  compiled exe to serialise. it is also a compile error.
- the differential oracle enforces that a compiled program produces the
  same bytes on stdout as the reference interpreter for every test. the
  closed-world subset is exactly the subset the oracle can match.

## what compile errors look like

using a banned construct produces a hard error from the front end with the
file, line, and a short explanation. for example, calling `load`:

```lua
-- forbidden.lua
local f = load("print('hi')")
f()
```

`clua check forbidden.lua` prints something like:

```
forbidden.lua:2: error: 'load' is not available in closed-world lua
    because it would require shipping a compiler in the output binary.
    hint: put the code in a separate .lua file and use `require`.
```

the same shape applies to `loadstring`, `dofile`, `string.dump`, and to
`require` calls with a non-literal argument.

## why this trade is worth it

with the whole program in view, the compiler can:

- link only the standard library modules a program actually uses. a
  program that never mentions `debug` does not carry the debug interpreter.
- prove that specific locals are always integers or floats, and drop the
  tag checks in tight loops.
- keep proven-int and proven-float locals in registers across loop regions.
- devirtualise calls to local helper functions when the argument types
  match a proved signature.

none of these are safe under a runtime that lets `load` introduce new code
mid-execution.
