# CLua concurrency, size, speed, DX, and Windows stability audit

Date: 2026-07-25  
Reviewers: Codex and Claude Code  
Scope: compiler, optimizer, code generator, internal linker, build system,
Rover package manager, and Windows behavior.

## Executive conclusion

CLua has a strong behavioral baseline: the complete suite passed with
677 passes, 0 failures, 5 skips, 0 XFAIL, and 0 XPASS. The highest-value next
step is not to put every compiler phase on a thread. The pipeline has necessary
barriers, and current code generation contains mutable globals that make naive
threading unsafe.

The recommended target is a deterministic dependency scheduler:

1. parallel work across independent modules/functions;
2. explicit barriers for interprocedural analysis and final layout;
3. overlap runtime-archive loading with front-end/codegen work;
4. immutable caches and transactional output;
5. bounded job counts with deterministic merge order.

Before adding workers, fix the verifier, package-store transactions, build
dependency tracking, and codegen context isolation.

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

### 3. Make Rover installs transactional and cross-process safe

`rover/src/rover.lua` uses predictable staging paths such as
`%TEMP%\rover-fetch\<name>\<version>`, deletes them before use, writes directly
into the global store, and updates manifests/locks without a lock or atomic
rename (around lines 940–987 and 1231 onward).

Two Rover processes can delete each other's downloads, observe partial trees,
overwrite manifests, or produce a lock that describes different bytes.

Required design:

- random per-operation staging directories;
- per-package/version named locks with bounded waits and owner diagnostics;
- download + verify entirely in staging;
- atomic directory publish/rename;
- atomic lock/manifest writes (`temp`, flush, replace);
- immutable version directories;
- recovery/cleanup of abandoned staging by age.

### 4. Do not let one project's GC/delete break other projects

`rover remove` deletes the package's entire global-store directory.
`rover gc` protects only the current project's lock and the latest installed
version. Another project's pinned version can therefore be deleted.

Use a content-addressed immutable store plus project links/metadata. GC must
either scan a durable global lease/reference database or be explicitly
conservative. `remove` should change the current project manifest/lock, not
delete shared content immediately.

### 5. Make output publication atomic

The internal linker opens the final output path with `fopen(..., "wb")` and
writes it directly (`clua/src/link/pe_emit.c`, around lines 1900–1903).
Interrupted builds, concurrent builds to one path, OneDrive sync, indexers, and
antivirus can observe or retain a partial executable.

Write beside the target under a unique name, flush and close it, then use a
Windows atomic replace/rename. Report sharing violations with the owning path
and retry only a small bounded set of transient errors.

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

## Rover-specific correctness and security gaps

- The flat “latest” copy is updated with non-recursive `xcopy` and is not
  cleared first. Nested files may be omitted and files removed in a newer
  version may remain stale. Publish a complete staged tree atomically.
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
- Compiler-side lock lookup reads a fixed 32 KB buffer; large lockfiles can be
  truncated. Parse the complete lockfile with the same strict parser/schema.

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

1. Verifier + codegen context isolation + deterministic IDs.
2. Atomic compiler output and Rover store/lock transactions.
3. Build dependency tracking and parallel build-system jobs.
4. Precise feature/library-use analysis for the immediate size reduction.
5. `-Oz` lowering: imm32 helper args, selective prologues, outlined slow paths.
6. Rover solve/fetch/verify/install phase split with bounded concurrency.
7. Parallel compiler local phases and archive-load overlap.
8. Incremental cache/build-server mode.
9. UTF-16 long-path/process/filesystem layer and full Windows fault matrix.

Each slice must retain byte-identical oracle behavior, deterministic output
across job counts, and a green full suite.
