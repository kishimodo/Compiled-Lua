# Create an isolated worktree for one agent's task.
#
# Everything is derived from Git at run time, so this works from the main
# checkout or from any linked worktree and never needs a path argument:
#   .\tools\agent-coordination\new-worktree.ps1 codex optimizer-fix
#   .\tools\agent-coordination\new-worktree.ps1 claude runtime-tests
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern("^[a-z0-9][a-z0-9-]*$")]
    [string]$Agent,
    [Parameter(Mandatory=$true)]
    [ValidatePattern("^[a-z0-9][a-z0-9-]*$")]
    [string]$Task,
    [string]$StartPoint="main"
)
$ErrorActionPreference = "Stop"

# The main checkout owns the shared Git metadata directory and is always listed
# first by `git worktree list`. Resolving it here lets a worktree be created
# from inside another worktree without nesting the new one under it.
$mainWorktree = $null
foreach ($line in (git worktree list --porcelain)) {
    if ($line -like "worktree *") { $mainWorktree = $line.Substring(9).Trim(); break }
}
if (-not $mainWorktree) {
    $commonDir = (git rev-parse --path-format=absolute --git-common-dir)
    if (-not $commonDir) { throw "Run this inside the CLua Git repository." }
    $mainWorktree = Split-Path -Parent $commonDir.Trim()
}
$mainWorktree = (Resolve-Path -LiteralPath $mainWorktree).Path

$branch = "$Agent/$Task"
$siblingName = "{0}-{1}-{2}" -f (Split-Path -Leaf $mainWorktree), $Agent, $Task
$worktree = Join-Path (Split-Path -Parent $mainWorktree) $siblingName
if (Test-Path -LiteralPath $worktree) { throw "Target exists: $worktree" }

git -C $mainWorktree show-ref --verify --quiet "refs/heads/$branch"
if ($LASTEXITCODE -eq 0) {
    git -C $mainWorktree worktree add $worktree $branch
} else {
    git -C $mainWorktree worktree add -b $branch $worktree $StartPoint
}
if ($LASTEXITCODE -ne 0) { throw "git worktree add failed." }
Write-Host "Created $worktree on branch $branch"
Write-Host "Shared files stay in the repository: see tools/agent-coordination/README.md"
