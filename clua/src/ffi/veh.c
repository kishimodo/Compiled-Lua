/*!
 * @brief
 *  VEH region table + recovery longjmp. The handler itself is added in
 *  Task 2; Task 4 wires the AddVectoredExceptionHandler call.
 */

#include "ffi/veh.h"

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VEH_REGION_MAX 64

static PVOID g_VehHandle = NULL;

typedef struct {
    uintptr_t  Start;
    uintptr_t  End;     /* exclusive */
} REGION_T;

static REGION_T  g_Regions[ VEH_REGION_MAX ];
static int       g_NumRegions = { 0 };

/* THREAD-LOCAL: per-OS-thread JIT recovery frame (see veh.h). In the AOT
   runtime, storage is a Win32 TLS slot -- `__thread` would drag in gcc's
   emutls (and its pthread/winpthread tail) which the lean internal linker
   cannot resolve. The interpreter (GCC link) uses a plain `__thread`. The slot
   is allocated lazily on the first SET, which always happens on the main thread
   at startup before any worker can spawn, so no race. */
#if defined( LUAC_AOT_RUNTIME )
#include "jit/tls_slot.h"
static volatile LONG g_JitFrameSlot = ( LONG )TLS_OUT_OF_INDEXES;
PJIT_FRAME_T Veh_GetJitFrame( void ) {
    DWORD slot = ( DWORD )g_JitFrameSlot;
    if ( slot == TLS_OUT_OF_INDEXES ) return NULL;
    return ( PJIT_FRAME_T )TlsGetValue( slot );
}
void Veh_SetJitFrame( PJIT_FRAME_T Frame ) {
    DWORD slot = CluaTls_Ensure( &g_JitFrameSlot );
    if ( slot != TLS_OUT_OF_INDEXES ) TlsSetValue( slot, Frame );
}
#else
static __thread PJIT_FRAME_T g_JitFrameTls = NULL;
PJIT_FRAME_T Veh_GetJitFrame( void )           { return g_JitFrameTls; }
void         Veh_SetJitFrame( PJIT_FRAME_T F ) { g_JitFrameTls = F; }
#endif

/* Weak forward decl so tests that link veh.o without dispatch.o still resolve.
   When dispatch.o is linked, this binds to the real implementation; otherwise
   the symbol address is NULL and the source-line lookup is skipped. */
__attribute__( ( weak ) )
int Jit_LookupSourceLine( void *Rip, const char **OutSource, int *OutLine );

/* Binary search: find the index of the region containing Addr, or -1. */
static int RegionLookup( uintptr_t Addr ) {
    int Lo = 0;
    int Hi = g_NumRegions - 1;
    while ( Lo <= Hi ) {
        int Mid = ( Lo + Hi ) / 2;
        if ( Addr < g_Regions[ Mid ].Start ) {
            Hi = Mid - 1;
        } else if ( Addr >= g_Regions[ Mid ].End ) {
            Lo = Mid + 1;
        } else {
            return Mid;
        }
    }
    return -1;
}

int Veh_IsCodeRegion( void *Addr ) {
    return RegionLookup( ( uintptr_t )Addr ) >= 0;
}

int Veh_RegisterRegion( void *Start, size_t Size ) {
    if ( Start == NULL || Size == 0 ) return 0;
    if ( g_NumRegions >= VEH_REGION_MAX ) return 0;

    uintptr_t S = ( uintptr_t )Start;
    uintptr_t E = S + Size;

    /* Find insertion index. Reject if duplicate Start. */
    int Idx = 0;
    while ( Idx < g_NumRegions && g_Regions[ Idx ].Start < S ) Idx++;
    if ( Idx < g_NumRegions && g_Regions[ Idx ].Start == S ) return 0;

    /* Shift later entries right. */
    if ( Idx < g_NumRegions ) {
        memmove( &g_Regions[ Idx + 1 ], &g_Regions[ Idx ],
                 ( size_t )( g_NumRegions - Idx ) * sizeof( REGION_T ) );
    }
    g_Regions[ Idx ].Start = S;
    g_Regions[ Idx ].End   = E;
    g_NumRegions++;
    return 1;
}

int Veh_UnregisterRegion( void *Start ) {
    uintptr_t S = ( uintptr_t )Start;
    int I = { 0 };
    for ( I = 0; I < g_NumRegions; I++ ) {
        if ( g_Regions[ I ].Start == S ) {
            if ( I + 1 < g_NumRegions ) {
                memmove( &g_Regions[ I ], &g_Regions[ I + 1 ],
                         ( size_t )( g_NumRegions - I - 1 ) * sizeof( REGION_T ) );
            }
            g_NumRegions--;
            return 1;
        }
    }
    return 0;
}

/*!
 * @brief
 *  Decide whether the fault is one we should catch + recover from.
 *  Returns 1 = recoverable (caller should longjmp), 0 = passthrough.
 *
 *  Catch policy:
 *  - AV / DIV0 / INT_OVERFLOW / ILLEGAL_INSTR — only if RIP is in a
 *    registered code region
 *  - STACK_OVERFLOW — always (the catch happens before the unwinder
 *    consumes more stack)
 *  - C++ exceptions (0xE06D7363), Ctrl-C (0x40010005), BREAKPOINT,
 *    SINGLE_STEP — never (let the debugger / language handle them)
 */
int Veh_ClassifyFault( PEXCEPTION_POINTERS Pointers ) {
    if ( Pointers == NULL || Pointers->ExceptionRecord == NULL ) return 0;
    DWORD  Code = Pointers->ExceptionRecord->ExceptionCode;
    void  *Rip  = Pointers->ExceptionRecord->ExceptionAddress;

    switch ( Code ) {
        case EXCEPTION_STACK_OVERFLOW:
            return 1;
        case EXCEPTION_ACCESS_VIOLATION:
        case EXCEPTION_INT_DIVIDE_BY_ZERO:
        case EXCEPTION_INT_OVERFLOW:
        case EXCEPTION_ILLEGAL_INSTRUCTION:
            return Veh_IsCodeRegion( Rip );
        default:
            return 0;
    }
}

void Veh_TriggerRecovery( const char *Message ) {
    PJIT_FRAME_T Frame = Veh_GetJitFrame( );
    if ( Frame == NULL ) {
        /* No JIT frame to recover into — print and abort. */
        fprintf( stderr, "[-] Veh_TriggerRecovery without JIT frame: %s\n",
                 Message ? Message : "(no message)" );
        abort( );
    }
    if ( Message != NULL ) {
        strncpy( Frame->FaultMessage, Message,
                 sizeof( Frame->FaultMessage ) - 1 );
        Frame->FaultMessage[ sizeof( Frame->FaultMessage ) - 1 ] = '\0';
    }
    longjmp( Frame->RecoveryJmp, 1 );
}

/*!
 * @brief
 *  Recovery trampoline invoked by redirecting RIP in the VEH CONTEXT record.
 *  Entered via a context-switch (not CALL), so there is no return address
 *  on the stack. Naked to suppress the compiler prologue.
 *
 *  Manually restores all callee-saved registers from the MinGW-w64 jmp_buf
 *  (_JUMP_BUFFER layout, x86-64) and jumps directly to the saved RIP — no
 *  call to UCRT longjmp, which would invoke RtlUnwindEx and could fault.
 *
 *  _JUMP_BUFFER field offsets (all uint64, from start of jmp_buf):
 *    +0   Frame
 *    +8   Rbx
 *    +16  Rsp
 *    +24  Rbp
 *    +32  Rsi
 *    +40  Rdi
 *    +48  R12
 *    +56  R13
 *    +64  R14
 *    +72  R15
 *    +80  Rip  (setjmp return address)
 *
 *  g_CurrentJitFrame->RecoveryJmp is the first field of JIT_FRAME_T (offset 0),
 *  so &RecoveryJmp == g_CurrentJitFrame.
 */
__attribute__( ( naked ) )
static void Veh_RecoveryTrampoline( void ) {
    __asm__ volatile (
        /* R11 = g_CurrentJitFrame = &RecoveryJmp (jmp_buf, first field). The VEH
         * handler set R11 in ContextRecord before redirecting here, because
         * g_CurrentJitFrame is now thread-local and cannot be read RIP-relative
         * from this thread-agnostic stub. */

        /* Restore callee-saved integer registers from the jmp_buf. */
        "movq   8(%%r11), %%rbx\n"   /* Rbx */
        "movq  24(%%r11), %%rbp\n"   /* Rbp */
        "movq  32(%%r11), %%rsi\n"   /* Rsi */
        "movq  40(%%r11), %%rdi\n"   /* Rdi */
        "movq  48(%%r11), %%r12\n"   /* R12 */
        "movq  56(%%r11), %%r13\n"   /* R13 */
        "movq  64(%%r11), %%r14\n"   /* R14 */
        "movq  72(%%r11), %%r15\n"   /* R15 */

        /* Load saved Rip into R10 before switching stacks. */
        "movq  80(%%r11), %%r10\n"   /* Rip (setjmp return address) */

        /* Switch to the saved stack. After this RSP is valid. */
        "movq  16(%%r11), %%rsp\n"   /* Rsp */

        /* setjmp return value = 1 (non-zero → longjmp branch taken). */
        "mov   $1, %%eax\n"

        /* Jump directly to the saved Rip — equivalent to returning 1 from
         * setjmp. R11 is a scratch register in the Win64 ABI. */
        "jmpq  *%%r10\n"
        :
        :
        :
    );
}

static LONG WINAPI Runtime_VehHandler( PEXCEPTION_POINTERS Pointers ) {
    if ( !Veh_ClassifyFault( Pointers ) ) {
        return EXCEPTION_CONTINUE_SEARCH;
    }

    /* Format a descriptive message for the Lua error. */
    char  Msg[ 192 ];
    DWORD Code = Pointers->ExceptionRecord->ExceptionCode;
    void *Rip  = Pointers->ExceptionRecord->ExceptionAddress;

    switch ( Code ) {
        case EXCEPTION_ACCESS_VIOLATION: {
            ULONG_PTR ReadOrWrite = 0;
            ULONG_PTR Addr        = 0;
            if ( Pointers->ExceptionRecord->NumberParameters >= 2 ) {
                ReadOrWrite = Pointers->ExceptionRecord->ExceptionInformation[ 0 ];
                Addr        = Pointers->ExceptionRecord->ExceptionInformation[ 1 ];
            }
            snprintf( Msg, sizeof( Msg ),
                      "access violation %s 0x%016llX at RIP 0x%016llX",
                      ReadOrWrite ? "writing" : "reading",
                      ( unsigned long long )Addr,
                      ( unsigned long long )( uintptr_t )Rip );
            break;
        }
        case EXCEPTION_INT_DIVIDE_BY_ZERO:
            snprintf( Msg, sizeof( Msg ),
                      "integer divide by zero at RIP 0x%016llX",
                      ( unsigned long long )( uintptr_t )Rip );
            break;
        case EXCEPTION_INT_OVERFLOW:
            snprintf( Msg, sizeof( Msg ),
                      "integer overflow at RIP 0x%016llX",
                      ( unsigned long long )( uintptr_t )Rip );
            break;
        case EXCEPTION_ILLEGAL_INSTRUCTION:
            snprintf( Msg, sizeof( Msg ),
                      "illegal instruction at RIP 0x%016llX",
                      ( unsigned long long )( uintptr_t )Rip );
            break;
        case EXCEPTION_STACK_OVERFLOW:
            snprintf( Msg, sizeof( Msg ), "stack overflow at RIP 0x%016llX",
                      ( unsigned long long )( uintptr_t )Rip );
            break;
        default:
            snprintf( Msg, sizeof( Msg ), "fault 0x%08X at RIP 0x%016llX",
                      ( unsigned )Code,
                      ( unsigned long long )( uintptr_t )Rip );
            break;
    }

    /* If RIP is inside a known JIT region, append source/line attribution. */
    if ( Jit_LookupSourceLine != NULL ) {
        const char *Src  = NULL;
        int         Line = 0;
        if ( Jit_LookupSourceLine( Rip, &Src, &Line ) && Src != NULL ) {
            /* Strip Lua's '@' chunkname prefix for file-loaded chunks. */
            if ( Src[ 0 ] == '@' ) Src++;
            /* Strip leading directory components for brevity. */
            const char *Bare = Src;
            const char *Q    = Src;
            while ( *Q != '\0' ) {
                if ( *Q == '/' || *Q == '\\' ) Bare = Q + 1;
                Q++;
            }
            char Suffix[ 96 ];
            snprintf( Suffix, sizeof( Suffix ), " at %s:%d", Bare, Line );
            /* Append suffix to Msg if there's room. */
            size_t Have = strlen( Msg );
            size_t Free = sizeof( Msg ) - Have - 1;
            if ( Free > 0 ) {
                strncat( Msg, Suffix, Free );
            }
        }
    }

    /* Store the message in this thread's JIT frame. */
    PJIT_FRAME_T Frame = Veh_GetJitFrame( );
    strncpy( Frame->FaultMessage, Msg,
             sizeof( Frame->FaultMessage ) - 1 );
    Frame->FaultMessage[ sizeof( Frame->FaultMessage ) - 1 ] = '\0';

    /* Redirect execution to the recovery trampoline so that longjmp runs
     * outside of Windows exception dispatch. Calling longjmp directly from
     * inside a VEH callback triggers RtlUnwind which raises a secondary
     * exception before we can return.
     *
     * Only RIP is modified; longjmp in the trampoline restores RSP and all
     * other registers from the saved jmp_buf, so the fault-time RSP is fine.
     *
     * R11 carries the per-thread g_CurrentJitFrame to the trampoline: we read
     * the thread-local here (in the faulting thread's context) where C can,
     * rather than from the naked stub which has no thread-local addressing. R11
     * is volatile in the Win64 ABI, so commandeering it across the redirect is
     * safe.
     */
    Pointers->ContextRecord->R11 = ( DWORD64 )( uintptr_t )Frame;
    Pointers->ContextRecord->Rip = ( DWORD64 )( uintptr_t )Veh_RecoveryTrampoline;
    return EXCEPTION_CONTINUE_EXECUTION;
}

int Veh_Init( void ) {
    if ( g_VehHandle != NULL ) return 1;  /* idempotent */
    g_VehHandle = AddVectoredExceptionHandler( 1, Runtime_VehHandler );
    return g_VehHandle != NULL;
}

void Veh_Shutdown( void ) {
    if ( g_VehHandle != NULL ) {
        RemoveVectoredExceptionHandler( g_VehHandle );
        g_VehHandle = NULL;
    }
    g_NumRegions = 0;
    memset( g_Regions, 0, sizeof( g_Regions ) );
    Veh_SetJitFrame( NULL );
}
