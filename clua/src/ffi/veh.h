/*!
 * @brief
 *  Vectored Exception Handler installation + region table + longjmp
 *  recovery for faults inside JIT / FFI / runtime-helper code regions.
 */

#ifndef CLUA_FFI_VEH_H
#define CLUA_FFI_VEH_H

#include "lua.h"

#include <setjmp.h>
#include <stddef.h>
#include <stdint.h>

/*!
 * @brief
 *  A JIT entry frame. Linked list head is g_CurrentJitFrame. Each
 *  Jit_TrampolineEntry pushes a new frame; VEH walks the list to find
 *  the innermost frame and longjmps to its RecoveryJmp.
 */
typedef struct _JIT_FRAME_T {
    jmp_buf                  RecoveryJmp;
    struct _JIT_FRAME_T     *Prev;
    void                    *PrevLuaTop;       /* L->top.p at frame entry */
    char                     FaultMessage[ 192 ];
} JIT_FRAME_T, *PJIT_FRAME_T;

/* Currently-innermost JIT frame. Modified only by Jit_TrampolineEntry
   (push/pop) and read by Veh_TriggerRecovery. V1 single-threaded — plain
   global. Future multi-thread: __declspec(thread). */
extern PJIT_FRAME_T g_CurrentJitFrame;

/*!
 * @brief
 *  Install the Vectored Exception Handler. Idempotent. Returns 1 on
 *  success, 0 if AddVectoredExceptionHandler failed.
 */
int Veh_Init( void );

/*!
 * @brief
 *  Remove the VEH and clear the region table.
 */
void Veh_Shutdown( void );

/*!
 * @brief
 *  Register a code region [Start, End) that the VEH should catch faults
 *  from. Inserted into the sorted region table. Returns 1 on success,
 *  0 if the table is full or args are invalid.
 */
int Veh_RegisterRegion( void *Start, size_t Size );

/*!
 * @brief
 *  Remove a previously-registered region by Start address (must match
 *  exactly). Returns 1 on success, 0 if not found.
 */
int Veh_UnregisterRegion( void *Start );

/*!
 * @brief
 *  Returns 1 if Addr lies within any registered region, 0 otherwise.
 *  Binary search over the sorted table.
 */
int Veh_IsCodeRegion( void *Addr );

/*!
 * @brief
 *  Called by the VEH handler when a recoverable fault is detected.
 *  Walks g_CurrentJitFrame to the innermost frame, copies FaultMessage
 *  into the frame, longjmps with value 1. Does not return.
 */
void Veh_TriggerRecovery( const char *Message );

#endif /* CLUA_FFI_VEH_H */
