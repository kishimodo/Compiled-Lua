@echo off
rem CLua differential fuzz campaign: generates seeded deterministic Lua
rem programs, aotc-compiles each at -O1, and diffs the compiled exe's stdout
rem against the bytecode interpreter (luavm.exe -i).
rem
rem   build\run-fuzz.bat [start_seed] [count]
rem
rem Defaults: start_seed=1 count=1000. Divergent cases are saved to
rem tests\fuzz-failures\ ready for triage/promotion (see the fuzzer header).
rem The products must already be built (build\build-luac.bat) -- the fixed
rem 25-seed smoke slice runs inside build\run-tests.bat on every test run.

setlocal
set "START=%~1"
set "COUNT=%~2"
if "%START%"=="" set "START=1"
if "%COUNT%"=="" set "COUNT=1000"

pushd %~dp0..
if not exist build\bin\luavm.exe (
    echo [-] build\bin\luavm.exe not found -- run build\build-luac.bat first
    popd & exit /b 1
)
if not exist build\bin\aotc.exe (
    echo [-] build\bin\aotc.exe not found -- run build\build-luac.bat first
    popd & exit /b 1
)
build\bin\luavm.exe tools\fuzz-differential.lua %START% %COUNT%
set RC=%ERRORLEVEL%
popd
exit /b %RC%
