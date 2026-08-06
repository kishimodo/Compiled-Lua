#!/usr/bin/env python3
"""Report object files that make will NOT rebuild but should.

Make rebuilds a target only when a prerequisite is *strictly* newer. An object
whose mtime merely EQUALS its source is therefore considered up to date, and
make will happily link stale code forever.

That is not hypothetical. During the 2026-07 size arc an A/B copied one arm's
source into place within the same whole second as the object built from the
other arm; `build/bin/obj/codegen/x64_emit.o` then kept the pre-imm8 encoder
across a dozen rebuilds, and the resulting figures went into
docs/benchmarks/size-and-speed-current.md as a measured "current size" table.
Nothing failed. The build was green the whole time.

So the check is deliberately the same comparison make makes -- strictly-newer --
rather than a heuristic about how large the gap is.

    python tools/check-object-freshness.py            # human output
    python tools/check-object-freshness.py --json     # for the Lua gate

Exit 0 when every resolvable object is strictly newer than its source, 1 when
any is not. Objects whose source cannot be resolved unambiguously are counted
and listed under "unmapped" but never fail the run -- generated package objects
legitimately have no one-to-one source.
"""

import argparse
import json
import os
import subprocess
import sys

# Object tree -> source root. Longest prefix wins, so obj-aot/ is tried before
# the bare obj/ that would also match it as a string prefix.
TREE_MAP = [
    ("build/bin/obj-aot/", "clua/src/"),
    ("build/bin/obj-emb/", "clua/src/"),
    ("build/bin/obj-aotc/", "clua/src/"),
    ("build/bin/obj/", "clua/src/"),
    ("build/bin/lua-emb/", "lua-5.4/src/"),
    ("build/bin/lua/", "lua-5.4/src/"),
]

# Fallback roots searched by basename when the tree mapping misses.
FALLBACK_ROOTS = ["clua/src", "lua-5.4/src", "build/gen"]


def repo_root():
    try:
        out = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        if out:
            return out
    except (OSError, subprocess.CalledProcessError):
        pass
    return os.getcwd()


def build_basename_index(root):
    """basename -> [relative source paths]. Ambiguous names keep every hit."""
    index = {}
    for sub in FALLBACK_ROOTS:
        base = os.path.join(root, sub)
        if not os.path.isdir(base):
            continue
        for dirpath, _dirnames, filenames in os.walk(base):
            for fn in filenames:
                if fn.endswith(".c"):
                    rel = os.path.relpath(os.path.join(dirpath, fn), root)
                    index.setdefault(fn, []).append(rel.replace("\\", "/"))
    return index


def resolve_source(root, obj_rel, index):
    """Return the source for an object, or None if it is not unambiguous."""
    for tree, src_root in TREE_MAP:
        if obj_rel.startswith(tree):
            cand = src_root + obj_rel[len(tree):-2] + ".c"
            if os.path.isfile(os.path.join(root, cand)):
                return cand
            break  # the tree matched; fall through to the basename index

    hits = index.get(os.path.basename(obj_rel)[:-2] + ".c", [])
    return hits[0] if len(hits) == 1 else None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    root = repo_root()
    index = build_basename_index(root)

    stale, unmapped, checked = [], [], 0
    objroot = os.path.join(root, "build", "bin")
    for dirpath, _dirnames, filenames in os.walk(objroot):
        for fn in filenames:
            if not fn.endswith(".o"):
                continue
            obj_abs = os.path.join(dirpath, fn)
            obj_rel = os.path.relpath(obj_abs, root).replace("\\", "/")
            src_rel = resolve_source(root, obj_rel, index)
            if src_rel is None:
                unmapped.append(obj_rel)
                continue
            checked += 1
            src_mtime = os.path.getmtime(os.path.join(root, src_rel))
            obj_mtime = os.path.getmtime(obj_abs)
            if not obj_mtime > src_mtime:  # make's own test: strictly newer
                stale.append({
                    "object": obj_rel,
                    "source": src_rel,
                    "lag_seconds": round(src_mtime - obj_mtime, 3),
                })

    if args.json:
        print(json.dumps({
            "checked": checked,
            "stale": stale,
            "unmapped_count": len(unmapped),
        }, indent=2))
    else:
        print("checked %d objects, %d unmapped" % (checked, len(unmapped)))
        for s in stale:
            print("STALE %s\n      source %s is %.3fs newer"
                  % (s["object"], s["source"], s["lag_seconds"]))
        if not stale:
            print("all objects are strictly newer than their sources")
        else:
            print("\nRemedy: touch the sources and rebuild, or")
            print("  make -f build/Makefile clean-objs && cmd /c build\\build-luac.bat")

    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
