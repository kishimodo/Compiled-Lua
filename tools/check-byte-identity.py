#!/usr/bin/env python3
"""Byte-identity gate for pure refactors of the compiler.

    python tools/check-byte-identity.py before > before.txt
    ... refactor ...
    python tools/check-byte-identity.py after  > after.txt
    diff before.txt after.txt        # must be empty except the label line

Compiles a fixed corpus with the CURRENT build/bin/clua.exe at several -O levels
and prints one SHA-256 per (input, level). A refactor that changes no semantics
must not change a single output byte, which is a far sharper gate than a green
test suite: it catches a reordered emission, a dropped optimization, or a
per-function value that leaked across functions.

The corpus deliberately includes the residency and savedpc differential cases,
because those are the ones that exercise the per-function codegen state
(g_res_* and the savedpc bias) rather than just the common path.

Caveat that matters: byte-identity is blind to leaks and to state that is still
shared but happens to be reset between functions. Pair it with a structural
check, e.g.

    nm build/bin/obj/codegen/codegen.o | grep -E "^[0-9a-f]+ [bBdD] "

which lists the mutable file-scope objects that remain.
"""
from __future__ import annotations

import hashlib
import pathlib
import subprocess
import sys
import tempfile

LEVELS = ("-O0", "-O1", "-O2")

# Inputs chosen to cover the state that per-function codegen keeps: register and
# float residency regions, savedpc bias windows, and a large real program.
CORPUS = (
    ("hello", None),                                     # generated below
    ("rover", "rover/src/rover.lua"),
    ("savedpc", "tests/differential/aot_savedpc_precision.lua"),
    ("residency", "tests/differential/aot_residency.lua"),
    ("residency_flt", "tests/differential/aot_residency_flt.lua"),
    ("residency_obs", "tests/differential/aot_residency_obs.lua"),
)


def main(argv: list[str]) -> int:
    label = argv[1] if len(argv) > 1 else "unlabelled"
    root = pathlib.Path(
        subprocess.run(["git", "rev-parse", "--show-toplevel"],
                       capture_output=True, text=True, check=True).stdout.strip()
    )
    clua = root / "build" / "bin" / "clua.exe"
    if not clua.is_file():
        print(f"{clua} not built", file=sys.stderr)
        return 2

    work = pathlib.Path(tempfile.mkdtemp(prefix="clua-byteid-"))
    hello = work / "hello.lua"
    hello.write_text('print("hello")\n', encoding="ascii")

    print(f"# byte-identity corpus: {label}")
    rc = 0
    for name, rel in CORPUS:
        src = hello if rel is None else (root / rel)
        if not src.is_file():
            print(f"{name:14} {'MISSING':>12}  {rel}")
            rc = 1
            continue
        for lvl in LEVELS:
            out = work / f"{name}{lvl}.exe"
            r = subprocess.run([str(clua), "build", str(src), lvl, "-o", str(out)],
                               capture_output=True, text=True, cwd=root)
            if r.returncode != 0 or not out.is_file():
                print(f"{name:14} {lvl:4} BUILD-FAILED  "
                      f"{(r.stderr or r.stdout).strip()[:80]}")
                rc = 1
                continue
            digest = hashlib.sha256(out.read_bytes()).hexdigest()
            print(f"{name:14} {lvl:4} {out.stat().st_size:>9,}  {digest}")
            out.unlink()
    hello.unlink()
    try:
        work.rmdir()
    except OSError:
        pass
    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
