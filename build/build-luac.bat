@echo off
rem build-luac.bat -- build build/bin/aotc.exe (the LuaC AOT compiler driver).
rem
rem Mirrors build/run-tests.bat's PATH setup (GnuWin32 make + MinGW bin), then:
rem   1. builds the base products/objects aotc links against
rem      (liblua54.a via `lua`, the front-end objs via `compiler`, the backend
rem       objs via `luac-objs`, plus clua-interp.exe + embedded archives so the
rem       differential oracle + the emitted-PE archives exist), then
rem   2. links aotc.exe via build/Makefile.luac.
if not defined CLUA_MINGW_BIN set "CLUA_MINGW_BIN=C:\Users\world\Downloads\gcc-15.2.0-gdb-16.3.90.20250511-binutils-2.45-mingw-w64-v13.0.0-ucrt\bin"
if not defined CLUA_MAKE_BIN  set "CLUA_MAKE_BIN=C:\Program Files (x86)\GnuWin32\bin"
set "PATH=%CLUA_MAKE_BIN%;%CLUA_MINGW_BIN%;%PATH%"

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

echo [*] building base products (lua, compiler front-end, backend objs, clua-interp, embedded)...
make -f build/Makefile lua compiler luac-objs clua-interp embedded
if errorlevel 1 (
    echo [-] base product build failed
    set RC=1
    goto :done
)

echo [*] linking aotc.exe + clua.exe (+ aot_entry.o)...
make -f build/Makefile.luac aotc aot-entry clua
if errorlevel 1 (
    echo [-] aotc/clua build failed
    set RC=1
    goto :done
)

rem The internal linker is now the DEFAULT, so build the CRT sysroot snapshot
rem BEFORE rover.exe (rover links via clua.exe, which now defaults to the
rem built-in linker and needs lib\sysroot / build\bin\sysroot).
echo [*] building CRT sysroot (build\bin\sysroot) for the default internal linker...
make -f build/Makefile.luac sysroot
if errorlevel 1 (
    echo [-] sysroot build failed
    set RC=1
    goto :done
)

echo [*] building rover.exe (via the default internal linker)...
make -f build/Makefile.luac rover
set RC=%ERRORLEVEL%

:done
popd
exit /b %RC%
