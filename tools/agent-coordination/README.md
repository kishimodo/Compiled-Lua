# Codex + Claude Code coordination

This is an optional local MCP mailbox, not a daemon. Each client starts its own
stdio process only when MCP is enabled, and it exits with the client. The
processes share SQLite data in Git's common metadata directory, including
across linked worktrees. No port, cloud service, API key, or committed message
history is involved.

## Setup and opt-in use

Claude Code reads the checked-in `.mcp.json` and asks for approval the first
time. Codex reads `.codex/config.toml` after the project is trusted. Python 3.9+
must be available as `python`.

The Codex entry is disabled by default. For a joint session, launch:

```powershell
codex -c mcp_servers.clua_coordination.enabled=true
```

If that surface does not expose the flag, temporarily change `enabled = false`
to `true` in `.codex/config.toml` and restart Codex. Restore it afterward.
Claude can disable the project server from `/mcp` for ordinary solo sessions.

## Joint-session protocol

Each agent publishes its task and branch with `set_status`, then checks
`get_status` and `read_messages` before editing overlapping areas. Use
`send_message` for ownership, decisions, blockers, interface changes, and
commit IDs. Acknowledge handled messages and publish `done` or `idle` at
handoff. This is a mailbox: it cannot wake an inactive model.

## Separate Git worktrees

Never run two agents in one working tree. From the main checkout:

```powershell
.\tools\agent-coordination\new-worktree.ps1 codex optimizer-fix
.\tools\agent-coordination\new-worktree.ps1 claude runtime-tests
git worktree list
```

This creates sibling directories on `codex/<task>` and `claude/<task>`
branches. Commit only on the agent's branch. Integrate through review, merge,
or cherry-pick after the relevant tests pass.

## Diagnostics and reset

```powershell
python .\tools\agent-coordination\server.py --help
git worktree list
```

To clear history, stop both clients and delete
`.git\agent-coordination.sqlite3` plus optional `-wal` and `-shm` companions.
