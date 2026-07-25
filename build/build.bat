@echo off
rem CLua build wrapper. Forwards arguments to `make -f build/Makefile`.
rem PATH adjustment: GnuWin32's GNU make and the MinGW binutils (objcopy, ld)
rem are prepended so they win over Embarcadero's same-named tools which sit
rem earlier on the default user PATH. Adjust CLUA_MINGW_BIN if your MinGW
rem bundle is somewhere else.
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

pushd "%~dp0.."
make -f build/Makefile %*
set RC=%ERRORLEVEL%
popd
exit /b %RC%
