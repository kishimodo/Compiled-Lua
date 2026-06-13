<#
  make-release.ps1 -- package dist\ into a versioned zip + SHA-256 sidecar.

  The version string is read from clua/src/common/version.h (the single source
  of truth -- tools/bump-version.ps1 rewrites it), so the release artifact name
  always matches what `clua version` prints.

  Usage:
    powershell -File build/make-release.ps1 -VersionHeader clua/src/common/version.h -DistDir dist -OutDir .
#>
param(
    [Parameter(Mandatory = $true)] [string] $VersionHeader,
    [Parameter(Mandatory = $true)] [string] $DistDir,
    [Parameter(Mandatory = $true)] [string] $OutDir
)

$ErrorActionPreference = 'Stop'

$m = Select-String -Path $VersionHeader -Pattern 'CLUA_VERSION_STRING\s+"([^"]+)"'
if (-not $m) { throw "make-release: CLUA_VERSION_STRING not found in $VersionHeader" }
$version = $m.Matches[0].Groups[1].Value

$zipName = "clua-v$version-windows-x64.zip"
$zipPath = Join-Path $OutDir $zipName

Compress-Archive -Force -Path (Join-Path $DistDir '*') -DestinationPath $zipPath
$hash = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
"$hash  $zipName" | Out-File -Encoding ascii "$zipPath.sha256"
Write-Host "[+] release: $zipName  sha256=$hash"
