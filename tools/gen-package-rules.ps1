# Auto-generate the per-package Makefile fragment and the compiler's
# built-in package name header from the on-disk layout of
# src/runtime/packages/. Replaces the hand-written PACKAGE_<X>_*
# blocks in build/Makefile and the static k_BuiltinPackages[] list
# in src/compiler/resolve.c.
#
# Run once at build time. Outputs are stable -- this script writes to
# a temp file and only replaces the target when the bytes differ, so
# unchanged regenerations don't bump mtimes and trigger needless
# rebuilds.
#
# Usage (called from build/Makefile -- see GEN_PACKAGES_MK rule):
#   powershell -NoProfile -ExecutionPolicy Bypass `
#       -File tools/gen-package-rules.ps1 `
#       -PackagesDir "src/runtime/packages" `
#       -OutMk       "build/gen/packages.mk" `
#       -OutHeader   "build/gen/_builtin_packages.h"
#
# How package discovery works:
#   1. Enumerate every directory under <PackagesDir>.
#   2. Read <dir>/package.lua, extract the modules = { ["name"] = "file.lua", ... }
#      map via regex. If no package.lua, fall back to convention:
#        <dir>/init.lua       -> require name "<dir>"
#        <dir>/<sub>.lua      -> require name "<dir>.<sub>"
#   3. For each (require_name, lua_file) pair, emit:
#        * Makefile variables (PACKAGE_<KEY>_LUA / _GEN_C / _OBJ)
#        * embed + compile rules
#        * appends to PACKAGE_OBJS_AUTO
#        * the require name into the .h list
#
# Naming derivation:
#   require name -> file/symbol form
#     "windows"            -> file: windows_pkg_gen.c    symbol: g_PackageWindowsLua
#     "windows.bcrypt"     -> file: windows_bcrypt_pkg_gen.c symbol: g_PackageWindowsBcryptLua
#     "imgui_bindings"     -> file: imgui_bindings_pkg_gen.c symbol: g_PackageImguiBindingsLua
#   Makefile key (upper snake) -> "windows.bcrypt" -> WINDOWS_BCRYPT

param(
    [Parameter(Mandatory=$true)] [string]$PackagesDir,
    [Parameter(Mandatory=$true)] [string]$OutMk,
    [Parameter(Mandatory=$true)] [string]$OutHeader,
    # Optional: emit a C header mapping each builtin package to the
    # native DLLs it requires (read from package.lua's requires_native
    # block). Consumed by the compiler's native-embed infrastructure.
    [string]$OutNativeDepsHeader = "",
    # When true (default): emit rules that call build/bin/embed_luac.exe
    # to precompile each package to Lua bytecode before embedding. The
    # tool dumps via lua_dump(strip=1) so the embedded blob holds
    # bytecode bytes instead of source -- ~30-50% smaller for cdef-heavy
    # packages and the runtime skips parse/lex/codegen for each package.
    # When false: fall back to the source-text path via tools/embed-lua.ps1
    # (preserved for debugging + the rare case of needing the Lua source
    # available for runtime tooling like load() against embedded chunks).
    [bool]$Bytecode = $true
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $PackagesDir)) {
    throw "PackagesDir not found: $PackagesDir"
}

# ----- helpers -----------------------------------------------------------

function ConvertTo-PascalCase {
    param([string]$Name)
    # Split on dot or underscore, capitalize each part, join.
    $parts = $Name -split '[._]'
    ($parts | ForEach-Object {
        if ($_.Length -gt 0) {
            $_.Substring(0,1).ToUpperInvariant() + $_.Substring(1).ToLowerInvariant()
        }
    }) -join ''
}

function ConvertTo-UpperSnake {
    param([string]$Name)
    ($Name -replace '\.', '_').ToUpperInvariant()
}

function ConvertTo-LowerSnake {
    param([string]$Name)
    ($Name -replace '\.', '_').ToLowerInvariant()
}

# Parse package.lua to extract:
#   modules = { ["name"] = "file.lua", ... }
# Returns an ordered list of @{ Require=...; File=... }.
# If parsing fails or modules is absent, returns $null.
function Read-PackageManifest {
    param([string]$ManifestPath)
    if (-not (Test-Path $ManifestPath)) { return $null }
    $text = Get-Content -Raw -Path $ManifestPath
    # Find the modules = { ... } block. Match the opening brace
    # through the FIRST balanced closing brace (modules table is flat,
    # no nested braces in practice).
    $m = [regex]::Match($text, 'modules\s*=\s*\{([^}]*)\}', 'Singleline')
    if (-not $m.Success) { return $null }
    $body = $m.Groups[1].Value
    $entries = @()
    foreach ($em in [regex]::Matches($body, '\[\s*"([^"]+)"\s*\]\s*=\s*"([^"]+)"')) {
        $entries += @{ Require = $em.Groups[1].Value; File = $em.Groups[2].Value }
    }
    return $entries
}

# Parse package.lua's requires_native block:
#   requires_native = {
#       { dll = "sqlite3.dll", mode_default = "embed", env_var = "LUAVM_SQLITE_DLL" },
#       ...
#   }
# Returns a list of @{ Dll; ModeDefault; EnvVar }, empty when absent.
function Read-PackageNativeDeps {
    param([string]$ManifestPath)
    if (-not (Test-Path $ManifestPath)) { return @() }
    $text = Get-Content -Raw -Path $ManifestPath
    # Greedy match across nested braces -- requires_native typically
    # ends with `},` then `}` for the outer return. Walk balanced
    # braces manually to be safe.
    $idx = $text.IndexOf("requires_native")
    if ($idx -lt 0) { return @() }
    $eq = $text.IndexOf("=", $idx)
    if ($eq -lt 0) { return @() }
    $brace = $text.IndexOf("{", $eq)
    if ($brace -lt 0) { return @() }
    # Walk to matching closing brace.
    $depth = 1; $pos = $brace + 1
    while ($depth -gt 0 -and $pos -lt $text.Length) {
        $c = $text[$pos]
        if ($c -eq '{') { $depth++ }
        elseif ($c -eq '}') { $depth-- }
        $pos++
    }
    if ($depth -ne 0) { return @() }
    $body = $text.Substring($brace + 1, $pos - $brace - 2)
    $entries = @()
    # Each inner table: { dll = "x", mode_default = "y", env_var = "z" }.
    foreach ($em in [regex]::Matches($body, '\{[^}]*\}')) {
        $inner = $em.Value
        $dllM = [regex]::Match($inner, 'dll\s*=\s*"([^"]+)"')
        if (-not $dllM.Success) { continue }
        $modeM = [regex]::Match($inner, 'mode_default\s*=\s*"([^"]+)"')
        $envM  = [regex]::Match($inner, 'env_var\s*=\s*"([^"]+)"')
        $entries += @{
            Dll         = $dllM.Groups[1].Value
            ModeDefault = if ($modeM.Success) { $modeM.Groups[1].Value } else { "embed" }
            EnvVar      = if ($envM.Success)  { $envM.Groups[1].Value }  else { "" }
        }
    }
    return $entries
}

# ----- discover packages -------------------------------------------------

$pkgDirs = Get-ChildItem -Path $PackagesDir -Directory | Sort-Object Name
$allPkgs = @()  # list of @{ Require; LuaPath; FileBase; Symbol; KeyUpper }
$allNativeDeps = @()  # list of @{ Pkg; Dll; ModeDefault; EnvVar }

foreach ($dir in $pkgDirs) {
    $manifestPath = Join-Path $dir.FullName 'package.lua'
    $manifest = Read-PackageManifest -ManifestPath $manifestPath
    # File -> Require map from manifest (for override)
    $manifestByFile = @{}
    if ($manifest) {
        foreach ($e in $manifest) { $manifestByFile[$e.File] = $e.Require }
    }

    # Collect requires_native (each entry attached to this package's
    # base name -- sub-modules inherit the parent's native deps when
    # they share the dir's package.lua).
    foreach ($nd in (Read-PackageNativeDeps -ManifestPath $manifestPath)) {
        $allNativeDeps += @{
            Pkg         = $dir.Name
            Dll         = $nd.Dll
            ModeDefault = $nd.ModeDefault
            EnvVar      = $nd.EnvVar
        }
    }

    # Union of manifest entries + every .lua in the directory (init first,
    # then others). Manifest takes precedence on require-name choice;
    # files-on-disk are authoritative for what gets compiled (so newly
    # dropped windows/<area>.lua picks up the windows.<area> convention
    # without needing the manifest touched).
    $files = @()
    $initLua = Join-Path $dir.FullName 'init.lua'
    if (Test-Path $initLua) { $files += 'init.lua' }
    Get-ChildItem -Path $dir.FullName -Filter '*.lua' -File |
        Where-Object { $_.Name -ne 'init.lua' -and $_.Name -ne 'package.lua' } |
        ForEach-Object { $files += $_.Name }

    foreach ($f in $files) {
        if ($manifestByFile.ContainsKey($f)) {
            $require = $manifestByFile[$f]
        }
        elseif ($f -eq 'init.lua') {
            $require = $dir.Name
        }
        else {
            $sub = [System.IO.Path]::GetFileNameWithoutExtension($f)
            $require = "$($dir.Name).$sub"
        }
        $luaPath = "`$(SRC_DIR)/runtime/packages/$($dir.Name)/$f"
        $allPkgs += @{
            Require  = $require
            LuaPath  = $luaPath
            FileBase = ConvertTo-LowerSnake $require
            Symbol   = "g_Package$(ConvertTo-PascalCase $require)Lua"
            KeyUpper = ConvertTo-UpperSnake $require
        }
    }
}

# ----- emit Makefile fragment -------------------------------------------

$mk = New-Object System.Text.StringBuilder
[void]$mk.AppendLine('# AUTO-GENERATED by tools/gen-package-rules.ps1 -- DO NOT EDIT.')
[void]$mk.AppendLine('# Re-runs whenever any src/runtime/packages/**/*.lua changes.')
[void]$mk.AppendLine()

foreach ($p in $allPkgs) {
    $k = $p.KeyUpper
    $genC = "`$(GEN_DIR)/runtime/packages/$($p.FileBase)_pkg_gen.c"
    $obj  = "`$(BUILD_DIR)/obj/runtime/packages/$($p.FileBase)_pkg_gen.o"
    [void]$mk.AppendLine("PACKAGE_${k}_LUA   := $($p.LuaPath)")
    [void]$mk.AppendLine("PACKAGE_${k}_GEN_C := $genC")
    [void]$mk.AppendLine("PACKAGE_${k}_OBJ   := $obj")
    [void]$mk.AppendLine()
}

[void]$mk.AppendLine('PACKAGE_OBJS_AUTO := \')
for ($i = 0; $i -lt $allPkgs.Count; $i++) {
    $k = $allPkgs[$i].KeyUpper
    $sep = ' \'
    if ($i -eq $allPkgs.Count - 1) { $sep = '' }
    [void]$mk.AppendLine("    `$(PACKAGE_${k}_OBJ)$sep")
}
[void]$mk.AppendLine()

foreach ($p in $allPkgs) {
    $k = $p.KeyUpper
    if ($Bytecode) {
        # Bytecode path: precompile via embed_luac.exe. The .c output
        # holds bytecode bytes as a const char[] -- luaL_loadbuffer at
        # runtime detects the bytecode signature and skips parsing.
        [void]$mk.AppendLine("`$(PACKAGE_${k}_GEN_C): `$(PACKAGE_${k}_LUA) `$(BUILD_DIR)/embed_luac.exe | `$(GEN_DIR)/runtime/packages")
        [void]$mk.AppendLine("`t`$(BUILD_DIR)/embed_luac.exe `$(PACKAGE_${k}_LUA) `$@ $($p.Symbol)")
    } else {
        # Source path: embed plain text via the PS shim (legacy +
        # debug). Used when --no-bytecode-pkgs is set at gen-time.
        [void]$mk.AppendLine("`$(PACKAGE_${k}_GEN_C): `$(PACKAGE_${k}_LUA) `$(ROOT)/tools/embed-lua.ps1 | `$(GEN_DIR)/runtime/packages")
        [void]$mk.AppendLine("`tpowershell -NoProfile -ExecutionPolicy Bypass -File `$(ROOT)/tools/embed-lua.ps1 -InputPath `$(PACKAGE_${k}_LUA) -OutputPath `$@ -SymbolName $($p.Symbol)")
    }
    [void]$mk.AppendLine("`$(PACKAGE_${k}_OBJ): `$(PACKAGE_${k}_GEN_C) | `$(BUILD_DIR)/obj/runtime/packages")
    [void]$mk.AppendLine("`t`$(CC) `$(CFLAGS) -c `$< -o `$@")
    [void]$mk.AppendLine()
}

# ----- emit C header ----------------------------------------------------

$hdr = New-Object System.Text.StringBuilder
[void]$hdr.AppendLine('/* AUTO-GENERATED by tools/gen-package-rules.ps1 -- DO NOT EDIT.')
[void]$hdr.AppendLine('   Mirrors the on-disk layout of src/runtime/packages/. The compiler')
[void]$hdr.AppendLine('   resolver consults this list to skip filesystem lookups for names')
[void]$hdr.AppendLine('   that the runtime registers via package.preload. */')
[void]$hdr.AppendLine('#ifndef LUAVM_BUILTIN_PACKAGES_H')
[void]$hdr.AppendLine('#define LUAVM_BUILTIN_PACKAGES_H')
[void]$hdr.AppendLine()
[void]$hdr.AppendLine('static const char *const k_BuiltinPackages[] = {')
foreach ($p in $allPkgs) {
    [void]$hdr.AppendLine("    `"$($p.Require)`",")
}
[void]$hdr.AppendLine('    NULL')
[void]$hdr.AppendLine('};')
[void]$hdr.AppendLine()
[void]$hdr.AppendLine('#endif')

# ----- write only if changed --------------------------------------------

function Write-IfChanged {
    param([string]$Path, [string]$Content)
    $parent = Split-Path -Parent $Path
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $existing = $null
    if (Test-Path $Path) {
        $existing = Get-Content -Raw -Path $Path
    }
    if ($existing -ne $Content) {
        # -Encoding UTF8 in PS 5.1 writes BOM; for .mk and .h we want
        # no BOM. Use .NET IO with UTF8Encoding($false).
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
        Write-Host "[+] wrote $Path"
    }
    else {
        Write-Host "[*] unchanged $Path"
    }
}

Write-IfChanged -Path $OutMk     -Content $mk.ToString()
Write-IfChanged -Path $OutHeader -Content $hdr.ToString()

# Optional native-deps header. The compiler reads this to decide
# what DLLs to embed / sidecar / system-load per required package.
if ($OutNativeDepsHeader) {
    $nd = New-Object System.Text.StringBuilder
    [void]$nd.AppendLine('/* AUTO-GENERATED by tools/gen-package-rules.ps1 -- DO NOT EDIT.')
    [void]$nd.AppendLine('   Per-builtin-package native DLL requirements. The compiler walks')
    [void]$nd.AppendLine('   this table for every required package to decide which DLLs to')
    [void]$nd.AppendLine('   embed, copy as sidecars, or assume on PATH. Each row is one')
    [void]$nd.AppendLine('   (package, dll, default-mode, env-override-var). */')
    [void]$nd.AppendLine('#ifndef LUAVM_BUILTIN_NATIVE_DEPS_H')
    [void]$nd.AppendLine('#define LUAVM_BUILTIN_NATIVE_DEPS_H')
    [void]$nd.AppendLine()
    [void]$nd.AppendLine('typedef struct {')
    [void]$nd.AppendLine('    const char *PkgName;')
    [void]$nd.AppendLine('    const char *Dll;')
    [void]$nd.AppendLine('    const char *ModeDefault;  /* "embed" | "sidecar" | "system" */')
    [void]$nd.AppendLine('    const char *EnvVar;       /* optional override env var; "" if none */')
    [void]$nd.AppendLine('} BUILTIN_NATIVE_DEP_T;')
    [void]$nd.AppendLine()
    [void]$nd.AppendLine('static const BUILTIN_NATIVE_DEP_T k_BuiltinNativeDeps[] = {')
    foreach ($d in $allNativeDeps) {
        $env = if ($d.EnvVar) { $d.EnvVar } else { "" }
        [void]$nd.AppendLine("    { `"$($d.Pkg)`", `"$($d.Dll)`", `"$($d.ModeDefault)`", `"$env`" },")
    }
    [void]$nd.AppendLine('    { (const char *)0, (const char *)0, (const char *)0, (const char *)0 }')
    [void]$nd.AppendLine('};')
    [void]$nd.AppendLine()
    [void]$nd.AppendLine('#endif')
    Write-IfChanged -Path $OutNativeDepsHeader -Content $nd.ToString()
    Write-Host "[+] $($allNativeDeps.Count) native deps registered"
}

Write-Host "[+] $($allPkgs.Count) packages registered"
