# Agent coordination and the shared workspace

Two things live here: the map of files that every coding agent shares, and an
optional local MCP mailbox for joint sessions. Both are repository-relative and
agent-neutral. Nothing shared belongs in a client-specific directory, and
nothing shared may hard-code a machine path or a worktree name.

## Shared file locations

| Kind | Location | Contents |
|---|---|---|
| Reviews and audits | [`docs/audits/`](../../docs/audits/) | dated findings, with the commits and line numbers they were verified against |
| Roadmap and status | [`docs/roadmaps/`](../../docs/roadmaps/) | one live status row per deliverable; edit this instead of re-litigating an audit |
| Benchmarks | [`docs/benchmarks/`](../../docs/benchmarks/) | measurement protocol, current baselines, per-change measured results |
| Handoffs | [`docs/handoff/`](../../docs/handoff/) | one dated file per handoff, written for whoever runs next |
| Coordination | `tools/agent-coordination/` | this file, the path helper, the worktree helper, the mailbox server |
| Known bugs | [`docs/known-bugs-2026-06-07.md`](../../docs/known-bugs-2026-06-07.md) | repros for anything marked XFAIL in the suite |

Client-specific files carry **MCP registration only** — no shared content, and no
paths for a human or an agent to remember:

- `.mcp.json` — the project MCP server list Claude Code reads;
- `.codex/config.toml` — the same registration for Codex, disabled by default.

## Dynamic paths: never remember a worktree

Every real path is derived from Git at run time, from whichever worktree you are
standing in:

```powershell
python tools/agent-coordination/repo-paths.py            # human-readable table
python tools/agent-coordination/repo-paths.py --json     # machine-readable
python tools/agent-coordination/repo-paths.py --get repo_root
python tools/agent-coordination/repo-paths.py --check    # verify the layout
```

`repo_root` follows the worktree you are in. `git_common_dir`, `main_worktree`,
`worktree_parent`, and `coordination_db` are **identical from every worktree** —
that is what lets the mailbox and the shared documents be one set of files rather
than one set per checkout. `--check` exits non-zero if a shared location is
missing or if shared material has drifted into a client directory; the same
invariants are gated by `tools/test-agent-workspace.lua` in the normal suite.

## Separate worktrees

Never run two agents in one working tree. From anywhere inside the repository:

```powershell
.\tools\agent-coordination\new-worktree.ps1 codex optimizer-fix
.\tools\agent-coordination\new-worktree.ps1 claude runtime-tests
git worktree list
```

The script derives the main checkout and its parent directory itself, so it works
from a linked worktree and never needs a path argument. It creates a sibling
directory named `<main-checkout>-<agent>-<task>` on branch `<agent>/<task>`.
Commit only on that branch, and integrate through review, merge, or cherry-pick
once the relevant tests pass.

## Optional mailbox for joint sessions

This is a local stdio MCP server, not a daemon. Each client starts its own
process when MCP is enabled and it exits with the client. The processes share one
SQLite file in Git's common metadata directory, so every linked worktree sees the
same mailbox. No port, cloud service, API key, or committed message history is
involved. Python 3.9+ must be available as `python`.

Claude Code reads the checked-in `.mcp.json` and asks for approval the first
time. Codex reads `.codex/config.toml` once the project is trusted; that entry is
disabled by default, so a joint session launches with:

```powershell
codex -c mcp_servers.clua_coordination.enabled=true
```

If that surface does not expose the flag, temporarily set `enabled = true` in
`.codex/config.toml` and restart, then restore it afterward. Claude Code can
disable the project server from `/mcp` for ordinary solo sessions.

### Protocol

Publish task and branch with `set_status`, then check `get_status` and
`read_messages` before editing an overlapping area. Use `send_message` for
ownership, decisions, blockers, interface changes, and commit ids. Acknowledge
handled messages, and publish `done` or `idle` at handoff — together with a file
in `docs/handoff/`, because the mailbox is not durable context. It is a mailbox,
not a scheduler: it cannot wake an inactive model.

### Diagnostics and reset

```powershell
python .\tools\agent-coordination\server.py --help
python .\tools\agent-coordination\repo-paths.py --get coordination_db
git worktree list
```

To clear history, stop every client and delete the file named by
`--get coordination_db`, plus its optional `-wal` and `-shm` companions.
