#include "jit/exec_mem.h"
#include "ffi/veh.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <windows.h>

static size_t PageSize( void ) {
    static size_t Cached = { 0 };
    SYSTEM_INFO Si = { 0 };
    if ( Cached == 0 ) {
        GetSystemInfo( &Si );
        Cached = ( size_t )Si.dwPageSize;
    }
    return Cached;
}

static size_t RoundUpToPage( size_t N ) {
    size_t Ps = PageSize( );
    return ( N + Ps - 1 ) & ~( Ps - 1 );
}

int ExecMem_Reserve( size_t ReserveBytes, PEXEC_MEM_SLOT_T Slot ) {
    size_t Rounded = { 0 };
    LPVOID Page    = { 0 };

    if ( ReserveBytes == 0 || Slot == NULL ) { return 0; }
    memset( Slot, 0, sizeof( *Slot ) );

    Rounded = RoundUpToPage( ReserveBytes );
    Page = VirtualAlloc( NULL, Rounded, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE );
    if ( Page == NULL ) { return 0; }

    Slot->Code      = ( unsigned char * )Page;
    Slot->Size      = Rounded;
    Slot->Used      = 0;
    Slot->Committed = 0;

    /* register this slab so VEH catches faults inside its JIT-emitted code */
    Veh_RegisterRegion( Slot->Code, Slot->Size );
    return 1;
}

int ExecMem_Append( PEXEC_MEM_SLOT_T Slot, const void *Bytes, size_t Len ) {
    if ( Slot == NULL || Slot->Code == NULL ) { return 0; }
    if ( Slot->Committed )                    { return 0; }
    if ( Slot->Used + Len > Slot->Size )      { return 0; }
    memcpy( Slot->Code + Slot->Used, Bytes, Len );
    Slot->Used += Len;
    return 1;
}

int ExecMem_Commit( PEXEC_MEM_SLOT_T Slot ) {
    DWORD Old = { 0 };
    if ( Slot == NULL || Slot->Code == NULL || Slot->Committed ) { return 0; }
    if ( !VirtualProtect( Slot->Code, Slot->Size, PAGE_EXECUTE_READ, &Old ) ) {
        return 0;
    }
    /* instruction cache is coherent on x64 with data writes, but
       FlushInstructionCache documents this guarantee */
    FlushInstructionCache( GetCurrentProcess( ), Slot->Code, Slot->Used );
    Slot->Committed = 1;
    return 1;
}

void ExecMem_Release( PEXEC_MEM_SLOT_T Slot ) {
    if ( Slot == NULL || Slot->Code == NULL ) { return; }
    Veh_UnregisterRegion( Slot->Code );
    VirtualFree( Slot->Code, 0, MEM_RELEASE );
    Slot->Code      = NULL;
    Slot->Size      = 0;
    Slot->Used      = 0;
    Slot->Committed = 0;
}
