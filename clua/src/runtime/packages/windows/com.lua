-- windows.com -- ole32 + oleaut32: CoInitialize, CoCreateInstance, GUID/SAFEARRAY/BSTR helpers.
local W = require "windows"

ffi.cdef[[
/* GUID -- named GUID_W to avoid name collisions with other packages
   that may have already declared it. On-the-wire layout matches the
   canonical Windows GUID. */
typedef struct _GUID_W {
    DWORD Data1; WORD Data2; WORD Data3; BYTE Data4[8];
} GUID_W;

/* COM apartment / initialization */
HRESULT  CoInitialize(LPVOID);
HRESULT  CoInitializeEx(LPVOID, DWORD);
void     CoUninitialize(void);
HRESULT  CoCreateInstance(GUID_W *, void *, DWORD, GUID_W *, void **);
HRESULT  CoGetClassObject(GUID_W *, DWORD, void *, GUID_W *, void **);
void    *CoTaskMemAlloc(ULONGLONG);
void     CoTaskMemFree(void *);

/* BSTR helpers (live in oleaut32) */
LPWSTR   SysAllocString(LPCWSTR);
LPWSTR   SysAllocStringByteLen(LPCSTR, DWORD);
void     SysFreeString(LPWSTR);
DWORD    SysStringLen(LPWSTR);
DWORD    SysStringByteLen(LPWSTR);

/* GUID string conversion (ole32) */
HRESULT  CLSIDFromString(LPCWSTR, GUID_W *);
HRESULT  IIDFromString(LPCWSTR, GUID_W *);
HRESULT  StringFromCLSID(GUID_W *, LPWSTR *);
HRESULT  StringFromIID(GUID_W *, LPWSTR *);

/* SAFEARRAY (oleaut32) */
typedef struct _SAFEARRAYBOUND {
    ULONG cElements;
    long  lLbound;
} SAFEARRAYBOUND;

typedef struct _SAFEARRAY {
    unsigned short cDims;
    unsigned short fFeatures;
    ULONG          cbElements;
    ULONG          cLocks;
    PVOID          pvData;
    SAFEARRAYBOUND rgsabound[1];
} SAFEARRAY;

SAFEARRAY *SafeArrayCreate(unsigned short vt, ULONG cDims, SAFEARRAYBOUND *rgsabound);
HRESULT    SafeArrayDestroy(SAFEARRAY *psa);
HRESULT    SafeArrayPutElement(SAFEARRAY *psa, long *rgIndices, void *pv);
HRESULT    SafeArrayAccessData(SAFEARRAY *psa, void **ppvData);
HRESULT    SafeArrayUnaccessData(SAFEARRAY *psa);
ULONG      SafeArrayGetDim(SAFEARRAY *psa);
HRESULT    SafeArrayGetLBound(SAFEARRAY *psa, ULONG nDim, long *plLbound);
HRESULT    SafeArrayGetUBound(SAFEARRAY *psa, ULONG nDim, long *plUbound);
]]
pcall(ffi.load, "ole32")
pcall(ffi.load, "oleaut32")

return {
    -- CoInitializeEx flags
    COINIT_APARTMENTTHREADED = 0x2,
    COINIT_MULTITHREADED     = 0x0,
    COINIT_DISABLE_OLE1DDE   = 0x4,
    COINIT_SPEED_OVER_MEMORY = 0x8,
    -- CLSCTX
    CLSCTX_INPROC_SERVER  = 0x1,
    CLSCTX_INPROC_HANDLER = 0x2,
    CLSCTX_LOCAL_SERVER   = 0x4,
    CLSCTX_REMOTE_SERVER  = 0x10,
    CLSCTX_ALL            = 0x17,
    -- VARENUM (for SafeArrayCreate vt)
    VT_EMPTY = 0,
    VT_UI1   = 17,
    VT_BSTR  = 8,
    VT_I4    = 3,
    VT_I8    = 20,
}
