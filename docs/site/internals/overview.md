# internals overview

placeholder for contributors. the internals section will grow over the
next doc arcs to cover the pieces of the compiler that a contributor
needs to know before touching them.

planned pages:

- ir: shape of the `lc` module, `lc` function, and `lc` block records;
  how the front end lifts lua source to ir.
- pass pipeline: the ordered list of passes in `clua/src/opt/passes.c`,
  which ones are real, which ones are stubs, and what each pass expects
  from the passes before it.
- codegen frame abi: the native prologue, savedpc semantics, why rbp is
  reserved across the backend, and how the lua stack lives on the heap
  behind rdi.
- linker: the coff read, coff write, ar read pipeline, the resolve and
  mark fixpoints, gc sections, and the atomic output publication path.
- runtime: the `rt_` helpers that back the hot path of every compiled
  binary, the closed-world stubs for `load` and friends, and the ffi
  thunk allocator.

for now, the surviving handoff notes and audit documents in the repo
under `docs/` are the source of truth. this section will consolidate
them as they get rewritten in the humanised style.
