# lua 5.4 support

clua targets lua 5.4 with high fidelity. the reference oracle for every
test is the reference bytecode interpreter, and every compiled program
must match the interpreter byte for byte on stdout.

## what is supported

the full lua 5.4 language and standard library, with the two categories of
exception listed below. everything else works, including:

- all lua 5.4 syntax: numeric for loops, generic for loops, goto and
  labels, integer division, bitwise operators, integer subtype (with 64-bit
  integers), floor division, and the `<close>` and `<const>` attributes.
- metatables and metamethods across every operator, including `__add`,
  `__sub`, `__mul`, `__div`, `__mod`, `__idiv`, `__pow`, `__unm`, `__band`,
  `__bor`, `__bxor`, `__bnot`, `__shl`, `__shr`, `__concat`, `__len`,
  `__eq`, `__lt`, `__le`, `__index`, `__newindex`, `__call`, `__tostring`,
  `__gc`, and `__close`.
- string patterns, format, and the full `string` library.
- the `table` library, including `move`, `pack`, `unpack`, and `sort`.
- the `math` library with the integer and float split from 5.4.
- the `io` library for file and stream io.
- the `os` library for environment, clock, and process operations.
- the `utf8` library.
- the `debug` library, including traceback, hooks, and locals inspection.
- coroutines with full symmetric coroutine semantics.
- the incremental garbage collector, including finalisers and generational
  mode via `collectgarbage`.
- long strings and long comments with any level of `=` signs.

## what is not supported

two categories, both fundamental to the closed-world design.

### dynamic code loading

these functions do not exist in the compiled exe. calling any of them is
a hard compile error:

- `load`
- `loadstring` (deprecated in 5.2, still rejected here)
- `loadfile`
- `dofile`
- `string.dump`
- `require` with a non-literal argument

the reason is the same for all of them: any of these would need a compiler
embedded in the output binary to be sound, which would defeat the point of
building a static exe.

### dynamic require

`require` with a string literal is supported and is the mechanism by which
clua discovers the transitive module graph at compile time. `require`
called with an expression that is not a literal is a compile error. if you
have a table of package names and want to load one of them, structure the
code so the compiler can see every possible name; a lookup table of
already-required modules is the usual answer.

## a note on the standard library modules a program does not use

by default the compiler links only the standard library modules the
program actually references. a program that never touches `debug` does
not carry the debug library; a program that never touches `io` does not
carry the io library. this is a size win, and it is not something the
programmer has to opt into: the compiler discovers reachability during
the front-end scan.
