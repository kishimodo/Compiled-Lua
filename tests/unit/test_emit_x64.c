/* test_emit_x64.c -- x64 instruction encoder: correct byte sequences
 * for representative instructions, plus execute round-trips.
 */
#include "test_harness.h"
#include "jit/exec_mem.h"
#include "jit/emit_x64.h"

#include <string.h>

static int         g_CallCount = 0;
static void Helper_Bump( void ) { g_CallCount++; }

typedef int     ( *FN_INT_T   )( void );
typedef int64_t ( *FN_I64_T   )( int64_t );
typedef void    ( *FN_VOID_T  )( void );

int main( void ) {
    TEST_BEGIN("emit_x64");

    /* ---------------------------------------------------------------
     * 1. MOV RAX, imm64 = 0x11223344  ->  48 B8 44 33 22 11 00 00 00 00
     * -------------------------------------------------------------- */
    EXEC_MEM_SLOT_T S = { 0 };
    CHECK( ExecMem_Reserve( 128, &S ) );
    CHECK( EmitX64_MovImm64ToReg( &S, X64_RAX, 0x11223344 ) );
    {
        static const unsigned char Exp[] = {
            0x48, 0xB8,
            0x44, 0x33, 0x22, 0x11, 0x00, 0x00, 0x00, 0x00
        };
        CHECK_EQ_INT( S.Used, sizeof( Exp ) );
        CHECK_MSG( memcmp( S.Code, Exp, sizeof( Exp ) ) == 0,
                   "MOV RAX,imm64 bytes match" );
    }
    S.Used = 0;

    /* ---------------------------------------------------------------
     * 2. MOV R8, imm64 = 1  ->  49 B8 01 00 00 00 00 00 00 00 (REX.B)
     * -------------------------------------------------------------- */
    CHECK( EmitX64_MovImm64ToReg( &S, X64_R8, 1 ) );
    {
        static const unsigned char Exp[] = {
            0x49, 0xB8,
            0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        };
        CHECK_EQ_INT( S.Used, sizeof( Exp ) );
        CHECK_MSG( memcmp( S.Code, Exp, sizeof( Exp ) ) == 0,
                   "MOV R8,imm64 bytes match (REX.B)" );
    }
    S.Used = 0;

    /* ---------------------------------------------------------------
     * 3. RET  ->  C3  (1 byte)
     * -------------------------------------------------------------- */
    CHECK( EmitX64_Ret( &S ) );
    CHECK_EQ_INT( S.Used, 1 );
    CHECK_EQ_INT( (unsigned char)S.Code[0], 0xC3 );
    S.Used = 0;

    ExecMem_Release( &S );

    /* ---------------------------------------------------------------
     * 4. Execute: MOV RAX, 0x1234; RET  -> returns 0x1234
     * -------------------------------------------------------------- */
    {
        EXEC_MEM_SLOT_T Slot = { 0 };
        CHECK( ExecMem_Reserve( 32, &Slot ) );
        CHECK( EmitX64_MovImm64ToReg( &Slot, X64_RAX, 0x1234 ) );
        CHECK( EmitX64_Ret( &Slot ) );
        CHECK( ExecMem_Commit( &Slot ) );
        int R = ( (FN_INT_T)(void *)Slot.Code )();
        CHECK_EQ_INT( R, 0x1234 );
        ExecMem_Release( &Slot );
    }

    /* ---------------------------------------------------------------
     * 5. Execute: MOV RAX, RCX; RET  (Windows ABI: arg1 in RCX)
     * -------------------------------------------------------------- */
    {
        EXEC_MEM_SLOT_T Slot = { 0 };
        CHECK( ExecMem_Reserve( 32, &Slot ) );
        CHECK( EmitX64_MovRegToReg( &Slot, X64_RAX, X64_RCX ) );
        CHECK( EmitX64_Ret( &Slot ) );
        CHECK( ExecMem_Commit( &Slot ) );
        int64_t R = ( (FN_I64_T)(void *)Slot.Code )( 0xDEADBEEFll );
        CHECK_EQ_INT( R, 0xDEADBEEFll );
        ExecMem_Release( &Slot );
    }

    /* ---------------------------------------------------------------
     * 6. Mem-to-reg / reg-to-mem round-trip
     *    f(int64_t *p): rax = p[1]; p[2] = rax; return p[2]
     * -------------------------------------------------------------- */
    {
        typedef int64_t ( *FN_PI64_T )( int64_t * );
        int64_t Arr[3] = { 0x1111, 0x2222, 0 };
        EXEC_MEM_SLOT_T Slot = { 0 };
        CHECK( ExecMem_Reserve( 64, &Slot ) );
        CHECK( EmitX64_MovMemToReg( &Slot, X64_RAX, X64_RCX, 8 ) );
        CHECK( EmitX64_MovRegToMem( &Slot, X64_RCX, 16, X64_RAX ) );
        CHECK( EmitX64_MovMemToReg( &Slot, X64_RAX, X64_RCX, 16 ) );
        CHECK( EmitX64_Ret( &Slot ) );
        CHECK( ExecMem_Commit( &Slot ) );
        int64_t R = ( (FN_PI64_T)(void *)Slot.Code )( Arr );
        CHECK_EQ_INT( R, 0x2222 );
        CHECK_EQ_INT( Arr[2], 0x2222 );
        ExecMem_Release( &Slot );
    }

    /* ---------------------------------------------------------------
     * 7. JNE rel8: emit cmp+jne so branch not taken when values equal
     * -------------------------------------------------------------- */
    {
        typedef int ( *FN_IP_T )( int * );
        int Target = 0;
        EXEC_MEM_SLOT_T Slot = { 0 };
        CHECK( ExecMem_Reserve( 64, &Slot ) );
        /* MOV [RCX], 0x5A5A; CMP [RCX], 0x5A5A; JNE +6; MOV EAX,0;RET; MOV EAX,1;RET */
        CHECK( EmitX64_MovImm32ToMem( &Slot, X64_RCX, 0, 0x5A5A ) );
        CHECK( EmitX64_CmpMem32Imm32( &Slot, X64_RCX, 0, 0x5A5A ) );
        CHECK( EmitX64_JneRel8( &Slot, 6 ) );
        /* 6-byte "return 0" block */
        unsigned char R0[] = { 0xB8, 0x00, 0x00, 0x00, 0x00, 0xC3 };
        ExecMem_Append( &Slot, R0, sizeof( R0 ) );
        /* fallthrough "return 1" */
        unsigned char R1[] = { 0xB8, 0x01, 0x00, 0x00, 0x00, 0xC3 };
        ExecMem_Append( &Slot, R1, sizeof( R1 ) );
        CHECK( ExecMem_Commit( &Slot ) );
        int R = ( (FN_IP_T)(void *)Slot.Code )( &Target );
        CHECK_EQ_INT( Target, 0x5A5A );
        CHECK_EQ_INT( R, 0 );  /* JNE not taken */
        ExecMem_Release( &Slot );
    }

    /* ---------------------------------------------------------------
     * 8. JMP rel8 placeholder + patch — skips 99 block, returns 7
     * -------------------------------------------------------------- */
    {
        EXEC_MEM_SLOT_T Slot = { 0 };
        CHECK( ExecMem_Reserve( 64, &Slot ) );
        size_t JmpOff = EmitX64_JmpRel8_Placeholder( &Slot );
        CHECK_NEQ_INT( (long long)JmpOff, (long long)(size_t)-1 );
        unsigned char Skip[] = { 0xB8, 0x63, 0x00, 0x00, 0x00, 0xC3 };
        ExecMem_Append( &Slot, Skip, sizeof( Skip ) );
        size_t TgtOff = Slot.Used;
        unsigned char Tgt[]  = { 0xB8, 0x07, 0x00, 0x00, 0x00, 0xC3 };
        ExecMem_Append( &Slot, Tgt, sizeof( Tgt ) );
        CHECK( EmitX64_PatchRel8( &Slot, JmpOff, TgtOff ) );
        CHECK( ExecMem_Commit( &Slot ) );
        int R = ( (FN_INT_T)(void *)Slot.Code )();
        CHECK_EQ_INT( R, 7 );
        ExecMem_Release( &Slot );
    }

    /* ---------------------------------------------------------------
     * 9. JMP rel32 placeholder + patch
     * -------------------------------------------------------------- */
    {
        EXEC_MEM_SLOT_T Slot = { 0 };
        CHECK( ExecMem_Reserve( 128, &Slot ) );
        size_t Jmp32Off = EmitX64_JmpRel32_Placeholder( &Slot );
        CHECK_NEQ_INT( (long long)Jmp32Off, (long long)(size_t)-1 );
        unsigned char Skip[] = { 0xB8, 0x63, 0x00, 0x00, 0x00, 0xC3 };
        ExecMem_Append( &Slot, Skip, sizeof( Skip ) );
        size_t TgtOff = Slot.Used;
        unsigned char Tgt[]  = { 0xB8, 0x07, 0x00, 0x00, 0x00, 0xC3 };
        ExecMem_Append( &Slot, Tgt, sizeof( Tgt ) );
        CHECK( EmitX64_PatchRel32( &Slot, Jmp32Off, TgtOff ) );
        CHECK( ExecMem_Commit( &Slot ) );
        int R = ( (FN_INT_T)(void *)Slot.Code )();
        CHECK_EQ_INT( R, 7 );
        ExecMem_Release( &Slot );
    }

    /* ---------------------------------------------------------------
     * 10. CALL abs: invoke a C helper via emitted code
     *     push rdi; sub rsp,32; mov rax,&Helper_Bump; call rax;
     *     add rsp,32; pop rdi; ret
     * -------------------------------------------------------------- */
    {
        EXEC_MEM_SLOT_T Slot = { 0 };
        CHECK( ExecMem_Reserve( 128, &Slot ) );
        CHECK( EmitX64_PushReg( &Slot, X64_RDI ) );
        CHECK( EmitX64_SubRspImm( &Slot, 32 ) );
        CHECK( EmitX64_CallAbs( &Slot, (void *)Helper_Bump ) );
        CHECK( EmitX64_AddRspImm( &Slot, 32 ) );
        CHECK( EmitX64_PopReg( &Slot, X64_RDI ) );
        CHECK( EmitX64_Ret( &Slot ) );
        CHECK( ExecMem_Commit( &Slot ) );
        g_CallCount = 0;
        ( (FN_VOID_T)(void *)Slot.Code )();
        CHECK_EQ_INT( g_CallCount, 1 );
        ExecMem_Release( &Slot );
    }

    /* ---------------------------------------------------------------
     * 11. SSE2 ADDSD round-trip: f(double *out) where out[0]=3.5, out[1]=2.25
     *     movsd xmm0,[rcx]; addsd xmm0,[rcx+8]; movsd [rcx+16],xmm0; ret
     * -------------------------------------------------------------- */
    {
        typedef void ( *FN_PDBL_T )( double * );
        double DArr[3] = { 3.5, 2.25, 0.0 };
        EXEC_MEM_SLOT_T Slot = { 0 };
        CHECK( ExecMem_Reserve( 64, &Slot ) );
        CHECK( EmitX64_MovsdMemToXmm0( &Slot, X64_RCX, 0 ) );
        CHECK( EmitX64_AddsdMemToXmm0( &Slot, X64_RCX, 8 ) );
        CHECK( EmitX64_MovsdXmm0ToMem( &Slot, X64_RCX, 16 ) );
        CHECK( EmitX64_Ret( &Slot ) );
        CHECK( ExecMem_Commit( &Slot ) );
        ( (FN_PDBL_T)(void *)Slot.Code )( DArr );
        CHECK_MSG( DArr[2] == 5.75, "ADDSD: 3.5 + 2.25 = 5.75" );
        ExecMem_Release( &Slot );
    }

    TEST_END();
}
