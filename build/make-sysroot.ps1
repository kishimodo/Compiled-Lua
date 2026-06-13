# make-sysroot.ps1 -DestDir <dir>
# Snapshot the MinGW CRT pieces the internal linker (LcPe_Link, --ld=internal)
# links, into <DestDir>. Each piece is located ONCE via gcc -print-file-name=,
# so internal-mode user builds need no gcc afterwards. Requires the MinGW bin on
# PATH (build-luac.bat / run-tests.bat already arrange that), or $env:CLUA_GCC.
param([Parameter(Mandatory=$true)][string]$DestDir)

$gcc = if ($env:CLUA_GCC) { $env:CLUA_GCC } else { "x86_64-w64-mingw32-gcc" }
$pieces = @(
  "crt2.o","crtbegin.o","crtend.o",
  "libmingw32.a","libgcc.a","libmoldname.a","libmingwex.a","libmsvcrt.a",
  "libadvapi32.a","libshell32.a","libuser32.a","libkernel32.a","libucrt.a"
)
if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Force $DestDir | Out-Null }

$n = 0
foreach ($p in $pieces) {
  $resolved = & $gcc "-print-file-name=$p" 2>$null
  if ($resolved -and (Test-Path $resolved) -and ($resolved -ne $p)) {
    Copy-Item $resolved (Join-Path $DestDir $p) -Force
    $n++
  } else {
    Write-Host "[-] sysroot: could not locate $p (got '$resolved')"
  }
}
$sz = (Get-ChildItem $DestDir | Measure-Object Length -Sum).Sum
Write-Host ("[+] sysroot: {0} CRT pieces ({1:N1} MB) -> {2}" -f $n, ($sz/1MB), $DestDir)
exit 0
