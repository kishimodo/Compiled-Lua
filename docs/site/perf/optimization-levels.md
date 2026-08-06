# optimization levels

clua accepts `-O0`, `-O1`, `-O2`, and `-O3`. this page describes what each
level does today, taken from the help output of the compiler. `-Os` and
`-Oz` are rejected, not silently accepted.

the default level is `-O2`.

## -O0

no optimizer passes. every operation goes through the faithful boxed
baseline the reference interpreter mirrors. this level is the easiest to
debug and it is what the differential oracle runs against for byte
identity checks at the other levels.

## -O1

type inference plus interprocedural type propagation, plus the typed
codegen fast paths:

- tag-check elision on operands that a forward dataflow proof shows to
  be integer or float on every path.
- integer for loop: proven-integral loops drop the per-iteration helper
  call, the step tag check, and the float arm.
- loop register residency: proven-int slots live in the callee-saved
  general-purpose registers and proven-float slots live in the
  callee-saved xmm registers across qualified loop regions.

this level costs about fourteen kilobytes over `-O0` on hello world and
gives most of the measurable speed win the current compiler can deliver.

## -O2

today `-O2` emits the same bytes as `-O1`. the three passes this level
was designed to gate (`monomorphize`, `ip_devirt`, `dead_global`) are
stubs. the default is `-O2` so a future release that implements those
passes does not require a flag change from every user.

the plan for a real `-O2` moves the inline table fast paths behind this
level. see the plan document at the repo root for the details.

## -O3

`-O2` plus scalar replacement of non-escaping constant-key tables. the
pass is real, but the surface is narrow: real programs rarely hold a
short-lived constant-key table that never escapes. useful when it fires;
usually the same bytes as `-O2` on production code.

## honest performance numbers

on tight numeric kernels versus the boxed `-O0` baseline:

- integer loop: about 17x, at roughly 3.7 cycles per iteration.
- float accumulator: about 14x, at the addsd latency floor.
- branchy integer kernel: 7x or better.

on general lua code the ceiling is 1.5 to 3x over the interpreter. the
kind of code that gets close to c is the annotated numeric subset above.
table field read and write is still around 0.80x the interpreter today;
the inline table fast paths in the plan are what closes that gap.
