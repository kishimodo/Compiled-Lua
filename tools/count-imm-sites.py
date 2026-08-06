#!/usr/bin/env python3
"""Count helper-call argument materialisation in an emitted CLua executable.

    python tools/count-imm-sites.py build/bin/rover.exe [more.exe ...]

LcCg_EmitHelperCall3 emits a fixed shape: `mov rcx, rbx`, three integer
arguments into RDX/R8/R9, then `call rel32`. Anchoring on that whole shape --
rather than on one instruction -- makes the count exact rather than a heuristic.

Each argument slot has three possible encodings, chosen by the value's sign so
that the 64-bit register always ends up bit-identical to the old `mov r64,imm64`
form:

    zero      xor r32, r32        31 /r              2 bytes (3 for R8/R9)
    positive  mov r32, imm32      B8+rd id           5 bytes (6 for R8/R9)
    negative  mov r64, imm32 sx   REX.W C7 /0 id     7 bytes

The tool also counts the pre-change 30-byte all-imm64 triple. After the imm32
commit that counter must read 0: a nonzero value means the build is half-applied
(a stale codegen object), which is the class of failure
tools/check-object-freshness.py exists to catch.

ACCURACY. On a pre-change binary this is exact: the anchored shape is 33 bytes
and cannot plausibly occur by accident, and both this matcher and a simpler
triple-only one independently find 4,724 sites in Rover. On a post-change binary
the shape can be as short as 12 bytes, so it collides with unrelated CRT bytes --
Rover reports 4,758 where 4,724 is the true count, about +0.7%. Treat the site
count and the "saved" figure here as an estimate, and take the authoritative
number from the measured `.text`/whole-file delta (`objdump -h`) instead.

Results are recorded in docs/benchmarks/helper-call-args.md.
"""
from __future__ import annotations

import pathlib
import struct
import sys

RESTORE_L = b"\x48\x89\xd9"          # mov rcx, rbx
CALL_REL32 = 0xE8

# (name, zero-form, positive-prefix, negative-prefix), imm64 form for the
# legacy scan. Order matters only for reporting.
SLOTS = [
    ("a", b"\x31\xd2",         b"\xba",         b"\x48\xc7\xc2", b"\x48\xba"),
    ("b", b"\x45\x31\xc0",     b"\x41\xb8",     b"\x49\xc7\xc0", b"\x49\xb8"),
    ("c", b"\x45\x31\xc9",     b"\x41\xb9",     b"\x49\xc7\xc1", b"\x49\xb9"),
]

IMM64_COST = 10


def match_slot(b: bytes, i: int, slot) -> tuple[int, int, str] | None:
    """Return (next_index, value, tier) if a slot encoding starts at i."""
    _, zero, pos, neg, _ = slot
    if b.startswith(zero, i):
        return i + len(zero), 0, "zero"
    if b.startswith(pos, i):
        j = i + len(pos)
        return j + 4, struct.unpack("<i", b[j:j + 4])[0], "pos"
    if b.startswith(neg, i):
        j = i + len(neg)
        return j + 4, struct.unpack("<i", b[j:j + 4])[0], "neg"
    return None


def scan(path: pathlib.Path) -> dict:
    b = path.read_bytes()
    sites = 0
    arg_bytes = 0
    tiers = {"zero": 0, "pos": 0, "neg": 0}
    lo = hi = None

    i = 0
    while True:
        i = b.find(RESTORE_L, i)
        if i < 0:
            break
        j = i + len(RESTORE_L)
        vals = []
        for slot in SLOTS:
            m = match_slot(b, j, slot)
            if m is None:
                break
            j, value, tier = m
            vals.append((value, tier))
        if len(vals) == 3 and j < len(b) and b[j] == CALL_REL32:
            sites += 1
            arg_bytes += j - (i + len(RESTORE_L))
            for value, tier in vals:
                tiers[tier] += 1
                lo = value if lo is None else min(lo, value)
                hi = value if hi is None else max(hi, value)
            i = j + 5
        else:
            i += 1

    # Legacy all-imm64 triple: must be 0 after the imm32 change.
    legacy, i = 0, 0
    a64, b64, c64 = SLOTS[0][4], SLOTS[1][4], SLOTS[2][4]
    while True:
        i = b.find(a64, i)
        if i < 0:
            break
        if b.startswith(b64, i + 10) and b.startswith(c64, i + 20):
            legacy += 1
            i += 30
        else:
            i += 2

    # What the old encoding would have spent on the same sites.
    would_have = sites * 3 * IMM64_COST
    return {
        "sites": sites,
        "arg_bytes": arg_bytes,
        "would_have": would_have,
        "saved": would_have - arg_bytes,
        "tiers": tiers,
        "range": (lo, hi),
        "legacy_imm64_triples": legacy,
    }


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(__doc__)
        return 2
    rc = 0
    for name in argv[1:]:
        path = pathlib.Path(name)
        if not path.is_file():
            print(f"{name}: not a file")
            return 1
        r = scan(path)
        t = r["tiers"]
        print(f"{path.name}: {r['sites']:,} helper-call sites, "
              f"{r['arg_bytes']:,} bytes of argument loads")
        print(f"   tiers:  zero={t['zero']:,}  positive={t['pos']:,}  "
              f"negative={t['neg']:,}")
        print(f"   immediate range: {r['range'][0]} .. {r['range'][1]}")
        print(f"   all-imm64 would spend {r['would_have']:,} "
              f"-> saved ~{r['saved']:,} bytes (estimate; see the accuracy note "
              f"in this file's docstring -- measure the .text delta for the "
              f"real figure)")
        if r["legacy_imm64_triples"]:
            print(f"   [-] {r['legacy_imm64_triples']:,} pre-change imm64 triples "
                  f"remain: this build is HALF-APPLIED (stale codegen object?)")
            rc = 1
    return rc


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
