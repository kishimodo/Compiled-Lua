<#
  bump-version.ps1 -- the one command that moves the CLua toolchain version.

  It is the only thing that should edit clua/src/common/version.h (the single
  source of truth that `clua version`, `aotc version` and the release zip all
  read) and it keeps CHANGELOG.md in step by promoting the running
  "## [Unreleased]" section to the new version + today's date.

  Usage:
    tools/bump-version.ps1 patch                 # 0.2.0       -> 0.2.1
    tools/bump-version.ps1 minor                 # 0.2.1       -> 0.3.0
    tools/bump-version.ps1 major                 # 0.3.0       -> 1.0.0
    tools/bump-version.ps1 prerelease beta       # 0.2.0       -> 0.2.0-beta.1
    tools/bump-version.ps1 prerelease beta       # 0.2.0-beta.1-> 0.2.0-beta.2
    tools/bump-version.ps1 release               # 0.2.0-beta.2-> 0.2.0 (drop prerelease)
    tools/bump-version.ps1 set 1.2.3-rc.1        # explicit

  A core bump (major/minor/patch) clears any prerelease suffix.

  Pass -NoChangelog to skip the CHANGELOG promotion, -DryRun to preview.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('major', 'minor', 'patch', 'prerelease', 'release', 'set')]
    [string] $Part,

    [Parameter(Position = 1)]
    [string] $Arg,

    [switch] $NoChangelog,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

$root          = Split-Path -Parent $PSScriptRoot
$versionHeader = Join-Path $root 'clua\src\common\version.h'
$changelog     = Join-Path $root 'CHANGELOG.md'

if (-not (Test-Path $versionHeader)) { throw "bump-version: missing $versionHeader" }

# ----- parse the current version -------------------------------------------
$text = Get-Content $versionHeader -Raw
function Read-Macro([string] $name) {
    # Capture only the first token after the macro name -- a "quoted" value or a
    # bare integer -- so a trailing /* comment */ is never swept into the value.
    $mm = [regex]::Match($text, "#define\s+$name\s+(`"[^`"]*`"|\S+)")
    if (-not $mm.Success) { throw "bump-version: $name not found in version.h" }
    return $mm.Groups[1].Value.Trim()
}
$major = [int] (Read-Macro 'CLUA_VERSION_MAJOR')
$minor = [int] (Read-Macro 'CLUA_VERSION_MINOR')
$patch = [int] (Read-Macro 'CLUA_VERSION_PATCH')
$preMacro = (Read-Macro 'CLUA_VERSION_PRERELEASE') -replace '"', ''   # "" when final
$current  = (Read-Macro 'CLUA_VERSION_STRING')     -replace '"', ''

# ----- compute the next version --------------------------------------------
$pre = $preMacro
switch ($Part) {
    'major'      { $major++; $minor = 0; $patch = 0; $pre = '' }
    'minor'      { $minor++; $patch = 0; $pre = '' }
    'patch'      { $patch++; $pre = '' }
    'release'    { $pre = '' }
    'prerelease' {
        $tag = if ($Arg) { $Arg } else { 'beta' }
        # bump the numeric suffix when already on this tag, else start at 1
        $mm = [regex]::Match($pre, "^$([regex]::Escape($tag))\.(\d+)$")
        if ($mm.Success) { $pre = "$tag.$([int]$mm.Groups[1].Value + 1)" }
        else             { $pre = "$tag.1" }
    }
    'set' {
        if (-not $Arg) { throw "bump-version: 'set' needs an explicit version (e.g. set 1.2.3-rc.1)" }
        $mm = [regex]::Match($Arg, '^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$')
        if (-not $mm.Success) { throw "bump-version: '$Arg' is not a valid semver" }
        $major = [int] $mm.Groups[1].Value
        $minor = [int] $mm.Groups[2].Value
        $patch = [int] $mm.Groups[3].Value
        $pre   = $mm.Groups[4].Value
    }
}

$core    = "$major.$minor.$patch"
$newVer  = if ($pre) { "$core-$pre" } else { $core }

Write-Host "bump-version: $current -> $newVer"
if ($DryRun) { Write-Host "(dry run -- nothing written)"; return }
if ($newVer -eq $current) { Write-Host "already at $newVer; nothing to do."; return }

# ----- rewrite version.h ----------------------------------------------------
$text = [regex]::Replace($text, '(#define\s+CLUA_VERSION_MAJOR\s+)\d+',                "`${1}$major")
$text = [regex]::Replace($text, '(#define\s+CLUA_VERSION_MINOR\s+)\d+',                "`${1}$minor")
$text = [regex]::Replace($text, '(#define\s+CLUA_VERSION_PATCH\s+)\d+',                "`${1}$patch")
$text = [regex]::Replace($text, '(#define\s+CLUA_VERSION_PRERELEASE\s+)"[^"]*"',       "`${1}""$pre""")
$text = [regex]::Replace($text, '(#define\s+CLUA_VERSION_STRING\s+)"[^"]*"',           "`${1}""$newVer""")
Set-Content -Path $versionHeader -Value $text -NoNewline -Encoding ascii
Write-Host "  updated $versionHeader"

# ----- promote the CHANGELOG Unreleased section -----------------------------
if (-not $NoChangelog -and (Test-Path $changelog)) {
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $cl = Get-Content $changelog -Raw
    if ($cl -match '(?m)^##\s+\[Unreleased\]') {
        $cl = [regex]::Replace($cl, '(?m)^##\s+\[Unreleased\].*$',
            "## [Unreleased]`n`n## [$newVer] - $today", 1)
        Set-Content -Path $changelog -Value $cl -Encoding ascii
        Write-Host "  promoted CHANGELOG Unreleased -> [$newVer] - $today"
    }
    else {
        Write-Warning "  no '## [Unreleased]' heading in CHANGELOG.md; left untouched"
    }
}

Write-Host "done. Review the diff, then build + run the suite before tagging."
