# Generate a LuaVM windows sub-package from Microsoft's win32metadata.
#
# Two-stage pipeline:
#   1. (PowerShell, this file) Download + cache the win32metadata NuGet,
#      build the C# winmd-gen tool if not already built.
#   2. (C#, tools/winmd-gen/Program.cs) Read the winmd via
#      System.Reflection.Metadata, decode every P/Invoke / struct /
#      union / enum / constant in the requested namespace, emit a
#      LuaVM packages/windows/<area>.lua file with proper ffi.cdef
#      declarations.
#
# Usage:
#   powershell tools/gen-windows-package.ps1 `
#       -Namespace "Windows.Win32.System.Threading" `
#       -OutFile   "clua/src/runtime/packages/windows/threading.lua"
#
# List-only mode (no .lua emitted, just print the function count):
#   powershell tools/gen-windows-package.ps1 `
#       -Namespace "Windows.Win32.System.Threading" -ListOnly
#
# Works in both Windows PowerShell 5.1 and pwsh 7+ -- the C# tool
# uses .NET 8.0 (built via the system dotnet SDK) so PS doesn't
# need to touch System.Reflection.Metadata directly.
#
# Requirements:
#   * .NET SDK 8.0+ on PATH (C:\Program Files\dotnet\dotnet.exe)
#   * Internet access on first run (downloads the winmd NuGet)
#
# After generation, wire the new sub-package into the build:
#   1. Add a PACKAGE_WIN_<AREA>_* block to build/Makefile (mirror
#      the existing entries -- LUA / GEN_C / OBJ + rule pair).
#   2. Add the require()-name (e.g. "windows.threading") to
#      k_BuiltinPackages in src/compiler/resolve.c.
#   3. Rebuild runtime + compiler. The Phase 2 tree-shaking pass
#      (commit 69e51d5) means binaries that don't require the new
#      sub-module pay zero bytes for it.

param(
    [Parameter(Mandatory=$true)] [string]$Namespace,
    [string]$OutFile,
    [string]$CacheDir     = "$env:TEMP\luavm-winmd",
    [string]$NugetVersion = "63.0.31-preview",
    [switch]$ListOnly,
    [switch]$Rebuild        # force rebuild of winmd-gen.dll
)

$ErrorActionPreference = "Stop"

if (-not $ListOnly -and -not $OutFile) {
    throw "either -OutFile or -ListOnly must be provided"
}

# ----- Step 1: locate dotnet --------------------------------------------
$dotnet = $null
$dotnetCmd = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnetCmd) { $dotnet = $dotnetCmd.Source }
elseif (Test-Path "C:\Program Files\dotnet\dotnet.exe") {
    $dotnet = "C:\Program Files\dotnet\dotnet.exe"
}
else {
    throw ".NET SDK not found. Install from https://dot.net/download or via " +
          "`winget install Microsoft.DotNet.SDK.8`."
}

# ----- Step 2: download + cache the winmd ------------------------------
$winmdPath = Join-Path $CacheDir "Windows.Win32.winmd"
if (-not (Test-Path $winmdPath)) {
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    $nupkg   = Join-Path $CacheDir "win32metadata.$NugetVersion.nupkg"
    $extract = Join-Path $CacheDir "extract"
    if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
    $url = "https://www.nuget.org/api/v2/package/Microsoft.Windows.SDK.Win32Metadata/$NugetVersion"
    Write-Host "[*] downloading $url ..."
    Invoke-WebRequest -Uri $url -OutFile $nupkg -UseBasicParsing
    Write-Host "[*] extracting winmd ..."
    $asZip = "$nupkg.zip"
    Copy-Item $nupkg $asZip -Force
    Expand-Archive -Path $asZip -DestinationPath $extract -Force
    Remove-Item $asZip
    $found = Get-ChildItem -Path $extract -Filter "Windows.Win32.winmd" -Recurse |
             Select-Object -First 1
    if (-not $found) { throw "Windows.Win32.winmd not found in NuGet payload" }
    Copy-Item $found.FullName $winmdPath
    Remove-Item -Recurse -Force $extract
    Remove-Item $nupkg
}
Write-Host "[*] using winmd: $winmdPath"

# ----- Step 3: build the C# winmd-gen tool (cached) --------------------
$genProj = Join-Path $PSScriptRoot "winmd-gen\winmd-gen.csproj"
$genDll  = Join-Path $PSScriptRoot "winmd-gen\bin\winmd-gen.dll"
$srcLatest = (Get-ChildItem -Path (Join-Path $PSScriptRoot "winmd-gen") -Filter "*.cs" -Recurse |
              Measure-Object -Property LastWriteTimeUtc -Maximum).Maximum
$buildNeeded = $Rebuild -or (-not (Test-Path $genDll)) -or
               ((Get-Item $genDll).LastWriteTimeUtc -lt $srcLatest)
if ($buildNeeded) {
    Write-Host "[*] building tools/winmd-gen ..."
    $build = & $dotnet build $genProj -c Release -o (Split-Path $genDll) -v quiet 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host ($build -join "`n")
        throw "winmd-gen build failed"
    }
}

# ----- Step 4: invoke -------------------------------------------------
if ($ListOnly) {
    $tmpOut = [System.IO.Path]::GetTempFileName()
    try {
        & $dotnet $genDll $winmdPath $Namespace $tmpOut | Write-Host
        if (Test-Path $tmpOut) {
            $lines = Get-Content $tmpOut
            $funcs = $lines | Where-Object { $_ -match '^[A-Z][A-Z_]* [A-Za-z_]+\(' }
            "  -- {0} functions in namespace --" -f $funcs.Count | Write-Host
            $funcs | ForEach-Object {
                if ($_ -match '^[A-Z_]+ ([A-Za-z_]+)\(') { "    $($Matches[1])" }
            } | Sort-Object | Select-Object -First 40 | Write-Host
        }
    } finally {
        if (Test-Path $tmpOut) { Remove-Item $tmpOut }
    }
    return
}

& $dotnet $genDll $winmdPath $Namespace $OutFile
if ($LASTEXITCODE -ne 0) { throw "winmd-gen failed" }
