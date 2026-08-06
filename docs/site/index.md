# clua

clua is an ahead-of-time optimizing compiler for the lua 5.4 language,
targeting windows x64. it takes a lua source tree, links every module it can
prove is reachable at compile time, and emits an ordinary pe executable. the
binary ships as native x64 machine code plus a small runtime library: no
bytecode blob, no in-binary vm, no jit. the compiled program links a runtime
archive the same way a c program links libc.

the compiler is closed world by design. the whole program has to be known
before code generation starts, which is why `load`, `loadstring`, `dofile`,
`string.dump`, and dynamic `require` are compile errors: honouring them would
mean shipping a compiler inside every output binary. in exchange for that
constraint the optimizer can prove things the interpreter cannot, and the
faster paths in the emitted code use those proofs to skip tag checks, keep
proven-int and proven-float locals in registers across loop regions, and drop
the per-iteration helper call from tight integer for loops.

there is no jit anywhere in the tree. clua has exactly two engines: the
compiled native exe, which is the product, and a reference bytecode
interpreter that exists only as the differential test oracle. every compiled
program must match the interpreter byte-for-byte across the whole test
corpus at every optimization level, o0 through o3. this site documents the
compiler, the language subset it accepts, the built-in packages, and the
runtime that keeps the compiled programs faithful to the lua semantics.
