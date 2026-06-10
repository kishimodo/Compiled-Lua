/*!
 * @brief
 *  Page-backed pool for JIT-emitted machine code.
 *  Pages are allocated with PAGE_READWRITE, written to, then committed
 *  to PAGE_EXECUTE_READ. Never RWX. One slot per emitted function.
 */

#ifndef LUAVM_JIT_EXEC_MEM_H
#define LUAVM_JIT_EXEC_MEM_H

#include <stddef.h>

typedef struct _EXEC_MEM_SLOT {
    unsigned char *Code;    /* writable while building; RX after commit */
    size_t         Size;    /* bytes reserved for this slot */
    size_t         Used;    /* bytes actually written */
    int            Committed; /* 1 = flipped to RX */
} EXEC_MEM_SLOT_T, *PEXEC_MEM_SLOT_T;

/*!
 * @brief
 *  Reserve a contiguous range of writable memory for a new function.
 *  ReserveBytes is an upper bound; the slot can use less.
 *
 * @return
 *  1 on success, 0 on alloc failure
 */
int ExecMem_Reserve( size_t ReserveBytes, PEXEC_MEM_SLOT_T Slot );

/*!
 * @brief
 *  Append bytes to the slot's writable region.
 *
 * @return
 *  1 on success, 0 if it would overflow the reservation
 */
int ExecMem_Append( PEXEC_MEM_SLOT_T Slot, const void *Bytes, size_t Len );

/*!
 * @brief
 *  Flip the slot to PAGE_EXECUTE_READ. After this call, Slot->Code is
 *  callable; further appends are rejected.
 *
 * @return
 *  1 on success, 0 on protection failure
 */
int ExecMem_Commit( PEXEC_MEM_SLOT_T Slot );

/*!
 * @brief
 *  Free the slot's backing page(s). Code pointer becomes invalid.
 */
void ExecMem_Release( PEXEC_MEM_SLOT_T Slot );

#endif /* LUAVM_JIT_EXEC_MEM_H */
