#!/usr/bin/env python3
"""Resolve CLua's shared agent-workspace paths dynamically.

Every path is derived from Git at run time, so no agent, script, or document
has to remember a worktree name or an absolute machine path. Run it from any
directory inside any linked worktree.

    python tools/agent-coordination/repo-paths.py           # human table
    python tools/agent-coordination/repo-paths.py --json
    python tools/agent-coordination/repo-paths.py --get git_common_dir
    python tools/agent-coordination/repo-paths.py --check   # verify the layout

`repo_root` follows the worktree you are standing in; `git_common_dir`,
`main_worktree`, and `coordination_db` are identical from every worktree,
which is what lets the mailbox and the shared documents be one set of files.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

# Repository-relative homes for material both agents read and write. Shared
# files live here and never under a client-specific directory such as .codex/
# or .claude/, which only carry MCP registration.
SHARED_DIRS = {
    "audits": "docs/audits",
    "roadmaps": "docs/roadmaps",
    "benchmarks": "docs/benchmarks",
    "handoff": "docs/handoff",
    "coordination": "tools/agent-coordination",
}

# Entry points that must keep pointing at the shared layout.
SHARED_FILES = {
    "agent_guide": "AGENTS.md",
    "claude_guide": "CLAUDE.md",
    "coordination_readme": "tools/agent-coordination/README.md",
}

COORDINATION_DB_NAME = "agent-coordination.sqlite3"


def git(*args: str, cwd: Path) -> str:
    """Run git and return stripped stdout, or "" when git cannot answer."""
    try:
        return subprocess.check_output(
            ["git", *args], cwd=cwd, text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def main_worktree_of(repo_root: Path, common_dir: Path, cwd: Path) -> Path:
    """The main checkout, which owns the shared Git metadata directory.

    `git worktree list` always reports the main worktree first; the parent of
    the common metadata directory is the fallback when that output is absent.
    """
    listing = git("worktree", "list", "--porcelain", cwd=cwd)
    for line in listing.splitlines():
        if line.startswith("worktree "):
            return Path(line[len("worktree ") :]).resolve()
    if common_dir.name == ".git":
        return common_dir.parent
    return repo_root


def resolve(start: Path | None = None) -> dict:
    cwd = (start or Path.cwd()).resolve()
    if not cwd.is_dir():
        cwd = cwd.parent

    top = git("rev-parse", "--show-toplevel", cwd=cwd)
    if not top:
        raise SystemExit(
            "not inside a Git repository (run this from anywhere in a CLua worktree)"
        )
    repo_root = Path(top).resolve()
    common = git("rev-parse", "--path-format=absolute", "--git-common-dir", cwd=cwd)
    common_dir = Path(common).resolve() if common else (repo_root / ".git")
    git_dir_raw = git("rev-parse", "--path-format=absolute", "--git-dir", cwd=cwd)
    git_dir = Path(git_dir_raw).resolve() if git_dir_raw else common_dir
    main_worktree = main_worktree_of(repo_root, common_dir, cwd)

    info = {
        "repo_root": str(repo_root),
        "git_dir": str(git_dir),
        "git_common_dir": str(common_dir),
        "main_worktree": str(main_worktree),
        "worktree_parent": str(main_worktree.parent),
        "is_linked_worktree": git_dir != common_dir,
        "branch": git("rev-parse", "--abbrev-ref", "HEAD", cwd=cwd),
        "head": git("rev-parse", "HEAD", cwd=cwd),
        "coordination_db": str(common_dir / COORDINATION_DB_NAME),
    }
    for key, rel in SHARED_DIRS.items():
        info[f"{key}_dir"] = str(repo_root / rel)
        info[f"{key}_rel"] = rel
    for key, rel in SHARED_FILES.items():
        info[key] = str(repo_root / rel)
        info[f"{key}_rel"] = rel
    return info


def check(info: dict) -> list[str]:
    """Report shared locations that are missing or misplaced."""
    problems = []
    root = Path(info["repo_root"])
    for key, rel in SHARED_DIRS.items():
        path = root / rel
        if not path.is_dir():
            problems.append(f"missing shared directory: {rel}")
        elif key != "coordination" and not any(path.glob("*.md")):
            problems.append(f"shared directory has no documents: {rel}")
    for _, rel in SHARED_FILES.items():
        if not (root / rel).is_file():
            problems.append(f"missing shared entry point: {rel}")
    for stray in ("docs/audits", "docs/roadmaps", "docs/benchmarks", "docs/handoff"):
        for client in (".codex", ".claude"):
            if (root / client / Path(stray).name).exists():
                problems.append(f"shared material must not live under {client}/")
    if not Path(info["git_common_dir"]).is_dir():
        problems.append("git common directory does not exist")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--json", action="store_true", help="emit the full map as JSON")
    parser.add_argument("--get", metavar="KEY", help="print one value and exit")
    parser.add_argument(
        "--check", action="store_true", help="verify the shared layout; non-zero if broken"
    )
    parser.add_argument(
        "--from", dest="start", metavar="DIR", help="resolve as if run from DIR"
    )
    args = parser.parse_args()

    info = resolve(Path(args.start) if args.start else None)

    if args.get:
        if args.get not in info:
            print(f"unknown key: {args.get}", file=sys.stderr)
            print("known keys: " + ", ".join(sorted(info)), file=sys.stderr)
            return 2
        print(info[args.get])
        return 0

    if args.check:
        problems = check(info)
        for problem in problems:
            print(f"[-] {problem}")
        if problems:
            return 1
        print("[+] shared agent workspace is intact")
        return 0

    if args.json:
        print(json.dumps(info, indent=2, sort_keys=True))
        return 0

    width = max(len(key) for key in info)
    for key in sorted(info):
        print(f"{key.ljust(width)}  {info[key]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
