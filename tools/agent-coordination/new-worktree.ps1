param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("codex","claude")]
    [string]$Agent,
    [Parameter(Mandatory=$true)]
    [ValidatePattern("^[a-z0-9][a-z0-9-]*$")]
    [string]$Task,
    [string]$StartPoint="main"
)
$ErrorActionPreference = "Stop"
$repoRoot = (git rev-parse --show-toplevel).Trim()
if (-not $repoRoot) { throw "Run this inside the CLua Git repository." }
$branch = "$Agent/$Task"
$worktree = Join-Path (Split-Path -Parent $repoRoot) "CLua-$Agent-$Task"
if (Test-Path -LiteralPath $worktree) { throw "Target exists: $worktree" }
git -C $repoRoot show-ref --verify --quiet "refs/heads/$branch"
if ($LASTEXITCODE -eq 0) {
    git -C $repoRoot worktree add $worktree $branch
} else {
    git -C $repoRoot worktree add -b $branch $worktree $StartPoint
}
if ($LASTEXITCODE -ne 0) { throw "git worktree add failed." }
Write-Host "Created $worktree on branch $branch"
