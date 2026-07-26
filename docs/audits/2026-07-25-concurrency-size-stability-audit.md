# CLua concurrency, size, speed, DX, and Windows stability audit

Date: 2026-07-25  
Reviewers: Codex and Claude Code  
Scope: compiler, optimizer, code generator, internal linker, build system,
Rover package manager, and Windows behavior.

## Executive conclusion

CLua has a broad behavioral suite, but its original 677-pass result was not
initially load-bearing evidence: the runner could classify a crashing test as
a skip and accept empty output. The harness now fails closed, checks its own
classifier, and has revalidated the suite. The highest-value next step is not
to put every compiler phase on a thread. The pipeline has necessary barriers,
and current code generation contains mutable globals that make naive threading
unsafe.

The recommended target is a deterministic dependency scheduler:

1. parallel work across independent modules/functions;
2. explicit barriers for interprocedural analysis and final layout;
3. overlap runtime-archive loading with front-end/codegen work;
4. immutable caches and transactional output;
5. bounded job counts with deterministic merge order.

Before adding workers, fix the verifier, package-store transactions, build
dependency tracking, and codegen context isolation.

## Joint implementation status

Codex and Claude Code independently reviewed the same tree, exchanged findings
through the optional local MCP mailbox, and implemented separate slices in
isolated Git worktrees. The following issues found during that review are fixed
on `codex/concurrency-size-stability`:

- compiler outputs are staged beside the destination, flushed, and atomically
  replaced with bounded Windows sharing-violation retries;
- the test harness fails on crashes, empty output, missing watchdog protection,
  and invalid skip classification;
- Rover uses private staging, per-package cross-process locks, immutable
  version directories, atomic metadata replacement, rollback, and recursive
  flat-view refresh;
- Rover rejects corrupt locks instead of silently discarding pins, verifies
  signed remote indexes before selection, and hashes version-shaped package
  directories correctly;
- compiler and interpreter lockfile resolution reject malicious version path
  segments, and the compiler no longer truncates lockfiles at 32 KB;
- `OP_SELF` preserves Lua 5.4's constant/register `k` bit, covered by a
  greater-than-255-constants conformance case at every optimization level;
- the internal linker validates relocation widths/ranges and no longer emits a
  64-bit base relocation over an `ADDR32` patch site;
- build entry scripts quote their workspace root for OneDrive and other paths
  containing spaces.

The transactional Rover work deliberately does not claim power-loss durability
without an OS-level directory flush, whole-directory atomicity for the legacy
flat compatibility view, or safe global garbage collection across unrelated
projects. Those require the content-addressed/reference-tracked store design
described below.

Final verification on this branch:

- complete fail-closed suite: 682 pass, 0 fail, 5 expected skips, 0 XFAIL,
  0 XPASS;
- differential fuzz smoke: 55 seeds across O1/O2/O3, with zero divergence and
  zero oracle failures;
- concurrent compiler stress: 16 simultaneous builds (8 sharing one output and
  8 using distinct outputs), all exited zero; all 9 published executables were
  valid, produced `ok 300`, and had one identical SHA-256;
- two sequential builds with the same invocation produced identical SHA-256
  output.

## Linker index: measured result and honest limits (implemented)

Delivery item 3 below — replacing the internal linker's repeated linear
symbol/contribution scans with indexed lookups — landed as `092122b` and was
independently cross-reviewed on `claude/final-integration`.

What the commit does: `gsym_find` now probes an open-addressed FNV-1a table
whose slots hold *symbol indexes* (encoded `index + 1`, so `0` is the empty
sentinel) rather than `GSym *`, which is what makes it safe against the
`realloc` inside `gsym_intern`. The table doubles from 512 whenever the load
factor would reach 0.7, so a probe sequence can never run full. The
`(object, section)` to contribution lookup in `sym_rva` and `reloc_target_rva`
reuses the existing `GcMap`, which is now owned by the `Linker` and rebuilt at
the only two points that mutate the contribution array: after
`collect_contribs` and after `layout_sections`' insertion sort.

Cross-review conclusions:

- the index is equivalent to the scan it replaces, because `collect_contribs`
  emits at most one contribution per `(object, section)`, so `gc_map_get`'s
  unique answer is exactly the old "first non-dropped linear match", and the
  dropped-COMDAT fallthrough is preserved in both callers;
- `gc_sections` only flips the `dropped` flag, which the map does not key on,
  so no third rebuild point exists;
- the commit incidentally fixes a latent allocation bug: the old
  `gsym_intern` bumped `nsyms` and then assigned `_strdup(name)`, so an
  allocation failure left a `NULL` name that the next `gsym_find` would
  `strcmp`. The name is now duplicated before the array grows and freed if the
  grow fails.

Measured on the audit machine, warm, one unmeasured warm-up run followed by
measured runs, comparing two `clua.exe` binaries built from identical objects
differing only in `pe_emit.o`:

| Build | Parent `7f02bd3` median | `092122b` median | Delta |
|---|---:|---:|---:|
| `rover.lua -O1` (n=9) | 206 ms | 202 ms | -4 ms (-1.9%) |
| `print("hello")` `-O1` (n=11) | 173 ms | 165 ms | -8 ms (-4.6%) |

Output is byte-identical across the change: `rover.exe` produced by the parent,
by `092122b`, and by a repeat run of `092122b` all share SHA-256
`d9860cac8ba2250a36d8adca4f11fb6e7874973f39dcaa90d81fe1889b805c2f`.

Honest limitation — the win is real but small, and the earlier "quadratic
internal-linker paths" framing overstated the present cost. `CLUA_GC_DEBUG`
reports only 994 contributions (656 kept, 338 dropped) for a `hello` build, so
the replaced scans were over roughly a thousand entries, not a pathological
set. The remaining ~165 ms of a link-dominated build is spent parsing the
13.9 MB CRT sysroot and runtime archives and writing the PE, not resolving
symbols. `092122b` removes the scaling cliff and is a prerequisite for larger
inputs and for any future linker threading, but it is not the source of a large
wall-clock win today. Delivery item 10 (caching and overlapping archive input)
is now the higher-value linker performance target, and it is unmeasured.

Suite result on `claude/final-integration` at `092122b` plus the new test:
684 pass, 1 fail, 4 skips, 0 XFAIL, 0 XPASS. The single failure is
`test-pkgmgr-foreign`, and it is an environment fault rather than a code
regression: `build\build.bat` prepends the GnuWin32 tools to `PATH`, so GNU
`tar.exe` shadows `C:\Windows\System32\tar.exe` and then reads the `C:\...`
destination as a remote host. Re-running the same test with System32 ahead of
GnuWin32 passes. The suite is therefore effectively 685 pass / 0 fail / 4 skip,
but the runner should pin the system `tar` rather than leaving this trap in
place.

Regression cover: `tests/unit/test_lc_link_symindex.c` links a synthetic COFF
carrying 4000 `EXTERNAL` symbols, which forces five rehash rounds with real
probe collisions, asserts the one genuine `REL32` still resolves through the
grown table, and asserts two independent links of the same input are
byte-identical so the hash iteration order cannot leak into output. It skips
cleanly when the sysroot is absent. Both benchmark numbers above are wall-clock
medians from a single machine under normal desktop load; they are not a
controlled benchmark environment and the run-to-run spread (roughly +-25 ms)
is wider than the measured delta for the Rover case.

## Measured baseline

Warm local runs compiling `rover/src/rover.lua` with the internal linker:

| Configuration | Median/typical wall time | Output size |
|---|---:|---:|
| `clua check` | about 14 ms | n/a |
| `-O0` | about 177 ms | 675,840 bytes |
| `-O1` | about 172 ms | 689,152 bytes |
| `-O2` | about 170–230 ms | 689,152 bytes |
| `-O3` | about 207 ms | 689,152 bytes |

The emitted Rover user object was 538,070 bytes:

- native `.text`: `0x6507a` bytes;
- Proto blob: `0x13d38` bytes;
- the top-level `luac_fn_0` alone: `0x6507a` bytes.

The front-end check is a small fraction of total warm build time. Link/archive
processing and native code volume are therefore higher-value targets than
parser-only parallelism.

False-positive feature scans have a directly measured size cost:

| Source | Output size |
|---|---:|
| `print("hello")` | 137,216 bytes |
| `print("bit")` | 173,056 bytes |
| `print("debug")` | 201,216 bytes |
| harmless `"string"`, `"table"`, `"math"`, `"io"`, `"os"`, or `"utf8"` literal | 184,320 bytes |

A data string currently looks like a feature/library use. This can add roughly
36–64 KB to a tiny executable and can disable optimizer proofs.

## P0: correctness and concurrency prerequisites

### 1. Make code generation reentrant

`clua/src/codegen/codegen.c` stores per-compilation/per-function state in
`g_lc_opt_level`, `g_res_fn_xmm`, `g_res_regions`, `g_res_n`, and `g_res_cur`
(around lines 54, 79, and 310–312). `lc_codegen` mutates that state while
iterating functions (around line 1953).

Parallel function codegen would race immediately. Move all mutable values into
an `LcCodegenContext`, with a child function context, and pass it through
lowering helpers. No worker pool should land before ThreadSanitizer-style or
stress coverage proves the new context isolated.

### 2. Implement the optimizer verifier

`lc_module_verify` in `clua/src/ir/ir.c` returns `true` unconditionally.
`LcPassConfig.verify_each` is declared and the driver sets it to true, but
`lc_optimize` never invokes it. This makes a safety control appear active when
it is not.

Implement structural checks appropriate to memory-form IR now, add stronger
SSA checks if/when SSA exists, and invoke verification after every mutating
pass in debug/test builds and at the final boundary in release builds.

### 3. Make Rover installs transactional and cross-process safe (implemented)

The original `rover/src/rover.lua` used predictable staging paths such as
`%TEMP%\rover-fetch\<name>\<version>`, deleted them before use, wrote directly
into the global store, and updated manifests/locks without a lock or atomic
rename (around lines 940–987 and 1231 onward).

Two Rover processes could delete each other's downloads, observe partial trees,
overwrite manifests, or produce a lock that describes different bytes.

Implemented design:

- random per-operation staging directories;
- per-package/version named locks with bounded waits and owner diagnostics;
- download + verify entirely in staging;
- atomic directory publish/rename;
- atomic lock/manifest writes (`temp`, replace);
- immutable version directories;
- recovery/cleanup of abandoned staging by age.

The implementation also verifies complete staged trees, rolls back a failed
version-directory replacement, and prevents a retiring lock owner from deleting
a successor's lock. Remaining durability and legacy-flat-view limits are listed
in the joint status above.

### 4. Do not let one project's GC/delete break other projects

`rover remove` deletes the package's entire global-store directory.
`rover gc` protects only the current project's lock and the latest installed
version. Another project's pinned version can therefore be deleted.

Use a content-addressed immutable store plus project links/metadata. GC must
either scan a durable global lease/reference database or be explicitly
conservative. `remove` should change the current project manifest/lock, not
delete shared content immediately.

### 5. Make output publication atomic (implemented)

The link orchestrator now gives the emitter a unique sibling temporary path,
flushes and closes it, calls `FlushFileBuffers`, and publishes with
`MoveFileExA(REPLACE_EXISTING | WRITE_THROUGH)`. Bounded retry covers sharing,
lock, and access-denied errors commonly caused by antivirus, indexers, and sync
clients. The path guard reserves space for the generated suffix.

## P1: highest-return size and speed work

### 6. Replace literal scans with bytecode use analysis

`lc_module_uses_debug`, `lc_module_uses_ffi`, and `lc_module_used_libs` treat
matching string constants as actual feature use. Inspect `GETTABUP`/global
access and resolved `require` sites instead. Preserve a conservative fallback
only for real environment materialization/dynamic lookup.

This is the fastest demonstrated binary-size win: up to about 64 KB on a tiny
program, with no runtime tradeoff.

### 7. Add a size-oriented lowering mode

`LcCg_EmitHelperCall3` emits three 64-bit immediate moves even though operands
are normally small Lua bytecode fields. Use 32-bit argument moves when legal.
Also:

- save only callee-saved registers actually used by a function;
- outline duplicated slow paths;
- consider compact helper thunks for cold operations;
- add `-Os`/`-Oz` separately from execution-speed `-O` levels;
- measure every change against runtime speed and differential fidelity.

`-O1+` currently grows Rover by about 13 KB versus `-O0`, so users need a clear
speed/size choice.

### 8. Hoist stable per-function runtime pointers

Constant lowering repeatedly walks `L -> ci -> closure -> Proto -> k`.
Hoist stable `Proto`/constant-table state in the function prologue when the
runtime invariants prove it safe. This reduces both code bytes and runtime
loads. Add defensive constant-index validation at lift/codegen boundaries.

### 9. Compress or strip Proto metadata deliberately

Rover's Proto blob is about 81 KB and includes bytecode, line tables, local
names, and upvalue names. Preserve the default developer-grade error fidelity,
but add explicit profiles:

- default debug metadata;
- `-gline` line-only metadata;
- `-g0` stripped release metadata;
- optional compressed blob with bounded decompression and corruption checks.

Do not silently remove metadata from the default build.

### 10. Cache and overlap linker inputs

The internal linker repeatedly parses stable runtime, Lua, and CRT archives.
Build a validated index/cache keyed by archive identity/content. During a
compile, start archive-map loading while front-end/lift/codegen work proceeds;
the final symbol-resolution/layout barrier remains sequential and deterministic.

A long-lived `clua watch`/build-server mode can retain validated read-only
archive indices and source cache entries, avoiding process startup and repeated
archive parsing.

## Safe concurrency architecture

### Compiler

Use a bounded work-stealing pool, defaulting to logical CPUs but capped by
memory pressure and exposed through `--jobs N` / `CLUA_JOBS`.

Suggested dependency graph:

1. discover the entry module;
2. parse dependency frontiers in parallel using one isolated Lua state per job;
3. deterministically sort/assign module and function IDs;
4. lift independent functions in parallel into per-job arenas;
5. run local analyses in parallel;
6. barrier: merge summaries and run interprocedural propagation to a fixpoint;
7. run final local specialization in parallel;
8. generate functions in parallel using isolated contexts;
9. serialize per-function Proto records in parallel, concatenate by stable ID;
10. write COFF deterministically;
11. while steps 4–10 run, preload/cache runtime archive indices;
12. barrier: resolve, lay out, relocate, and atomically publish the PE.

Not every phase can run simultaneously. The promise should be “all independent
work runs concurrently,” with deterministic barriers where outputs depend on
prior results.

### Rover

Separate resolution from mutation:

1. load/cache registry metadata once;
2. solve the complete graph without installing;
3. sort the final immutable plan;
4. download independent artifacts concurrently with host and global limits;
5. verify hashes/signatures concurrently;
6. acquire ordered package locks to avoid deadlock;
7. atomically publish immutable store entries;
8. atomically replace the project lockfile.

Use cancellation, timeouts, retry policy with jitter, progress events, and
structured errors. Never run arbitrary unbounded `curl` processes per file.

## Windows stability and developer experience

### Build system

- Build wrappers currently invoke Make serially. Add a supported `-j` default
  and test parallel clean builds.
- Add compiler-generated header dependencies (`-MMD -MP`) instead of requiring
  manual object deletion after header edits.
- Remove developer-machine path defaults from build scripts; discover tools
  from PATH, Visual Studio/MinGW installations, or an explicit toolchain file.
- Replace wildcard-linked backend object lists with source-derived explicit
  lists so new/stale objects cannot silently change the binary.

### Paths and process execution

- Replace fixed 400/512/1024-byte path buffers and ANSI-only file APIs with a
  centralized Windows UTF-16/long-path layer.
- Replace `system`, `cmd /c`, `dir`, `xcopy`, and shell-built commands with
  direct Win32/filesystem/process APIs.
- Handle spaces, Unicode, reserved device names, reparse points, case folding,
  OneDrive placeholders, sharing violations, and paths beyond `MAX_PATH`.
- Add tests rooted in a Unicode path, a path with spaces/metacharacters, a
  long path, and a OneDrive-like directory.

### CLI behavior

- Validate optimization levels strictly (`O0` through `O3` or the new `Os/Oz`).
- Error rather than silently dropping force-link arguments beyond the fixed
  capacity.
- Add `--timings`, `--jobs`, `--json`, and a verbose phase/progress mode.
- `clua init` currently adds `rover.lock` to `.gitignore`, conflicting with
  reproducible pinned installs. Lockfiles should normally be committed.
- `clua run --shared-rt` should locate/stage the required runtime DLL
  automatically or emit a precise remediation.

## Cross-review refinements

The independent second pass changed the priority of several performance items:

- `emit_store_savedpc` emits roughly 30 bytes before most potentially throwing
  bytecodes, repeatedly walking stable `L -> ci -> closure -> Proto -> code`
  state. Hoisting that state can remove more native code than literal-scan
  cleanup alone.
- `gsym_find` and relocation target lookup repeatedly scan global symbols and
  contributions, making important internal-linker paths quadratic. Indexed
  lookup should precede linker threading.
- `-O2` and `-O3` currently produce the same Rover size as `-O1`; the measured
  `-O1` growth is primarily multi-arm code generation rather than meaningful
  higher-level optimization. A separate `-Oz` contract is preferable to
  promising that all `-O` levels reduce size.
- precise feature-use analysis remains correct work, but the string library is
  also conservatively enabled by common table/field opcodes. Its isolated size
  benefit must therefore be remeasured after each gate is made precise.

## Rover-specific correctness and security gaps

- The flat compatibility view is now recursively refreshed and stale files are
  removed, but its per-file publication cannot become whole-directory atomic
  without changing the current store layout.
- Remote index and package files are fetched serially; the same index may be
  fetched repeatedly. Cache metadata per command and download with bounded
  concurrency.
- Optional HMAC metadata is a shared-secret integrity mechanism, not public-key
  publisher authentication. Move toward signed, expiring metadata with key
  rotation and rollback protection.
- Foreign GitHub installs follow branch heads and cannot be reproducibly
  refetched from the lock. Record and fetch an immutable commit/tree digest.
- Add size limits, file-count limits, timeouts, and cancellation to remote
  fetch and extraction paths.
- Compiler-side lock lookup now reads the complete lockfile (bounded at 16 MB),
  scopes a version lookup to its package entry, and validates the path segment.

## Test additions required before claiming extreme Windows stability

1. 2–20 concurrent `clua build` processes, same and different output paths.
2. Repeated interruption at every output publication boundary.
3. Parallel Rover install/update/remove/verify/gc against one shared store.
4. Multiple projects pinning different versions while GC/remove runs.
5. Unicode, spaces, metacharacters, long paths, UNC, and OneDrive roots.
6. Antivirus-style sharing violations and delayed file deletion.
7. Determinism: hash outputs across job counts 1, 2, 4, 8, and logical CPU max.
8. Fault injection for OOM, disk full, short write, corrupt archive/index, and
   network timeout.
9. Stress codegen after context isolation and verify every IR boundary.
10. Benchmark gates for compile wall time, peak memory, output bytes, startup,
    and representative runtime kernels.

## Recommended delivery order

1. Correctness/security fixes: `OP_SELF`, lock-version traversal, relocation
   validation, fail-closed tests (implemented).
2. Atomic compiler output and Rover store/lock transactions (implemented).
3. Replace the linker's repeated linear symbol/contribution scans with indexed
   lookups (implemented, `092122b`). The warm build is link-dominated, but the
   measured gain was only 1.9% on Rover and 4.6% on a tiny program; see the
   linker-index section above for why, and prefer item 10 for the next linker
   performance work.
4. Hoist stable `CallInfo`/`Proto` state used by `emit_store_savedpc`; this is
   the largest code-volume opportunity identified by the second review.
5. Add golden byte-identity/reproducibility gates, then implement `-Oz`
   lowering: imm32 helper arguments, selective prologues, and outlined slow
   paths. Make `-O2`/`-O3` behavior honest or implement their advertised work.
6. Implement the optimizer verifier, codegen context isolation, deterministic
   IDs, build dependency tracking, and safe parallel build-system jobs.
7. Split Rover solve/fetch/verify/install, add a real backtracking solver, and
   use bounded concurrent fetch/verification.
8. Parallelize compiler-local work and overlap immutable archive-index loading;
   keep deterministic barriers for layout and publication.
9. Add incremental cache/build-server mode, then the UTF-16
   long-path/process/filesystem layer and complete Windows fault matrix.

Each slice must retain byte-identical oracle behavior, deterministic output
across job counts, and a green full suite.
