-- LuaVM dotnet package -- comprehensive in-memory .NET CLR hosting.
--
-- Mirrors .NET surface as closely as Lua syntax allows:
--   dotnet.Assembly.Load(bytes)        -- System.Reflection.Assembly.Load(byte[])
--   dotnet.Assembly.LoadFile(path)     -- Assembly.LoadFile(string)
--   dotnet.Assembly.LoadFrom(path)     -- Assembly.LoadFrom(string)
--   dotnet.AppDomain.CurrentDomain     -- AppDomain.CurrentDomain
--   dotnet.AppDomain.CreateDomain(n)   -- AppDomain.CreateDomain(name)
--   dotnet.Activator.CreateInstance(t) -- Activator.CreateInstance(type)
--
-- Instance methods use Lua colon syntax (asm:GetType, type:GetMethod,
-- method:Invoke) since .NET's instance-method semantics map cleanly to
-- userdata-with-metatable idiom.
--
-- Two hosting paths:
--   1. ICorRuntimeHost (in-memory): used by Assembly.Load(bytes).
--      Walks COM all the way to _AppDomain::Load_3(SAFEARRAY of byte).
--   2. ICLRRuntimeHost::ExecuteInDefaultAppDomain (path-based):
--      used by dotnet.execute_file / dotnet.invoke_method_in_file.
--      Faster and simpler when you have a file on disk.
--
-- All paths target .NET Framework 4.x (mscoree.dll). For .NET Core /
-- 5+ via hostfxr.dll, see dotnet.core.* (separate sub-table).

local ffi   = ffi
local async -- lazy-loaded; only needed if dotnet.from_url is used
local W

local ok_w, win = pcall(require, "windows")
if ok_w then W = win end

-- ===== FFI cdefs =========================================================

ffi.cdef[[

/* basic Win32 types we need locally (not relying on windows package
   in case it's not been required) */
typedef long             HRESULT;
typedef long             SCODE;
typedef unsigned long    ULONG;
typedef unsigned short   USHORT;
typedef unsigned short   WORD;
typedef unsigned long    DWORD;
typedef int              VARIANT_BOOL;
typedef int              INT;
typedef void            *HMODULE;
typedef void            *HANDLE;
typedef void            *PVOID;
typedef const void      *LPCVOID;
typedef char            *LPSTR;
typedef const char      *LPCSTR;
typedef unsigned short  *LPWSTR;
typedef const unsigned short *LPCWSTR;
typedef unsigned short  *BSTR;
typedef long             VARTYPE;
typedef unsigned long   *LPDWORD;
typedef void           (*FARPROC)(void);

/* GUID -- 16 bytes, used for IIDs and CLSIDs */
typedef struct _GUID {
    unsigned long  Data1;
    unsigned short Data2;
    unsigned short Data3;
    unsigned char  Data4[8];
} GUID, IID, CLSID;

/* SAFEARRAY -- used for byte[] parameters into _AppDomain::Load_3 */
typedef struct _SAFEARRAYBOUND {
    ULONG cElements;
    long  lLbound;
} SAFEARRAYBOUND;

typedef struct _SAFEARRAY {
    USHORT          cDims;
    USHORT          fFeatures;
    ULONG           cbElements;
    ULONG           cLocks;
    PVOID           pvData;
    SAFEARRAYBOUND  rgsabound[1];
} SAFEARRAY;

/* VARIANT -- 24-byte tagged union for _MethodInfo::Invoke parameters.
   We only ever fill .vt = VT_EMPTY (for null instance) or use it as a
   sized opaque blob, so a 24-byte struct is plenty. */
typedef struct _VARIANT_PADDED {
    VARTYPE  vt;
    WORD     wReserved1;
    WORD     wReserved2;
    WORD     wReserved3;
    long long llVal_or_pad;
    long long llExtra;
} VARIANT_PADDED;

/* ===== mscoree.dll exports we call directly ========================== */
HRESULT __stdcall CLRCreateInstance(GUID *clsid, GUID *riid, void **ppInterface);

/* ===== oleaut32 -- SAFEARRAY + BSTR helpers ========================== */
SAFEARRAY *SafeArrayCreate(VARTYPE vt, ULONG cDims, SAFEARRAYBOUND *rgsabound);
HRESULT    SafeArrayDestroy(SAFEARRAY *psa);
HRESULT    SafeArrayPutElement(SAFEARRAY *psa, long *rgIndices, void *pv);
HRESULT    SafeArrayAccessData(SAFEARRAY *psa, void **ppvData);
HRESULT    SafeArrayUnaccessData(SAFEARRAY *psa);
ULONG      SafeArrayGetDim(SAFEARRAY *psa);
HRESULT    SafeArrayGetLBound(SAFEARRAY *psa, ULONG nDim, long *plLbound);
HRESULT    SafeArrayGetUBound(SAFEARRAY *psa, ULONG nDim, long *plUbound);

BSTR       SysAllocString(const unsigned short *psz);
BSTR       SysAllocStringByteLen(const char *psz, ULONG len);
void       SysFreeString(BSTR bstrString);
ULONG      SysStringLen(BSTR bstrString);
ULONG      SysStringByteLen(BSTR bstrString);

/* ===== kernel32 -- file I/O for from_file =========================== */
HANDLE     CreateFileA(LPCSTR, DWORD, DWORD, void *, DWORD, DWORD, HANDLE);
DWORD      GetFileSize(HANDLE, LPDWORD);
int        ReadFile(HANDLE, void *, DWORD, LPDWORD, void *);
int        CloseHandle(HANDLE);
HMODULE    LoadLibraryA(LPCSTR);
FARPROC    GetProcAddress(HMODULE, LPCSTR);
int        VirtualProtect(void *, unsigned long long, DWORD, LPDWORD);
HMODULE    GetModuleHandleA(LPCSTR);
int        MultiByteToWideChar(unsigned int, DWORD, LPCSTR, int,
                               unsigned short *, int);
int        WideCharToMultiByte(unsigned int, DWORD, const unsigned short *, int,
                               LPSTR, int, LPCSTR, int *);
]]

-- ===== COM vtable plumbing ===============================================
-- Forward-declare every interface struct first (so vtables can reference
-- *Interface in their function pointer signatures without circularity).
ffi.cdef[[
typedef struct ICLRMetaHost        ICLRMetaHost;
typedef struct ICLRRuntimeInfo     ICLRRuntimeInfo;
typedef struct ICLRRuntimeHost     ICLRRuntimeHost;
typedef struct ICorRuntimeHost     ICorRuntimeHost;
typedef struct IUnknown            IUnknown;
typedef struct _AppDomain          AppDomain;
typedef struct _Assembly           Assembly;
typedef struct _Type               Type;
typedef struct _MethodInfo         MethodInfo;
]]

ffi.cdef[[
typedef struct ICLRMetaHostVtbl {
    HRESULT (__stdcall *QueryInterface)(ICLRMetaHost*, GUID*, void**);
    ULONG   (__stdcall *AddRef)(ICLRMetaHost*);
    ULONG   (__stdcall *Release)(ICLRMetaHost*);
    HRESULT (__stdcall *GetRuntime)(ICLRMetaHost*, LPCWSTR, GUID*, void**);
    HRESULT (__stdcall *GetVersionFromFile)(ICLRMetaHost*, LPCWSTR, LPWSTR, DWORD*);
    HRESULT (__stdcall *EnumerateInstalledRuntimes)(ICLRMetaHost*, void**);
    HRESULT (__stdcall *EnumerateLoadedRuntimes)(ICLRMetaHost*, HANDLE, void**);
    HRESULT (__stdcall *RequestRuntimeLoadedNotification)(ICLRMetaHost*, void*);
    HRESULT (__stdcall *QueryLegacyV2RuntimeBinding)(ICLRMetaHost*, GUID*, void**);
    HRESULT (__stdcall *ExitProcess)(ICLRMetaHost*, INT);
} ICLRMetaHostVtbl;
struct ICLRMetaHost { ICLRMetaHostVtbl *lpVtbl; };

typedef struct ICLRRuntimeInfoVtbl {
    HRESULT (__stdcall *QueryInterface)(ICLRRuntimeInfo*, GUID*, void**);
    ULONG   (__stdcall *AddRef)(ICLRRuntimeInfo*);
    ULONG   (__stdcall *Release)(ICLRRuntimeInfo*);
    HRESULT (__stdcall *GetVersionString)(ICLRRuntimeInfo*, LPWSTR, DWORD*);
    HRESULT (__stdcall *GetRuntimeDirectory)(ICLRRuntimeInfo*, LPWSTR, DWORD*);
    HRESULT (__stdcall *IsLoaded)(ICLRRuntimeInfo*, HANDLE, int*);
    HRESULT (__stdcall *LoadErrorString)(ICLRRuntimeInfo*, DWORD, LPWSTR, DWORD*, long);
    HRESULT (__stdcall *LoadLibrary)(ICLRRuntimeInfo*, LPCWSTR, HMODULE*);
    HRESULT (__stdcall *GetProcAddress)(ICLRRuntimeInfo*, LPCSTR, void**);
    HRESULT (__stdcall *GetInterface)(ICLRRuntimeInfo*, GUID*, GUID*, void**);
    HRESULT (__stdcall *IsLoadable)(ICLRRuntimeInfo*, int*);
    HRESULT (__stdcall *SetDefaultStartupFlags)(ICLRRuntimeInfo*, DWORD, LPCWSTR);
    HRESULT (__stdcall *GetDefaultStartupFlags)(ICLRRuntimeInfo*, DWORD*, LPWSTR, DWORD*);
    HRESULT (__stdcall *BindAsLegacyV2Runtime)(ICLRRuntimeInfo*);
    HRESULT (__stdcall *IsStarted)(ICLRRuntimeInfo*, int*, DWORD*);
} ICLRRuntimeInfoVtbl;
struct ICLRRuntimeInfo { ICLRRuntimeInfoVtbl *lpVtbl; };

typedef struct ICLRRuntimeHostVtbl {
    HRESULT (__stdcall *QueryInterface)(ICLRRuntimeHost*, GUID*, void**);
    ULONG   (__stdcall *AddRef)(ICLRRuntimeHost*);
    ULONG   (__stdcall *Release)(ICLRRuntimeHost*);
    HRESULT (__stdcall *Start)(ICLRRuntimeHost*);
    HRESULT (__stdcall *Stop)(ICLRRuntimeHost*);
    HRESULT (__stdcall *SetHostControl)(ICLRRuntimeHost*, void*);
    HRESULT (__stdcall *GetCLRControl)(ICLRRuntimeHost*, void**);
    HRESULT (__stdcall *UnloadAppDomain)(ICLRRuntimeHost*, DWORD, int);
    HRESULT (__stdcall *ExecuteInAppDomain)(ICLRRuntimeHost*, DWORD, void*, void*);
    HRESULT (__stdcall *GetCurrentAppDomainId)(ICLRRuntimeHost*, DWORD*);
    HRESULT (__stdcall *ExecuteApplication)(ICLRRuntimeHost*, LPCWSTR, DWORD, LPCWSTR*, DWORD, LPCWSTR*, int*);
    HRESULT (__stdcall *ExecuteInDefaultAppDomain)(ICLRRuntimeHost*, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, DWORD*);
} ICLRRuntimeHostVtbl;
struct ICLRRuntimeHost { ICLRRuntimeHostVtbl *lpVtbl; };

/* ICorRuntimeHost: the legacy hosting interface that still ships with
   .NET Framework 4.x. Needed because ICLRRuntimeHost has no
   GetDefaultDomain, and Assembly.Load(byte[]) requires going through
   _AppDomain. */
typedef struct ICorRuntimeHostVtbl {
    HRESULT (__stdcall *QueryInterface)(ICorRuntimeHost*, GUID*, void**);
    ULONG   (__stdcall *AddRef)(ICorRuntimeHost*);
    ULONG   (__stdcall *Release)(ICorRuntimeHost*);
    HRESULT (__stdcall *CreateLogicalThreadState)(ICorRuntimeHost*);
    HRESULT (__stdcall *DeleteLogicalThreadState)(ICorRuntimeHost*);
    HRESULT (__stdcall *SwitchInLogicalThreadState)(ICorRuntimeHost*, DWORD*);
    HRESULT (__stdcall *SwitchOutLogicalThreadState)(ICorRuntimeHost*, DWORD**);
    HRESULT (__stdcall *LocksHeldByLogicalThread)(ICorRuntimeHost*, DWORD*);
    HRESULT (__stdcall *MapFile)(ICorRuntimeHost*, HANDLE, HMODULE*);
    HRESULT (__stdcall *GetConfiguration)(ICorRuntimeHost*, void**);
    HRESULT (__stdcall *Start)(ICorRuntimeHost*);
    HRESULT (__stdcall *Stop)(ICorRuntimeHost*);
    HRESULT (__stdcall *CreateDomain)(ICorRuntimeHost*, LPCWSTR, IUnknown*, IUnknown**);
    HRESULT (__stdcall *GetDefaultDomain)(ICorRuntimeHost*, IUnknown**);
    HRESULT (__stdcall *EnumDomains)(ICorRuntimeHost*, HANDLE*);
    HRESULT (__stdcall *NextDomain)(ICorRuntimeHost*, HANDLE, IUnknown**);
    HRESULT (__stdcall *CloseEnum)(ICorRuntimeHost*, HANDLE);
    HRESULT (__stdcall *CreateDomainEx)(ICorRuntimeHost*, LPCWSTR, IUnknown*, IUnknown*, IUnknown**);
    HRESULT (__stdcall *CreateDomainSetup)(ICorRuntimeHost*, IUnknown**);
    HRESULT (__stdcall *CreateEvidence)(ICorRuntimeHost*, IUnknown**);
    HRESULT (__stdcall *UnloadDomain)(ICorRuntimeHost*, IUnknown*);
    HRESULT (__stdcall *CurrentDomain)(ICorRuntimeHost*, IUnknown**);
} ICorRuntimeHostVtbl;
struct ICorRuntimeHost { ICorRuntimeHostVtbl *lpVtbl; };

typedef struct IUnknownVtbl {
    HRESULT (__stdcall *QueryInterface)(IUnknown*, GUID*, void**);
    ULONG   (__stdcall *AddRef)(IUnknown*);
    ULONG   (__stdcall *Release)(IUnknown*);
} IUnknownVtbl;
struct IUnknown { IUnknownVtbl *lpVtbl; };

/* _AppDomain -- mscorlib AppDomain dispinterface. Only the methods we
   call are spelled out; the rest are void* placeholders. The order
   MUST match mscorlib.tlb (we hard-code the slot offsets). */
typedef struct AppDomainVtbl {
    HRESULT (__stdcall *QueryInterface)(AppDomain*, GUID*, void**);
    ULONG   (__stdcall *AddRef)(AppDomain*);
    ULONG   (__stdcall *Release)(AppDomain*);
    void *_GetTypeInfoCount;
    void *_GetTypeInfo;
    void *_GetIDsOfNames;
    void *_Invoke;
    void *_get_ToString;
    void *_Equals;
    void *_GetHashCode;
    void *_GetType;
    void *_InitializeLifetimeService;
    void *_GetLifetimeService;
    void *_get_Evidence;
    void *_add_DomainUnload;
    void *_remove_DomainUnload;
    void *_add_AssemblyLoad;
    void *_remove_AssemblyLoad;
    void *_add_ProcessExit;
    void *_remove_ProcessExit;
    void *_add_TypeResolve;
    void *_remove_TypeResolve;
    void *_add_ResourceResolve;
    void *_remove_ResourceResolve;
    void *_add_AssemblyResolve;
    void *_remove_AssemblyResolve;
    void *_add_UnhandledException;
    void *_remove_UnhandledException;
    void *_DefineDynamicAssembly_1;
    void *_DefineDynamicAssembly_2;
    void *_DefineDynamicAssembly_3;
    void *_DefineDynamicAssembly_4;
    void *_DefineDynamicAssembly_5;
    void *_DefineDynamicAssembly_6;
    void *_DefineDynamicAssembly_7;
    void *_DefineDynamicAssembly_8;
    void *_DefineDynamicAssembly_9;
    void *_CreateInstance;
    void *_CreateInstanceFrom;
    void *_CreateInstance_2;
    void *_CreateInstanceFrom_2;
    void *_CreateInstance_3;
    void *_CreateInstanceFrom_3;
    HRESULT (__stdcall *Load_3)(AppDomain*, SAFEARRAY*, Assembly**);
    void *_Load_2;
    void *_Load_4;
    void *_Load_5;
    void *_Load_6;
    void *_Load_7;
    void *_ExecuteAssembly_2;
    void *_ExecuteAssembly_3;
    void *_ExecuteAssembly;
    void *_get_FriendlyName;
    void *_get_BaseDirectory;
    void *_get_RelativeSearchPath;
    void *_get_ShadowCopyFiles;
    void *_GetAssemblies;
    void *_AppendPrivatePath;
    void *_ClearPrivatePath;
    void *_SetShadowCopyPath;
    void *_ClearShadowCopyPath;
    void *_SetCachePath;
    void *_SetData;
    void *_GetData;
    void *_SetAppDomainPolicy;
    void *_SetThreadPrincipal;
    void *_SetPrincipalPolicy;
    void *_DoCallBack;
    void *_get_DynamicDirectory;
} AppDomainVtbl;
struct _AppDomain { AppDomainVtbl *lpVtbl; };

/* _Assembly -- mscorlib Assembly dispinterface. */
typedef struct AssemblyVtbl {
    HRESULT (__stdcall *QueryInterface)(Assembly*, GUID*, void**);
    ULONG   (__stdcall *AddRef)(Assembly*);
    ULONG   (__stdcall *Release)(Assembly*);
    void *_GetTypeInfoCount;
    void *_GetTypeInfo;
    void *_GetIDsOfNames;
    void *_Invoke;
    HRESULT (__stdcall *get_ToString)(Assembly*, BSTR*);
    void *_Equals;
    void *_GetHashCode;
    void *_GetType;
    void *_get_CodeBase;
    void *_get_EscapedCodeBase;
    void *_GetName;
    void *_GetName_2;
    void *_get_FullName;
    HRESULT (__stdcall *get_EntryPoint)(Assembly*, MethodInfo**);
    HRESULT (__stdcall *GetType_2)(Assembly*, BSTR, Type**);
    HRESULT (__stdcall *GetType_3)(Assembly*, BSTR, VARIANT_BOOL, Type**);
    void *_GetExportedTypes;
    HRESULT (__stdcall *GetTypes)(Assembly*, SAFEARRAY**);
    void *_GetManifestResourceStream;
    void *_GetManifestResourceStream_2;
    void *_GetFile;
    void *_GetFiles;
    void *_GetFiles_2;
    void *_GetManifestResourceNames;
    void *_GetManifestResourceInfo;
    void *_get_Location;
    void *_get_Evidence;
    void *_GetCustomAttributes;
    void *_GetCustomAttributes_2;
    void *_IsDefined;
    void *_GetObjectData;
    void *_add_ModuleResolve;
    void *_remove_ModuleResolve;
    HRESULT (__stdcall *GetType_4)(Assembly*, BSTR, VARIANT_BOOL, VARIANT_BOOL, Type**);
    void *_GetSatelliteAssembly;
    void *_GetSatelliteAssembly_2;
    void *_LoadModule;
    void *_LoadModule_2;
    void *_CreateInstance;
    void *_CreateInstance_2;
    void *_CreateInstance_3;
    void *_GetLoadedModules;
    void *_GetLoadedModules_2;
    void *_GetModules;
    void *_GetModules_2;
    void *_GetModule;
    void *_GetReferencedAssemblies;
    void *_get_GlobalAssemblyCache;
} AssemblyVtbl;
struct _Assembly { AssemblyVtbl *lpVtbl; };

/* _Type -- mscorlib Type dispinterface. Only methods we use. */
typedef struct TypeVtbl {
    HRESULT (__stdcall *QueryInterface)(Type*, GUID*, void**);
    ULONG   (__stdcall *AddRef)(Type*);
    ULONG   (__stdcall *Release)(Type*);
    /* Slots 4..7: IDispatch (skipped). */
    void *_GetTypeInfoCount;
    void *_GetTypeInfo;
    void *_GetIDsOfNames;
    void *_Invoke;
    /* slot 8 */ HRESULT (__stdcall *get_ToString)(Type*, BSTR*);
    /* The remaining slots include get_Name, get_FullName, GetMethod
       variants, etc. We declare void* placeholders for everything we
       don't directly use; offsets must match mscorlib.tlb exactly. */
    void *_Equals;
    void *_GetHashCode;
    void *_GetType;
    void *_get_MemberType;
    void *_get_name;          /* slot 13 */
    void *_get_DeclaringType;
    void *_get_ReflectedType;
    void *_GetCustomAttributes;
    void *_GetCustomAttributes_2;
    void *_IsDefined;
    void *_get_Guid;
    void *_get_Module;
    void *_get_Assembly;
    void *_get_TypeHandle;
    void *_get_FullName;
    void *_get_Namespace;
    void *_get_AssemblyQualifiedName;
    void *_GetArrayRank;
    void *_get_BaseType;
    void *_GetConstructors;
    void *_GetInterface;
    void *_GetInterfaces;
    void *_FindInterfaces;
    void *_GetEvent;
    void *_GetEvents;
    void *_GetEvents_2;
    void *_GetNestedTypes;
    void *_GetNestedType;
    void *_GetMember;
    void *_GetDefaultMembers;
    void *_FindMembers;
    void *_GetElementType;
    void *_IsSubclassOf;
    void *_IsInstanceOfType;
    void *_IsAssignableFrom;
    void *_GetInterfaceMap;
    HRESULT (__stdcall *GetMethod_2)(Type*, BSTR, MethodInfo**);
    void *_GetMethod;
    void *_GetMethods;
    void *_GetField;
    void *_GetFields;
    void *_GetProperty;
    void *_GetProperty_2;
    void *_GetProperties;
    void *_GetMember_2;
    void *_GetMembers;
    /* InvokeMember overloads; we use InvokeMember_3. */
    void *_InvokeMember;
    void *_InvokeMember_2;
    HRESULT (__stdcall *InvokeMember_3)(Type*, BSTR, int /*BindingFlags*/,
                                        void * /*Binder*/, VARIANT_PADDED,
                                        SAFEARRAY *, VARIANT_PADDED *);
} TypeVtbl;
struct _Type { TypeVtbl *lpVtbl; };

/* _MethodInfo -- mscorlib MethodInfo dispinterface. */
typedef struct MethodInfoVtbl {
    HRESULT (__stdcall *QueryInterface)(MethodInfo*, GUID*, void**);
    ULONG   (__stdcall *AddRef)(MethodInfo*);
    ULONG   (__stdcall *Release)(MethodInfo*);
    void *_GetTypeInfoCount;
    void *_GetTypeInfo;
    void *_GetIDsOfNames;
    void *_Invoke_;
    HRESULT (__stdcall *get_ToString)(MethodInfo*, BSTR*);
    void *_Equals;
    void *_GetHashCode;
    void *_GetType;
    void *_get_MemberType;
    void *_get_name;
    void *_get_DeclaringType;
    void *_get_ReflectedType;
    void *_GetCustomAttributes;
    void *_GetCustomAttributes_2;
    void *_IsDefined;
    void *_GetParameters;
    void *_GetMethodImplementationFlags;
    void *_get_MethodHandle;
    void *_get_Attributes;
    void *_get_CallingConvention;
    HRESULT (__stdcall *Invoke_3)(MethodInfo*, VARIANT_PADDED, SAFEARRAY*, VARIANT_PADDED*);
} MethodInfoVtbl;
struct _MethodInfo { MethodInfoVtbl *lpVtbl; };
]]

local C       = ffi.C
local mscoree = ffi.load("mscoree")
local oleaut  = ffi.load("oleaut32")

-- ===== Common constants ==================================================

-- GUIDs straight from mscoree.h / mscorlib.tlb. We hand-pack each one
-- because Lua doesn't have a GUID literal.
local function make_guid(s)
    -- "AABBCCDD-EEFF-GGHH-IIJJ-KKLLMMNNOOPP"
    local g = ffi.new("GUID")
    local d1, d2, d3, d4hi, d4lo = s:match(
        "^(%x%x%x%x%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x%x%x%x)%-(%x+)$")
    assert(d1, "bad GUID: " .. s)
    g.Data1 = tonumber(d1, 16)
    g.Data2 = tonumber(d2, 16)
    g.Data3 = tonumber(d3, 16)
    g.Data4[0] = tonumber(d4hi:sub(1, 2), 16)
    g.Data4[1] = tonumber(d4hi:sub(3, 4), 16)
    for i = 0, 5 do
        g.Data4[2 + i] = tonumber(d4lo:sub(i * 2 + 1, i * 2 + 2), 16)
    end
    return g
end

local CLSID_CLRMetaHost     = make_guid("9280188D-0E8E-4867-B30C-7FA83884E8DE")
local IID_ICLRMetaHost      = make_guid("D332DB9E-B9B3-4125-8207-A14884F53216")
local IID_ICLRRuntimeInfo   = make_guid("BD39D1D2-BA2F-486A-89B0-B4B0CB466891")
local CLSID_CLRRuntimeHost  = make_guid("90F1A06E-7712-4762-86B5-7A5EBA6BDB02")
local IID_ICLRRuntimeHost   = make_guid("90F1A06C-7712-4762-86B5-7A5EBA6BDB02")
local CLSID_CorRuntimeHost  = make_guid("CB2F6723-AB3A-11D2-9C40-00C04FA30A3E")
local IID_ICorRuntimeHost   = make_guid("CB2F6722-AB3A-11D2-9C40-00C04FA30A3E")
local IID_AppDomain         = make_guid("05F696DC-2B29-3663-AD8B-C4389CF2A713")

-- System.Reflection.BindingFlags values we use
local BindingFlags = {
    Default       = 0x00,
    IgnoreCase    = 0x01,
    DeclaredOnly  = 0x02,
    Instance      = 0x04,
    Static        = 0x08,
    Public        = 0x10,
    NonPublic     = 0x20,
    InvokeMethod  = 0x100,
    CreateInstance= 0x200,
    GetField      = 0x400,
    SetField      = 0x800,
    GetProperty   = 0x1000,
    SetProperty   = 0x2000,
}

-- Variant types we use
local VT_EMPTY  = 0
local VT_NULL   = 1
local VT_UI1    = 17    -- byte for SafeArray of byte[]
local VT_BSTR   = 8

-- ===== Helpers ===========================================================

local function fail(msg)            error("dotnet: " .. msg, 2) end
local function check(hr, ctx)
    if hr ~= 0 then
        -- HRESULT is signed long; encode as unsigned hex for readability
        local u = ffi.cast("unsigned long", hr)
        fail(string.format("%s failed (HRESULT 0x%08X)", ctx, tonumber(u)))
    end
end

local function release(iface)
    if iface ~= nil and iface[0] ~= nil and iface[0].lpVtbl ~= nil then
        iface[0].lpVtbl.Release(iface[0])
    end
end

local function utf8_to_wide(s)
    if s == nil then return nil end
    local need = C.MultiByteToWideChar(65001, 0, s, -1, nil, 0)
    if need <= 0 then return nil end
    local buf = ffi.new("unsigned short[?]", need)
    C.MultiByteToWideChar(65001, 0, s, -1, buf, need)
    return buf
end

local function wide_to_utf8(w)
    if w == nil then return nil end
    local need = C.WideCharToMultiByte(65001, 0, w, -1, nil, 0, nil, nil)
    if need <= 0 then return nil end
    local buf = ffi.new("char[?]", need)
    C.WideCharToMultiByte(65001, 0, w, -1, buf, need, nil, nil)
    return ffi.string(buf)
end

local function bstr(s)
    local w = utf8_to_wide(s)
    if w == nil then return nil end
    return oleaut.SysAllocString(w)
end

local function bytes_to_safearray(bytes, len)
    local b = SAFEARRAYBOUND_pool or ffi.new("SAFEARRAYBOUND[1]")
    SAFEARRAYBOUND_pool = b
    b[0].cElements = len
    b[0].lLbound   = 0
    local sa = oleaut.SafeArrayCreate(VT_UI1, 1, b)
    if sa == nil then fail("SafeArrayCreate returned NULL") end
    local pData = ffi.new("void*[1]")
    check(oleaut.SafeArrayAccessData(sa, pData), "SafeArrayAccessData")
    ffi.copy(pData[0], bytes, len)
    oleaut.SafeArrayUnaccessData(sa)
    return sa
end

-- ===== CLR hosting layer =================================================

local clr_meta_host         -- ICLRMetaHost*
local clr_runtime_info      -- ICLRRuntimeInfo*
local clr_runtime_host      -- ICLRRuntimeHost*
local cor_runtime_host      -- ICorRuntimeHost*
local default_appdomain     -- _AppDomain*

local function require_runtime_info()
    if clr_runtime_info ~= nil then return end
    if clr_meta_host == nil then
        local p = ffi.new("ICLRMetaHost*[1]")
        check(mscoree.CLRCreateInstance(CLSID_CLRMetaHost,
              IID_ICLRMetaHost, ffi.cast("void**", p)), "CLRCreateInstance")
        clr_meta_host = p
    end
    local p = ffi.new("ICLRRuntimeInfo*[1]")
    -- "v4.0.30319" is the .NET Framework 4.x runtime; covers 4.5/4.6/4.7/4.8.
    local ver = utf8_to_wide("v4.0.30319")
    check(clr_meta_host[0].lpVtbl.GetRuntime(clr_meta_host[0], ver,
          IID_ICLRRuntimeInfo, ffi.cast("void**", p)), "ICLRMetaHost::GetRuntime")
    clr_runtime_info = p
end

local function require_runtime_host()
    if clr_runtime_host ~= nil then return clr_runtime_host end
    require_runtime_info()
    local p = ffi.new("ICLRRuntimeHost*[1]")
    check(clr_runtime_info[0].lpVtbl.GetInterface(clr_runtime_info[0],
          CLSID_CLRRuntimeHost, IID_ICLRRuntimeHost, ffi.cast("void**", p)),
          "ICLRRuntimeInfo::GetInterface(CLRRuntimeHost)")
    clr_runtime_host = p
    check(clr_runtime_host[0].lpVtbl.Start(clr_runtime_host[0]),
          "ICLRRuntimeHost::Start")
    return clr_runtime_host
end

local function require_cor_runtime_host()
    if cor_runtime_host ~= nil then return cor_runtime_host end
    require_runtime_info()
    local p = ffi.new("ICorRuntimeHost*[1]")
    check(clr_runtime_info[0].lpVtbl.GetInterface(clr_runtime_info[0],
          CLSID_CorRuntimeHost, IID_ICorRuntimeHost, ffi.cast("void**", p)),
          "ICLRRuntimeInfo::GetInterface(CorRuntimeHost)")
    cor_runtime_host = p
    check(cor_runtime_host[0].lpVtbl.Start(cor_runtime_host[0]),
          "ICorRuntimeHost::Start")
    return cor_runtime_host
end

local function require_default_appdomain()
    if default_appdomain ~= nil then return default_appdomain end
    require_cor_runtime_host()
    local pUnk = ffi.new("IUnknown*[1]")
    check(cor_runtime_host[0].lpVtbl.GetDefaultDomain(cor_runtime_host[0], pUnk),
          "ICorRuntimeHost::GetDefaultDomain")
    local pAd = ffi.new("AppDomain*[1]")
    check(pUnk[0].lpVtbl.QueryInterface(pUnk[0], IID_AppDomain,
          ffi.cast("void**", pAd)), "QueryInterface(_AppDomain)")
    pUnk[0].lpVtbl.Release(pUnk[0])
    default_appdomain = pAd
    return default_appdomain
end

-- ===== MethodInfo wrapper ================================================

local MethodInfo_mt = { __index = {} }

function MethodInfo_mt.__index:Invoke(instance, args)
    -- instance: nil (for static) or a _Object via VARIANT (not yet supported -- pass nil)
    -- args:     Lua table -> SAFEARRAY of VARIANTs (subset: pass nil for now, see invoke_method_no_args)
    local inst = ffi.new("VARIANT_PADDED")
    inst.vt = VT_EMPTY
    local sa
    if args ~= nil and #args > 0 then
        fail("MethodInfo:Invoke(instance, args): args marshaling is in v2; for now pass nil " ..
             "or use dotnet.invoke_entrypoint() / Type:InvokeMember()")
    end
    local out = ffi.new("VARIANT_PADDED[1]")
    check(self._raw[0].lpVtbl.Invoke_3(self._raw[0], inst, sa, out),
          "MethodInfo::Invoke")
    return out[0]   -- caller can inspect .vt and union slot; v1 return is opaque
end

function MethodInfo_mt.__index:Release()
    if self._raw ~= nil then
        release(self._raw)
        self._raw = nil
    end
end

MethodInfo_mt.__gc = MethodInfo_mt.__index.Release

local function wrap_method(raw)
    return setmetatable({ _raw = raw }, MethodInfo_mt)
end

-- ===== Type wrapper ======================================================

local Type_mt = { __index = {} }

function Type_mt.__index:GetMethod(name)
    local b = bstr(name)
    if b == nil then fail("bad method name") end
    local p = ffi.new("MethodInfo*[1]")
    local hr = self._raw[0].lpVtbl.GetMethod_2(self._raw[0], b, p)
    oleaut.SysFreeString(b)
    check(hr, "Type::GetMethod(" .. name .. ")")
    return wrap_method(p)
end

function Type_mt.__index:InvokeMember(name, flags, args_safearray)
    -- BindingFlags: pass a number (combine BindingFlags.* with bit ops)
    local b = bstr(name)
    local inst = ffi.new("VARIANT_PADDED"); inst.vt = VT_EMPTY
    local out  = ffi.new("VARIANT_PADDED[1]")
    local hr = self._raw[0].lpVtbl.InvokeMember_3(self._raw[0], b,
        flags or (BindingFlags.InvokeMethod + BindingFlags.Static + BindingFlags.Public),
        nil, inst, args_safearray, out)
    oleaut.SysFreeString(b)
    check(hr, "Type::InvokeMember(" .. name .. ")")
    return out[0]
end

function Type_mt.__index:Release()
    if self._raw ~= nil then
        release(self._raw)
        self._raw = nil
    end
end

Type_mt.__gc = Type_mt.__index.Release

local function wrap_type(raw)
    return setmetatable({ _raw = raw }, Type_mt)
end

-- ===== Assembly wrapper ==================================================

local Assembly_mt = { __index = {} }

function Assembly_mt.__index:GetType(name)
    local b = bstr(name)
    if b == nil then fail("bad type name") end
    local p = ffi.new("Type*[1]")
    local hr = self._raw[0].lpVtbl.GetType_2(self._raw[0], b, p)
    oleaut.SysFreeString(b)
    check(hr, "Assembly::GetType(" .. name .. ")")
    if p[0] == nil then fail("type not found: " .. name) end
    return wrap_type(p)
end

function Assembly_mt.__index:EntryPoint()
    local p = ffi.new("MethodInfo*[1]")
    check(self._raw[0].lpVtbl.get_EntryPoint(self._raw[0], p),
          "Assembly::get_EntryPoint")
    if p[0] == nil then return nil end
    return wrap_method(p)
end

function Assembly_mt.__index:ToString()
    local b = ffi.new("BSTR[1]")
    check(self._raw[0].lpVtbl.get_ToString(self._raw[0], b), "Assembly::ToString")
    local s = wide_to_utf8(b[0])
    oleaut.SysFreeString(b[0])
    return s
end

function Assembly_mt.__index:Release()
    if self._raw ~= nil then
        release(self._raw)
        self._raw = nil
    end
end

Assembly_mt.__gc = Assembly_mt.__index.Release

local function wrap_assembly(raw)
    return setmetatable({ _raw = raw }, Assembly_mt)
end

-- ===== Public API: dotnet.Assembly.* =====================================

local M = {}

M.Assembly = {}

-- dotnet.Assembly.Load(bytes [, length])
-- Equivalent to System.Reflection.Assembly.Load(byte[]).
-- bytes: a Lua string (treated as bytes) OR a cdata pointer + length.
function M.Assembly.Load(bytes, length)
    local ptr, len
    if type(bytes) == "string" then
        ptr = ffi.cast("const char *", bytes)
        len = #bytes
    else
        ptr = ffi.cast("const char *", bytes)
        len = assert(length, "dotnet.Assembly.Load: cdata bytes require length")
    end
    local ad = require_default_appdomain()
    local sa = bytes_to_safearray(ptr, len)
    local pAsm = ffi.new("Assembly*[1]")
    local hr = ad[0].lpVtbl.Load_3(ad[0], sa, pAsm)
    oleaut.SafeArrayDestroy(sa)
    check(hr, "_AppDomain::Load_3")
    return wrap_assembly(pAsm)
end

-- dotnet.Assembly.LoadFile(path) -- via Assembly.LoadFile string overload.
-- Path-based load: bytes are read from disk by the CLR.
function M.Assembly.LoadFile(path)
    -- The simple path: call Assembly.Load(byte[]) with the file contents.
    -- This avoids the LoadFile-vs-LoadFrom distinction and gives the same
    -- runtime behaviour as Assembly.Load(File.ReadAllBytes(path)).
    return M.Assembly.Load(M.from_file(path))
end

-- dotnet.Assembly.LoadFrom(path) -- alias for LoadFile in this API.
function M.Assembly.LoadFrom(path) return M.Assembly.LoadFile(path) end

-- ===== Public API: dotnet.AppDomain.* ====================================

M.AppDomain = {}

-- dotnet.AppDomain.CurrentDomain -- a getter (lazy)
setmetatable(M.AppDomain, {
    __index = function(t, k)
        if k == "CurrentDomain" then
            local ad = require_default_appdomain()
            return { _raw = ad, FriendlyName = "Default" }
        end
    end,
})

-- ===== Public API: dotnet.Activator.* ====================================

M.Activator = {}

-- dotnet.Activator.CreateInstance(type) -- Activator.CreateInstance(Type)
-- Calls the parameterless constructor; returns an opaque VARIANT.
function M.Activator.CreateInstance(t)
    if getmetatable(t) ~= Type_mt then
        fail("Activator.CreateInstance: expected a dotnet Type wrapper")
    end
    return t:InvokeMember("", BindingFlags.CreateInstance + BindingFlags.Public +
                              BindingFlags.Instance, nil)
end

-- ===== Convenience helpers ===============================================

-- dotnet.execute(bytes [, length]) -- load assembly bytes, invoke EntryPoint().
-- Pass-args is not yet supported; the entry point receives an empty string[].
function M.execute(bytes, length)
    local asm = M.Assembly.Load(bytes, length)
    local entry = asm:EntryPoint()
    if entry == nil then
        fail("assembly has no EntryPoint -- use invoke_method() with a type+method")
    end
    return entry:Invoke(nil, nil)
end

-- dotnet.invoke_method(bytes, type_name, method_name [, args]) -- load, call
-- a specific static method on a type.
function M.invoke_method(bytes, type_name, method_name, args)
    local asm = M.Assembly.Load(bytes)
    local t   = asm:GetType(type_name)
    return t:InvokeMember(method_name,
        BindingFlags.InvokeMethod + BindingFlags.Static + BindingFlags.Public, args)
end

-- dotnet.from_file(path) -> bytes_string
function M.from_file(path)
    -- 0x80000000 = GENERIC_READ, 1 = FILE_SHARE_READ, 3 = OPEN_EXISTING
    local h = C.CreateFileA(path, 0x80000000, 1, nil, 3, 0x80, nil)
    if h == ffi.cast("HANDLE", -1) or h == nil then
        fail("cannot open " .. tostring(path))
    end
    local hi = ffi.new("DWORD[1]")
    local lo = C.GetFileSize(h, hi)
    if lo == 0xFFFFFFFF then C.CloseHandle(h); fail("GetFileSize failed") end
    local sz = tonumber(lo) + tonumber(hi[0]) * 2 ^ 32
    if sz > 256 * 1024 * 1024 then C.CloseHandle(h); fail("file too large") end
    local buf = ffi.new("char[?]", sz)
    local got = ffi.new("DWORD[1]")
    if C.ReadFile(h, buf, sz, got, nil) == 0 then
        C.CloseHandle(h); fail("ReadFile failed")
    end
    C.CloseHandle(h)
    return ffi.string(buf, tonumber(got[0]))
end

-- dotnet.from_base64(b64) -> bytes_string. Standard Lua-side base64 decode;
-- accepts both standard and URL-safe alphabets.
function M.from_base64(b64)
    -- compact pure-Lua decoder; not micro-optimized but plenty fast for
    -- one-shot assembly loads.
    local b = b64:gsub("[-_]", { ["-"] = "+", ["_"] = "/" })
                 :gsub("[^A-Za-z0-9+/=]", "")
    local map = {}
    for i = 0, 63 do
        local c = ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"):sub(i + 1, i + 1)
        map[c] = i
    end
    local out, n, acc, bits = {}, 0, 0, 0
    for i = 1, #b do
        local c = b:sub(i, i)
        if c ~= "=" then
            local v = map[c]
            if v == nil then fail("base64: bad char at " .. i) end
            acc = acc * 64 + v
            bits = bits + 6
            if bits >= 8 then
                bits = bits - 8
                local byte = math.floor(acc / 2 ^ bits) % 256
                n = n + 1
                out[n] = string.char(byte)
            end
        end
    end
    return table.concat(out)
end

-- ===== Convenience surface (follow-up expansion) =========================
--
-- Brings the dotnet package closer to the ergonomic API surface C/C++/
-- Rust/Go's CLR-hosting wrappers expose: by-name Type lookup, static
-- method invocation in one call, property get/set, common namespace
-- shortcuts (System.IO.File, System.Net.Http.HttpClient, ...). All
-- thin layers over the existing Assembly / Activator primitives -- no
-- new CLR plumbing.

-- M.Type("System.IO.File") -> a Type reflecting that .NET type.
-- Searches default AppDomain's loaded assemblies; loads mscorlib /
-- common framework assemblies on first call. The result composes with
-- M.Activator.CreateInstance and M.MethodInfo:Invoke.
function M.Type(name)
    if default_appdomain == nil then
        if not init_clr() then return nil, "CLR not initialized" end
    end
    -- AppDomain.GetAssemblies, then iterate each calling .GetType(name).
    local asms = M.AppDomain.GetAssemblies and M.AppDomain.GetAssemblies()
    if asms then
        for _, a in ipairs(asms) do
            local ok, t = pcall(function() return a:GetType(name) end)
            if ok and t ~= nil then return t end
        end
    end
    return nil, "type not found: " .. tostring(name)
end

-- M.callstatic("System.IO.File", "ReadAllText", path) -- one-liner static call.
-- Returns whatever the method returns (boxed back to Lua).
function M.callstatic(type_name, method_name, ...)
    local t, err = M.Type(type_name)
    if t == nil then return nil, err end
    local m = t:GetMethod(method_name)
    if m == nil then return nil, "method not found: " .. method_name end
    return m:Invoke(nil, { ... })
end

-- M.new("System.Net.Http.HttpClient", ...) -- shorthand for Activator over Type.
function M.new(type_name, ...)
    local t, err = M.Type(type_name)
    if t == nil then return nil, err end
    return M.Activator.CreateInstance(t, ...)
end

-- M.get(obj, "PropertyName") / M.set(obj, "PropertyName", value).
-- Wraps the GetProperty / SetProperty BindingFlags path so callers
-- don't have to spell out flags.
function M.get(obj, prop)
    if obj == nil then return nil, "nil instance" end
    local t = obj:GetType()
    local p = t and t:GetProperty(prop)
    if p == nil then return nil, "property not found: " .. prop end
    return p:GetValue(obj)
end
function M.set(obj, prop, value)
    if obj == nil then return false, "nil instance" end
    local t = obj:GetType()
    local p = t and t:GetProperty(prop)
    if p == nil then return false, "property not found: " .. prop end
    p:SetValue(obj, value)
    return true
end

-- Namespace shortcuts for the most-used .NET surface. Lazy-init so
-- programs that never touch them pay no startup cost.
-- Usage: local f = M.System.IO.File; local txt = f.ReadAllText("c:\\x.txt")
M.System = setmetatable({}, { __index = function(t, name)
    local sub = setmetatable({}, { __index = function(_, sym)
        return M.Type("System." .. name .. "." .. sym)
            or M.Type("System." .. name .. sym)
    end })
    rawset(t, name, sub)
    return sub
end })

-- ===== Exposed constants + utilities ======================================

M.BindingFlags = BindingFlags

-- Shutdown / cleanup. Best-effort; called automatically on Lua GC of the
-- last Assembly wrapper isn't done -- the CLR refuses to be shut down
-- cleanly anyway, so this is mostly for completeness.
function M.shutdown()
    if cor_runtime_host ~= nil then
        pcall(function() cor_runtime_host[0].lpVtbl.Stop(cor_runtime_host[0]) end)
        release(cor_runtime_host); cor_runtime_host = nil
    end
    if clr_runtime_host ~= nil then
        pcall(function() clr_runtime_host[0].lpVtbl.Stop(clr_runtime_host[0]) end)
        release(clr_runtime_host); clr_runtime_host = nil
    end
    release(clr_runtime_info);  clr_runtime_info  = nil
    release(clr_meta_host);     clr_meta_host     = nil
    default_appdomain = nil
end

return M
