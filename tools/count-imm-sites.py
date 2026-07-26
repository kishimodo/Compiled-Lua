#!/usr/bin/env python3
"""Count helper-call argument materialisation in an emitted CLua executable.

    python tools/count-imm-sites.py build/bin/rover.exe [more.exe ...]

LcCg_EmitHelperCall3 loads its three integer arguments with
`mov rdx/r8/r9, imm64`, and those three destinations are used by no other
X64Emit_MovImm64ToReg call site in the backend (every other one targets RAX).
So the 30-byte triple

    48 BA <imm64>   mov rdx, a
    49 B8 <imm64>   mov r8,  b
    49 B9 <imm64>   mov r9,  c

identifies a helper call site uniquely, which makes this an exact count rather
than an estimate. The tally also reports how many immediates are zero and
whether any needs more than 32 bits, which is what decides whether a shorter
encoding is legal.

Results are recorded in docs/benchmarks/helper-call-args.md.
"""
from __future__ import annotations

import pathlib
import struct
import sys

TRIPLE = (b"\x48\xba", b"\x49\xb8", b"\x49\xb9")   # mov rdx / r8 / r9, imm64
MOV_RAX_IMM64 = b"\x48\xb8"

# Byte cost of each encoding, per destination: (imm64, imm32, xor-zero).
COST = {"rdx": (10, 5, 2), "r8": (10, 6, 3), "r9": (10, 6, 3)}
INT32 = range(-(2 ** 31), 2 ** 31)


def scan(path: pathlib.Path) -> dict:
    b = path.read_bytes()
    sites, zeros, oversize = 0, [0, 0, 0], 0
    lo, hi = None, None

    i = 0
    while True:
        i = b.find(TRIPLE[0], i)
        if i < 0:
            break
        if b[i + 10:i + 12] == TRIPLE[1] and b[i + 20:i + 22] == TRIPLE[2]:
            for k, off in enumerate((2, 12, 22)):
                v = struct.unpack("<q", b[i + off:i + off + 8])[0]
                if v == 0:
                    zeros[k] += 1
                if v not in INT32:
                    oversize += 1
                lo = v if lo is None else min(lo, v)
                hi = v if hi is None else max(hi, v)
            sites += 1
            i += 30
        else:
            i += 2

    # `mov rax, imm64 0` -- ten bytes to materialise zero, replaceable by
    # `xor eax, eax` (two bytes).
    rax_zero, i = 0, 0
    needle = MOV_RAX_IMM64 + b"\x00" * 8
    while True:
        i = b.find(needle, i)
        if i < 0:
            break
        rax_zero += 1
        i += 10

    saving = 0
    for k, name in enumerate(("rdx", "r8", "r9")):
        imm64, imm32, zero = COST[name]
        saving += zeros[k] * (imm64 - zero) + (sites - zeros[k]) * (imm64 - imm32)

    return {
        "sites": sites,
        "arg_bytes": sites * 30,
        "zeros": zeros,
        "oversize": oversize,
        "range": (lo, hi),
        "rax_zero": rax_zero,
        "saving": saving,
    }


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    for name in argv[1:]:
        path = pathlib.Path(name)
        if not path.is_file():
            print(f"{name}: not a file")
            return 1
        r = scan(path)
        z = r["zeros"]
        print(f"{path.name}: {r['sites']:,} helper-call sites, "
              f"{r['arg_bytes']:,} bytes of argument loads")
        print(f"   zero args:  a={z[0]:,}  b={z[1]:,}  c={z[2]:,}")
        print(f"   immediate range: {r['range'][0]} .. {r['range'][1]}"
              f"   needing >32 bits: {r['oversize']}")
        print(f"   imm32 + xor-zero would save: {r['saving']:,} bytes")
        print(f"   'mov rax, 0' sites: {r['rax_zero']:,} "
              f"({r['rax_zero'] * 8:,} bytes recoverable)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
