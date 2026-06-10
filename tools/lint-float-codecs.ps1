# tools/lint-float-codecs.ps1
#
# Flags packages that hand-roll IEEE-754 binary32/binary64 (de)serialization
# instead of using the canonical, exact, endian-explicit string codecs:
#
#     encode 8 bytes : string.pack(">d", n)   / "<d"
#     decode 8 bytes : string.unpack(">d", s, p)
#     encode 4 bytes : string.pack(">f", n)
#     decode 4 bytes : string.unpack(">f", s, p)
#
# Hand-rolled float codecs (math.frexp / math.ldexp combined with bit shifts,
# *2^32 / *4294967296 mantissa assembly, >>52 exponent extraction, etc.) are
# error-prone: the historic msgpack r_f64 bug corrupted EVERY binary64 value
# because the 52-bit mantissa was reassembled with the wrong byte grouping.
#
# This linter does NOT auto-fix. It lists every src/runtime/packages/*/init.lua
# that still contains hand-rolled float-codec signals, with the matched lines,
# so new packages adopting the same anti-pattern get caught in review.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/lint-float-codecs.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools/lint-float-codecs.ps1 -PackagesDir src/runtime/packages
#
# Exit code: 0 always (advisory). Use -Strict to exit 1 when any hits are found.

param(
    [string]$PackagesDir = "src/runtime/packages",
    [switch]$Strict
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $PackagesDir)) {
    Write-Error "PackagesDir not found: $PackagesDir"
    exit 2
}

# Signals that strongly indicate hand-rolled IEEE-754 float (de)serialization.
# Each entry: a label + a regex. We require at least one "mantissa/exponent
# arithmetic" signal AND the file to be plausibly doing byte<->float work, but
# to keep this a simple, dependable grep we just collect any signal hit and
# report per-file. The constants below are the classic magic numbers:
#   4294967296          = 2^32   (mantissa middle-group multiplier)
#   281474976710656     = 2^48
#   4503599627370496    = 2^52   (implicit mantissa bit for binary64)
#   8388608 / 0x800000  = 2^23   (implicit mantissa bit for binary32)
$signals = @(
    @{ Label = "math.frexp";          Pattern = 'math\.frexp' },
    @{ Label = "math.ldexp";          Pattern = 'math\.ldexp' },
    @{ Label = "2^32 mantissa mul";   Pattern = '4294967296' },
    @{ Label = "2^48 mantissa mul";   Pattern = '281474976710656' },
    @{ Label = "2^52 implicit bit";   Pattern = '4503599627370496' },
    @{ Label = "*2^32 literal";       Pattern = '\*\s*2\s*\^\s*32' },
    @{ Label = "*2^52 literal";       Pattern = '\*\s*2\s*\^\s*52' },
    @{ Label = ">>52 exponent shift"; Pattern = '>>\s*52' },
    @{ Label = "0x800000 (2^23)";     Pattern = '0x800000\b' }
)

# Patterns that are the SANCTIONED codec -- if a file uses string.(un)pack with
# a float format we still report frexp/ldexp usage (it may be a fallback), but
# we annotate whether the canonical codec is also present.
$canonicalPattern = 'string\.(pack|unpack)\s*\(\s*"[<>]?[df]'

$dirs = Get-ChildItem -Path $PackagesDir -Directory | Sort-Object Name
$offenders = @()

foreach ($dir in $dirs) {
    $init = Join-Path $dir.FullName "init.lua"
    if (-not (Test-Path $init)) { continue }
    $lines = Get-Content -Path $init

    $hits = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        foreach ($sig in $signals) {
            if ($line -match $sig.Pattern) {
                $hits += [pscustomobject]@{
                    Line  = $i + 1
                    Label = $sig.Label
                    Text  = $line.Trim()
                }
            }
        }
    }

    if ($hits.Count -gt 0) {
        $hasCanonical = ($lines -match $canonicalPattern).Count -gt 0
        $offenders += [pscustomobject]@{
            Package      = $dir.Name
            Path         = $init -replace '\\', '/'
            Hits         = $hits
            HasCanonical = $hasCanonical
        }
    }
}

Write-Host "== lint-float-codecs =="
Write-Host "scanned $($dirs.Count) package directories under $PackagesDir"
Write-Host ""

if ($offenders.Count -eq 0) {
    Write-Host "[+] no hand-rolled IEEE-754 float codecs found."
    exit 0
}

Write-Host "[-] $($offenders.Count) package(s) still hand-roll float (de)serialization:"
Write-Host ""
foreach ($o in $offenders) {
    $note = if ($o.HasCanonical) { " (also uses string.pack/unpack -- frexp/ldexp may be a fallback)" } else { "" }
    Write-Host ("  {0}  [{1}]{2}" -f $o.Package, $o.Path, $note)
    foreach ($h in $o.Hits) {
        Write-Host ("      L{0,-5} {1,-22} {2}" -f $h.Line, $h.Label, $h.Text)
    }
    Write-Host ""
}

Write-Host ("summary: " + (($offenders | ForEach-Object { $_.Package }) -join ", "))

if ($Strict) { exit 1 } else { exit 0 }
