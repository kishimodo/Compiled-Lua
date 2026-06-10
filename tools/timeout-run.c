/* timeout-run.c -- run a command with a hard wall-clock deadline.
 *
 *   timeout-run.exe <timeout_ms> <command line...>
 *
 * Exit code: the child's exit code, or 124 if the deadline fired (GNU
 * `timeout` convention; the test runner reports that as a TIMEOUT failure).
 *
 * The child command line is taken VERBATIM from this process's own command
 * line (GetCommandLineW, skipping argv[0] and the timeout argument) so
 * embedded quoting survives untouched -- argv re-joining would mangle paths
 * with spaces. The child is placed in a kill-on-close Job Object so a timeout
 * terminates the ENTIRE process tree (a test that spawns compiler.exe or a
 * compiled test exe must not leave orphans wedging the suite). Std handles
 * are inherited, so cmd.exe redirections (2>&1 into the runner's io.popen
 * pipe) flow through to the child unchanged.
 *
 * Built lazily by tools/run-tests.lua with the same MinGW gcc used for the
 * C unit tests; if the build fails the runner just runs unguarded (warned).
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

/* Advance past one command-line token (quoted or bare) + trailing spaces. */
static wchar_t *SkipToken( wchar_t *P ) {
    if ( *P == L'"' ) {
        P++;
        while ( *P != L'\0' && *P != L'"' ) P++;
        if ( *P == L'"' ) P++;
    } else {
        while ( *P != L'\0' && *P != L' ' && *P != L'\t' ) P++;
    }
    while ( *P == L' ' || *P == L'\t' ) P++;
    return P;
}

int wmain( void ) {
    wchar_t *Cl = GetCommandLineW( );

    /* Skip our own (possibly quoted) program name. */
    wchar_t *P = SkipToken( Cl );

    /* Parse the timeout (milliseconds). */
    wchar_t *End   = NULL;
    unsigned long TimeoutMs = wcstoul( P, &End, 10 );
    if ( End == P || TimeoutMs == 0 ) {
        fwprintf( stderr, L"usage: timeout-run.exe <timeout_ms> <command...>\n" );
        return 125;
    }
    P = End;
    while ( *P == L' ' || *P == L'\t' ) P++;
    if ( *P == L'\0' ) {
        fwprintf( stderr, L"timeout-run: no command given\n" );
        return 125;
    }

    /* Kill-on-close job: a timeout (or our own death) reaps the whole tree. */
    HANDLE Job = CreateJobObjectW( NULL, NULL );
    if ( Job != NULL ) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION Limits = { 0 };
        Limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject( Job, JobObjectExtendedLimitInformation,
                                 &Limits, sizeof( Limits ) );
    }

    STARTUPINFOW Si = { 0 };
    Si.cb         = sizeof( Si );
    Si.dwFlags    = STARTF_USESTDHANDLES;
    Si.hStdInput  = GetStdHandle( STD_INPUT_HANDLE );
    Si.hStdOutput = GetStdHandle( STD_OUTPUT_HANDLE );
    Si.hStdError  = GetStdHandle( STD_ERROR_HANDLE );

    PROCESS_INFORMATION Pi = { 0 };
    /* CREATE_SUSPENDED so the child is inside the job BEFORE it can spawn
       grandchildren that would otherwise escape it. */
    if ( !CreateProcessW( NULL, P, NULL, NULL, TRUE,
                          CREATE_SUSPENDED, NULL, NULL, &Si, &Pi ) ) {
        fwprintf( stderr, L"timeout-run: CreateProcess failed (err=%lu): %ls\n",
                  GetLastError( ), P );
        if ( Job != NULL ) CloseHandle( Job );
        return 126;
    }
    if ( Job != NULL ) AssignProcessToJobObject( Job, Pi.hProcess );
    ResumeThread( Pi.hThread );
    CloseHandle( Pi.hThread );

    DWORD ExitCode = 124;
    DWORD Wait     = WaitForSingleObject( Pi.hProcess, TimeoutMs );
    if ( Wait == WAIT_OBJECT_0 ) {
        GetExitCodeProcess( Pi.hProcess, &ExitCode );
    } else {
        fwprintf( stderr, L"timeout-run: deadline (%lu ms) exceeded -- killing process tree\n",
                  TimeoutMs );
        if ( Job != NULL ) TerminateJobObject( Job, 124 );
        else               TerminateProcess( Pi.hProcess, 124 );
        WaitForSingleObject( Pi.hProcess, 5000 );
        ExitCode = 124;
    }

    CloseHandle( Pi.hProcess );
    if ( Job != NULL ) CloseHandle( Job );  /* kill-on-close reaps any stragglers */
    return ( int )ExitCode;
}
