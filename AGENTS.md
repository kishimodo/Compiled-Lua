# CLua agent guidance

Read `CLAUDE.md` for the authoritative architecture, build commands, test
discipline, and build-system gotchas. Those rules apply to every coding agent.

## Git ownership

- Never let Codex and Claude Code edit in the same working tree concurrently.
- Joint work uses linked worktrees and agent branches: `codex/<task>` for Codex
  and `claude/<task>` for Claude Code.
- Before editing, inspect `git status --short --branch` and preserve unrelated
  user changes. Never commit another agent's partial work.
- Exchange commit IDs through coordination MCP, then integrate through review,
  merge, or cherry-pick after relevant tests pass.

## Optional joint-session coordination

When the `clua-coordination` MCP server is available, publish task/branch/state
with `set_status`; check `get_status` and `read_messages` before shared-area
edits; message ownership, interface changes, blockers, decisions, and commit
IDs; acknowledge handled messages; and publish `done` or `idle` at handoff.
The mailbox cannot wake an inactive agent.

See `tools/agent-coordination/README.md` for operation details.
