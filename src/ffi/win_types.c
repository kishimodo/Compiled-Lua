/*!
 * @brief
 *  Register the standard Windows API typedef set into the ctype table.
 *  Mirrors a minimal subset of windef.h / winnt.h / winternl.h.
 */

#include "ffi/win_types.h"
#include "ffi/ctype.h"
#include "ffi/cdecl_parser.h"

static const char *g_TypedefSource =
    "typedef unsigned char  BYTE;"
    "typedef unsigned char  BOOLEAN;"
    "typedef unsigned short WORD;"
    "typedef unsigned int   DWORD;"
    "typedef unsigned long long QWORD;"
    "typedef unsigned int   UINT;"
    "typedef unsigned long  ULONG;"
    "typedef unsigned long long ULONGLONG;"
    "typedef unsigned long  DWORD32;"
    "typedef unsigned long long DWORD64;"
    "typedef unsigned short USHORT;"
    "typedef unsigned char  UCHAR;"
    "typedef int            BOOL;"
    "typedef long           LONG;"
    "typedef long long      LONGLONG;"
    "typedef int            INT;"
    "typedef long           NTSTATUS;"
    "typedef unsigned short WCHAR;"
    "typedef char          *LPSTR;"
    "typedef const char    *LPCSTR;"
    "typedef unsigned short *LPWSTR;"
    "typedef const unsigned short *LPCWSTR;"
    "typedef void          *PVOID;"
    "typedef void          *LPVOID;"
    "typedef void          *HANDLE;"
    "typedef void          *HMODULE;"
    "typedef void          *HINSTANCE;"
    "typedef void          *HWND;"
    "typedef void          *HKEY;"
    "typedef void          *HDC;"
    "typedef void          *HMENU;"
    "typedef unsigned int  *LPDWORD;"
    "typedef unsigned int  *PDWORD;"
    "typedef unsigned long *PULONG;"
    "typedef int           *PINT;"
    "typedef long          *PLONG;"
    "typedef union LARGE_INTEGER { long long QuadPart; struct { unsigned int LowPart; int HighPart; }; } LARGE_INTEGER;";

void Ffi_RegisterWindowsTypes( void )
{
    Cdecl_Parse( g_TypedefSource );
}
