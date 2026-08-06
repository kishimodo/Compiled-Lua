# ffi overview

this page is a placeholder. full ffi documentation is a follow-up in the
same doc arc.

the shipped `ffi` package exposes a c type description dsl for declaring
structs, unions, and function signatures, plus helpers for loading windows
dlls and invoking their exports from lua. callbacks let a lua function be
passed to a c api that expects a function pointer; the runtime allocates
executable trampolines on demand under a w-caret-x policy so the writable
and executable views of the same memory never overlap.

the follow-up will cover:

- the c type dsl: primitive types, pointers, arrays, structs, unions,
  function pointers, and how sizes and alignments are computed on
  windows x64.
- loading dlls and resolving exports.
- calling conventions and how the compiler generates the marshalling
  code.
- callbacks and the trampoline allocator.
- lifetime and ownership rules for pointers passed across the boundary.

for now, look at the tests under `tests/ffi/` for concrete examples that
exercise every path the runtime supports today.
