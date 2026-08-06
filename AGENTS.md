# CLua agent guidance

Read `CLAUDE.md` for the authoritative architecture, build commands, test
discipline, and build-system gotchas. Those rules apply to every coding agent.

## Shared workspace

Shared material is repository-relative and agent-neutral. Read and update these
files directly; never keep a private copy under `.codex/`, `.claude/`, or an
absolute path outside the repository, and never write a client's name into a
shared file where the work itself is the subject.

| Kind | Location |
|---|---|
| Reviews and audits | [`docs/audits/`](docs/audits/) |
| Roadmap and live status | [`docs/roadmaps/`](docs/roadmaps/) |
| Benchmarks and baselines | [`docs/benchmarks/`](docs/benchmarks/) |
| Session handoffs | [`docs/handoff/`](docs/handoff/) |
| Coordination map and tools | [`tools/agent-coordination/README.md`](tools/agent-coordination/README.md) |

`.mcp.json` and `.codex/config.toml` carry MCP registration only.

Resolve real paths at run time instead of remembering a worktree:

```powershell
python tools/agent-coordination/repo-paths.py --json
python tools/agent-coordination/repo-paths.py --check
```

`repo_root` follows the worktree you are in; `git_common_dir`, `main_worktree`,
and `coordination_db` are the same from every worktree.
`tools/test-agent-workspace.lua` gates these invariants in the normal suite.

## Git ownership

- Never let two agents edit in the same working tree concurrently.
- Joint work uses linked worktrees and `<agent>/<task>` branches:
  `.\tools\agent-coordination\new-worktree.ps1 <agent> <task>` derives the main
  checkout itself and works from any worktree.
- Before editing, inspect `git status --short --branch` and preserve unrelated
  user changes. Never commit another agent's partial work.
- Exchange commit ids through the coordination MCP mailbox or a `docs/handoff/`
  file, then integrate through review, merge, or cherry-pick after the relevant
  tests pass.

## Optional joint-session coordination

When the `clua-coordination` MCP server is available, publish task/branch/state
with `set_status`; check `get_status` and `read_messages` before shared-area
edits; message ownership, interface changes, blockers, decisions, and commit
ids; acknowledge handled messages; and publish `done` or `idle` at handoff.
The mailbox cannot wake an inactive agent, and it is not durable context — a
handoff also needs a file in `docs/handoff/`.

See `tools/agent-coordination/README.md` for operation details.
