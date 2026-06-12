@echo off
rem build-luac.bat -- build build/bin/aotc.exe (the LuaC AOT compiler driver).
rem
rem Mirrors build/run-tests.bat's PATH setup (GnuWin32 make + MinGW bin), then:
rem   1. builds the base products/objects aotc links against
rem      (liblua54.a via `lua`, the front-end objs via `compiler`, the backend
rem       objs via `luac-objs`, plus luavm.exe + embedded archives so the
rem       differential oracle + the emitted-PE archives exist), then
rem   2. links aotc.exe via build/Makefile.luac.
if not defined LUAVM_MINGW_BIN set "LUAVM_MINGW_BIN=C:\Users\world\Downloads\gcc-15.2.0-gdb-16.3.90.20250511-binutils-2.45-mingw-w64-v13.0.0-ucrt\bin"
if not defined LUAVM_MAKE_BIN  set "LUAVM_MAKE_BIN=C:\Program Files (x86)\GnuWin32\bin"
set "PATH=%LUAVM_MAKE_BIN%;%LUAVM_MINGW_BIN%;%PATH%"

where make >nul 2>nul
if errorlevel 1 (
    echo [-] 'make' not found on PATH. Install GnuWin32 make or set LUAVM_MAKE_BIN
    echo     to the folder containing make.exe ^(currently: "%LUAVM_MAKE_BIN%"^).
    exit /b 1
)
where x86_64-w64-mingw32-gcc >nul 2>nul
if errorlevel 1 (
    echo [-] MinGW gcc ^(x86_64-w64-mingw32-gcc^) not found on PATH. Install MinGW-w64
    echo     or set LUAVM_MINGW_BIN to its bin folder ^(currently: "%LUAVM_MINGW_BIN%"^).
    exit /b 1
)

pushd %~dp0..

echo [*] building base products (lua, compiler front-end, backend objs, luavm, embedded)...
make -f build/Makefile lua compiler luac-objs luavm embedded
if errorlevel 1 (
    echo [-] base product build failed
    set RC=1
    goto :done
)

echo [*] linking aotc.exe + clua.exe (+ aot_entry.o, rover.exe)...
make -f build/Makefile.luac aotc aot-entry clua rover
set RC=%ERRORLEVEL%

:done
popd
exit /b %RC%
