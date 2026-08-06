# Handoff notes

One file per handoff, named `<YYYY-MM-DD>-<topic>.md`. A handoff exists so the
next session — whichever agent runs it, in whichever worktree — can resume
without asking anything.

Rules that make a handoff usable by either agent:

- **Name branches and commits, never worktrees or absolute paths.** A branch is
  a repository fact; a worktree directory is one machine's private detail.
  Anything that needs a real path is derived at run time:

  ```powershell
  python tools/agent-coordination/repo-paths.py --json
  ```

- **Write agent-neutral prose.** "The reviewer found", not a client's name. The
  work is the subject; who typed it is not load-bearing.
- **Separate verified from believed.** Give the command that produced the
  evidence, and say plainly which claims are unmeasured.
- **Point at the shared documents** rather than restating them: reviews in
  [`../audits/`](../audits/), status in [`../roadmaps/`](../roadmaps/), numbers
  in [`../benchmarks/`](../benchmarks/).
- **Delete nothing on arrival.** A stale handoff is history; supersede it with a
  new dated file and say which one it replaces.

## Template

```markdown
# Handoff: <topic> — <YYYY-MM-DD>

Branch: `<branch>` at `<commit>`. Supersedes: `<file or none>`.

## State
What is done and *proven*, each with its commit and its evidence.

## Verified how
The exact commands run, and their results. Note anything environment-specific.

## Not done / not claimed
Deliberate omissions, unmeasured claims, known traps.

## Next
The intended next step and why it is next, cross-referenced to the roadmap row.
```
