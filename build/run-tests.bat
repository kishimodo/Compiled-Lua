@echo off
rem CLua test runner. Builds the products (including aotc.exe -- the
rem differential layers compile every test to a native exe and diff it against
rem the interpreter oracle), then runs the auto-discovering Lua test runner
rem (tools\run-tests.lua), which compiles + runs every test under tests\
rem (unit / lua / packages / differential / conformance) plus the tools\
rem behavioral suites, and prints one PASS/FAIL/SKIP tally. Returns non-zero
rem on any failure.
rem
rem PATH: prepend GnuWin32 make + the MinGW bin so gcc/ar/make are found (same as
rem build.bat). Override CLUA_MINGW_BIN / CLUA_MAKE_BIN if your bundle differs.
if not defined CLUA_MINGW_BIN set "CLUA_MINGW_BIN=C:\Users\world\Downloads\gcc-15.2.0-gdb-16.3.90.20250511-binutils-2.45-mingw-w64-v13.0.0-ucrt\bin"
if not defined CLUA_MAKE_BIN  set "CLUA_MAKE_BIN=C:\Program Files (x86)\GnuWin32\bin"
set "PATH=%CLUA_MAKE_BIN%;%CLUA_MINGW_BIN%;%PATH%"

rem Fail fast with a clear message if the toolchain isn't on PATH, rather
rem than letting make/gcc surface a cryptic "not recognized" mid-build.
where make >nul 2>nul
if errorlevel 1 (
    echo [-] 'make' not found on PATH. Install GnuWin32 make or set CLUA_MAKE_BIN
    echo     to the folder containing make.exe ^(currently: "%CLUA_MAKE_BIN%"^).
    exit /b 1
)
where x86_64-w64-mingw32-gcc >nul 2>nul
if errorlevel 1 (
    echo [-] MinGW gcc ^(x86_64-w64-mingw32-gcc^) not found on PATH. Install MinGW-w64
    echo     or set CLUA_MINGW_BIN to its bin folder ^(currently: "%CLUA_MINGW_BIN%"^).
    exit /b 1
)

pushd %~dp0..

echo [*] building products (compiler, luavm, embedded)...
rem `embedded` = lua-embedded + runtime-embedded + packages-embedded. The package
rem tests compile via compiler.exe, which LINKS runtime-embedded.a +
rem liblua54-embedded.a; building only `packages-embedded` leaves those archives
rem missing after a `clean`, and every package test then fails to link with
rem "cannot find build/bin/runtime-embedded.a".
make -f build/Makefile compiler luavm embedded luac-objs
if errorlevel 1 (
    echo [-] product build failed
    set RC=1
    goto :done
)

rem aotc.exe + aot_entry.o: the compiled-vs-interpreter layers (lua behavioral,
rem differential, conformance, fuzz smoke) aotc-compile each test into a PE.
make -f build/Makefile.luac aotc aot-entry
if errorlevel 1 (
    echo [-] aotc build failed
    set RC=1
    goto :done
)

echo [*] running test suite...
build\bin\luavm.exe tools\run-tests.lua
set RC=%ERRORLEVEL%

:done
popd
exit /b %RC%
