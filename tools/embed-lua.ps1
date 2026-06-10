# tools/embed-lua.ps1 -- embed a .lua file as a const C string literal.
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/embed-lua.ps1 `
#       -InputPath src/runtime/preload/windows.lua `
#       -OutputPath build/gen/runtime/preload/windows_embed_gen.c `
#       -SymbolName g_EmbeddedWindowsLua

param(
    [Parameter(Mandatory=$true)][string]$InputPath,
    [Parameter(Mandatory=$true)][string]$OutputPath,
    [Parameter(Mandatory=$true)][string]$SymbolName
)

$lines = Get-Content -Path $InputPath -Encoding UTF8

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("/* AUTO-GENERATED from $(Split-Path $InputPath -Leaf). DO NOT EDIT. */")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("const char ${SymbolName}[] =")
foreach ($line in $lines) {
    # Escape backslash first, then double-quote. Both are literal-character
    # replacements (no regex metachars in the search string).
    $escaped = $line.Replace('\', '\\').Replace('"', '\"')
    [void]$sb.AppendLine("    `"${escaped}\n`"")
}
[void]$sb.AppendLine(";")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("const unsigned int ${SymbolName}_len = sizeof(${SymbolName}) - 1;")

# Ensure output directory exists.
$outDir = Split-Path -Parent $OutputPath
if ($outDir -and -not (Test-Path -Path $outDir)) {
    New-Item -ItemType Directory -Force -Path $outDir | Out-Null
}

# Write atomically (single Set-Content call). ASCII keeps the file plain
# 7-bit and avoids a BOM that the C compiler would choke on.
$sb.ToString() | Set-Content -Path $OutputPath -Encoding ASCII -NoNewline
