-- wasapi -- Windows Audio Session API capture / playback.
--
-- Talks IMMDeviceEnumerator / IMMDevice / IAudioClient + IAudioRenderClient
-- / IAudioCaptureClient via FFI vtables. Shared mode is the default; both
-- shared and exclusive modes are exposed. Loopback capture works by
-- opening a render endpoint with the AUDCLNT_STREAMFLAGS_LOOPBACK flag.
--
-- Surface:
--   wasapi.enumerate("render"|"capture")  -> { device, ... }
--   wasapi.default("render"|"capture")    -> device
--
--   device:open(opts?)
--     opts = {
--       mode      = "shared"|"exclusive",
--       loopback  = bool,                  (capture: defaults false; render endpoints support loopback)
--       format    = { sample_rate, channels, bits, float = bool },
--       buffer_ms = number,                (target buffer length; default 20ms)
--     }
--   -> client
--
--   client:start()                  -- begin streaming
--   client:stop()                   -- pause
--   client:close()                  -- release
--   client:get_format()             -> { sample_rate, channels, bits, float }
--   client:get_buffer_size()        -> frames
--   client:get_padding()            -> frames currently in the device buffer
--   client:write(samples)           (render)   bytes in the device's wave format
--   client:read(max_frames)         (capture) -> bytes, frames_returned, flags
--   client:set_volume(level)        0.0 .. 1.0
--   client:get_volume()             -> float
--
-- Loopback capture: open the *render* device and pass loopback=true.

local ffi = ffi
local W   = require "windows"
require "windows.com"

local C = ffi.C
local M = {}

-- ===== cdef ============================================================

ffi.cdef[[
typedef struct IMMDeviceEnumerator IMMDeviceEnumerator;
typedef struct IMMDevice           IMMDevice;
typedef struct IMMDeviceCollection IMMDeviceCollection;
typedef struct IAudioClient        IAudioClient;
typedef struct IAudioRenderClient  IAudioRenderClient;
typedef struct IAudioCaptureClient IAudioCaptureClient;
typedef struct IPropertyStore      IPropertyStore;
typedef struct ISimpleAudioVolume  ISimpleAudioVolume;

typedef struct WAVEFORMATEX {
    WORD  wFormatTag;
    WORD  nChannels;
    DWORD nSamplesPerSec;
    DWORD nAvgBytesPerSec;
    WORD  nBlockAlign;
    WORD  wBitsPerSample;
    WORD  cbSize;
} WAVEFORMATEX;

typedef struct WAVEFORMATEXTENSIBLE {
    WAVEFORMATEX Format;
    union {
        WORD wValidBitsPerSample;
        WORD wSamplesPerBlock;
        WORD wReserved;
    } Samples;
    DWORD dwChannelMask;
    GUID_W SubFormat;
} WAVEFORMATEXTENSIBLE;

typedef struct IMMDeviceEnumeratorVtbl {
    HRESULT (__stdcall *QueryInterface)(IMMDeviceEnumerator*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IMMDeviceEnumerator*);
    ULONG   (__stdcall *Release)(IMMDeviceEnumerator*);
    HRESULT (__stdcall *EnumAudioEndpoints)(IMMDeviceEnumerator*, DWORD, DWORD, IMMDeviceCollection**);
    HRESULT (__stdcall *GetDefaultAudioEndpoint)(IMMDeviceEnumerator*, DWORD, DWORD, IMMDevice**);
    HRESULT (__stdcall *GetDevice)(IMMDeviceEnumerator*, LPCWSTR, IMMDevice**);
    HRESULT (__stdcall *RegisterEndpointNotificationCallback)(IMMDeviceEnumerator*, void*);
    HRESULT (__stdcall *UnregisterEndpointNotificationCallback)(IMMDeviceEnumerator*, void*);
} IMMDeviceEnumeratorVtbl;
struct IMMDeviceEnumerator { IMMDeviceEnumeratorVtbl *lpVtbl; };

typedef struct IMMDeviceCollectionVtbl {
    HRESULT (__stdcall *QueryInterface)(IMMDeviceCollection*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IMMDeviceCollection*);
    ULONG   (__stdcall *Release)(IMMDeviceCollection*);
    HRESULT (__stdcall *GetCount)(IMMDeviceCollection*, UINT*);
    HRESULT (__stdcall *Item)(IMMDeviceCollection*, UINT, IMMDevice**);
} IMMDeviceCollectionVtbl;
struct IMMDeviceCollection { IMMDeviceCollectionVtbl *lpVtbl; };

typedef struct IMMDeviceVtbl {
    HRESULT (__stdcall *QueryInterface)(IMMDevice*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IMMDevice*);
    ULONG   (__stdcall *Release)(IMMDevice*);
    HRESULT (__stdcall *Activate)(IMMDevice*, GUID_W*, DWORD, void*, void**);
    HRESULT (__stdcall *OpenPropertyStore)(IMMDevice*, DWORD, IPropertyStore**);
    HRESULT (__stdcall *GetId)(IMMDevice*, LPWSTR*);
    HRESULT (__stdcall *GetState)(IMMDevice*, DWORD*);
} IMMDeviceVtbl;
struct IMMDevice { IMMDeviceVtbl *lpVtbl; };

typedef struct PROPERTYKEY {
    GUID_W fmtid;
    DWORD  pid;
} PROPERTYKEY;

typedef struct PROPVARIANT {
    WORD vt;
    WORD _pad1, _pad2, _pad3;
    union {
        LONG  lVal;
        ULONG ulVal;
        ULONGLONG uhVal;
        LPCWSTR pwszVal;
        void *pBlob;
    } u;
    /* full PROPVARIANT is 24 bytes on x64; the union above plus the
       leading 8 bytes of header == 16, so pad to 24. */
    DWORD _pad4, _pad5;
} PROPVARIANT;

typedef struct IPropertyStoreVtbl {
    HRESULT (__stdcall *QueryInterface)(IPropertyStore*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IPropertyStore*);
    ULONG   (__stdcall *Release)(IPropertyStore*);
    HRESULT (__stdcall *GetCount)(IPropertyStore*, DWORD*);
    HRESULT (__stdcall *GetAt)(IPropertyStore*, DWORD, PROPERTYKEY*);
    HRESULT (__stdcall *GetValue)(IPropertyStore*, PROPERTYKEY*, PROPVARIANT*);
    HRESULT (__stdcall *SetValue)(IPropertyStore*, PROPERTYKEY*, PROPVARIANT*);
    HRESULT (__stdcall *Commit)(IPropertyStore*);
} IPropertyStoreVtbl;
struct IPropertyStore { IPropertyStoreVtbl *lpVtbl; };

typedef struct IAudioClientVtbl {
    HRESULT (__stdcall *QueryInterface)(IAudioClient*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IAudioClient*);
    ULONG   (__stdcall *Release)(IAudioClient*);
    HRESULT (__stdcall *Initialize)(IAudioClient*, DWORD, DWORD, LONGLONG, LONGLONG, WAVEFORMATEX*, GUID_W*);
    HRESULT (__stdcall *GetBufferSize)(IAudioClient*, UINT*);
    HRESULT (__stdcall *GetStreamLatency)(IAudioClient*, LONGLONG*);
    HRESULT (__stdcall *GetCurrentPadding)(IAudioClient*, UINT*);
    HRESULT (__stdcall *IsFormatSupported)(IAudioClient*, DWORD, WAVEFORMATEX*, WAVEFORMATEX**);
    HRESULT (__stdcall *GetMixFormat)(IAudioClient*, WAVEFORMATEX**);
    HRESULT (__stdcall *GetDevicePeriod)(IAudioClient*, LONGLONG*, LONGLONG*);
    HRESULT (__stdcall *Start)(IAudioClient*);
    HRESULT (__stdcall *Stop)(IAudioClient*);
    HRESULT (__stdcall *Reset)(IAudioClient*);
    HRESULT (__stdcall *SetEventHandle)(IAudioClient*, HANDLE);
    HRESULT (__stdcall *GetService)(IAudioClient*, GUID_W*, void**);
} IAudioClientVtbl;
struct IAudioClient { IAudioClientVtbl *lpVtbl; };

typedef struct IAudioRenderClientVtbl {
    HRESULT (__stdcall *QueryInterface)(IAudioRenderClient*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IAudioRenderClient*);
    ULONG   (__stdcall *Release)(IAudioRenderClient*);
    HRESULT (__stdcall *GetBuffer)(IAudioRenderClient*, UINT, BYTE**);
    HRESULT (__stdcall *ReleaseBuffer)(IAudioRenderClient*, UINT, DWORD);
} IAudioRenderClientVtbl;
struct IAudioRenderClient { IAudioRenderClientVtbl *lpVtbl; };

typedef struct IAudioCaptureClientVtbl {
    HRESULT (__stdcall *QueryInterface)(IAudioCaptureClient*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IAudioCaptureClient*);
    ULONG   (__stdcall *Release)(IAudioCaptureClient*);
    HRESULT (__stdcall *GetBuffer)(IAudioCaptureClient*, BYTE**, UINT*, DWORD*, ULONGLONG*, ULONGLONG*);
    HRESULT (__stdcall *ReleaseBuffer)(IAudioCaptureClient*, UINT);
    HRESULT (__stdcall *GetNextPacketSize)(IAudioCaptureClient*, UINT*);
} IAudioCaptureClientVtbl;
struct IAudioCaptureClient { IAudioCaptureClientVtbl *lpVtbl; };

typedef struct ISimpleAudioVolumeVtbl {
    HRESULT (__stdcall *QueryInterface)(ISimpleAudioVolume*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(ISimpleAudioVolume*);
    ULONG   (__stdcall *Release)(ISimpleAudioVolume*);
    HRESULT (__stdcall *SetMasterVolume)(ISimpleAudioVolume*, float, GUID_W*);
    HRESULT (__stdcall *GetMasterVolume)(ISimpleAudioVolume*, float*);
    HRESULT (__stdcall *SetMute)(ISimpleAudioVolume*, BOOL, GUID_W*);
    HRESULT (__stdcall *GetMute)(ISimpleAudioVolume*, BOOL*);
} ISimpleAudioVolumeVtbl;
struct ISimpleAudioVolume { ISimpleAudioVolumeVtbl *lpVtbl; };
]]

-- ===== GUIDs ===========================================================

local function make_guid(d1, d2, d3, d4)
    local g = ffi.new("GUID_W")
    g.Data1 = d1; g.Data2 = d2; g.Data3 = d3
    for i = 0, 7 do g.Data4[i] = d4[i + 1] end
    return g
end

-- CLSID_MMDeviceEnumerator: BCDE0395-E52F-467C-8E3D-C4579291692E
local CLSID_MMDeviceEnumerator = make_guid(0xBCDE0395, 0xE52F, 0x467C, {0x8E,0x3D,0xC4,0x57,0x92,0x91,0x69,0x2E})
-- IID_IMMDeviceEnumerator: A95664D2-9614-4F35-A746-DE8DB63617E6
local IID_IMMDeviceEnumerator  = make_guid(0xA95664D2, 0x9614, 0x4F35, {0xA7,0x46,0xDE,0x8D,0xB6,0x36,0x17,0xE6})
-- IID_IAudioClient: 1CB9AD4C-DBFA-4C32-B178-C2F568A703B2
local IID_IAudioClient         = make_guid(0x1CB9AD4C, 0xDBFA, 0x4C32, {0xB1,0x78,0xC2,0xF5,0x68,0xA7,0x03,0xB2})
-- IID_IAudioRenderClient: F294ACFC-3146-4483-A7BF-ADDCA7C260E2
local IID_IAudioRenderClient   = make_guid(0xF294ACFC, 0x3146, 0x4483, {0xA7,0xBF,0xAD,0xDC,0xA7,0xC2,0x60,0xE2})
-- IID_IAudioCaptureClient: C8ADBD64-E71E-48A0-A4DE-185C395CD317
local IID_IAudioCaptureClient  = make_guid(0xC8ADBD64, 0xE71E, 0x48A0, {0xA4,0xDE,0x18,0x5C,0x39,0x5C,0xD3,0x17})
-- IID_ISimpleAudioVolume: 87CE5498-68D6-44E5-9215-6DA47EF883D8
local IID_ISimpleAudioVolume   = make_guid(0x87CE5498, 0x68D6, 0x44E5, {0x92,0x15,0x6D,0xA4,0x7E,0xF8,0x83,0xD8})

-- KSDATAFORMAT_SUBTYPE_PCM            00000001-0000-0010-8000-00aa00389b71
local KSDATAFORMAT_SUBTYPE_PCM        = make_guid(0x00000001, 0x0000, 0x0010, {0x80,0x00,0x00,0xAA,0x00,0x38,0x9B,0x71})
-- KSDATAFORMAT_SUBTYPE_IEEE_FLOAT     00000003-0000-0010-8000-00aa00389b71
local KSDATAFORMAT_SUBTYPE_IEEE_FLOAT = make_guid(0x00000003, 0x0000, 0x0010, {0x80,0x00,0x00,0xAA,0x00,0x38,0x9B,0x71})

-- PKEY_Device_FriendlyName: a45c254e-df1c-4efd-8020-67d146a850e0, pid 14
local PKEY_Device_FriendlyName = ffi.new("PROPERTYKEY")
PKEY_Device_FriendlyName.fmtid = make_guid(0xa45c254e, 0xdf1c, 0x4efd, {0x80,0x20,0x67,0xd1,0x46,0xa8,0x50,0xe0})
PKEY_Device_FriendlyName.pid   = 14

-- ===== Constants =======================================================

local eRender   = 0
local eCapture  = 1
local eConsole  = 0
local DEVICE_STATE_ACTIVE = 0x00000001

local AUDCLNT_SHAREMODE_SHARED    = 0
local AUDCLNT_SHAREMODE_EXCLUSIVE = 1

local AUDCLNT_STREAMFLAGS_LOOPBACK       = 0x00020000
local AUDCLNT_STREAMFLAGS_EVENTCALLBACK  = 0x00040000
local AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM = 0x80000000
local AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY = 0x08000000

local AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY = 0x1
local AUDCLNT_BUFFERFLAGS_SILENT             = 0x2
local AUDCLNT_BUFFERFLAGS_TIMESTAMP_ERROR    = 0x4

local STGM_READ = 0
local CLSCTX_ALL = 0x17

M.LOOPBACK = AUDCLNT_STREAMFLAGS_LOOPBACK

-- 100-nanosecond units per millisecond.
local REFTIMES_PER_MS = 10000

-- ===== HRESULT helper ==================================================

local function check_hr(hr, where)
    if hr ~= 0 then
        local u = tonumber(ffi.cast("DWORD", hr))
        error(string.format("wasapi: %s failed (HRESULT 0x%08x)", where, u), 2)
    end
end

local function maybe_coinit()
    local hr = C.CoInitializeEx(nil, 0)  -- MULTITHREADED
    -- S_FALSE / RPC_E_CHANGED_MODE are tolerable; everything else is fatal.
    if hr ~= 0 and hr ~= 1 then
        local u = tonumber(ffi.cast("DWORD", hr))
        if u ~= 0x80010106 then
            error(string.format("wasapi: CoInitializeEx failed (0x%08x)", u))
        end
    end
end

-- ===== Enumerator wrapper ==============================================

local _enum
local function enum()
    if _enum then return _enum end
    maybe_coinit()
    local pp = ffi.new("void*[1]")
    local hr = C.CoCreateInstance(CLSID_MMDeviceEnumerator, nil,
                                  CLSCTX_ALL, IID_IMMDeviceEnumerator, pp)
    check_hr(hr, "CoCreateInstance(MMDeviceEnumerator)")
    _enum = ffi.gc(ffi.cast("IMMDeviceEnumerator*", pp[0]),
                   function(p) p.lpVtbl.Release(p) end)
    return _enum
end

-- ===== Device wrapper ==================================================

local Device = {}
Device.__index = Device

local function wrap_device(ptr, is_default, dir)
    return setmetatable({
        _ptr        = ffi.gc(ptr, function(p) p.lpVtbl.Release(p) end),
        _is_default = is_default and true or false,
        _direction  = dir,
    }, Device)
end

local function read_friendly_name(devptr)
    local pp = ffi.new("IPropertyStore*[1]")
    local hr = devptr.lpVtbl.OpenPropertyStore(devptr, STGM_READ, pp)
    if hr ~= 0 then return "(unknown)" end
    local store = pp[0]
    local pv = ffi.new("PROPVARIANT")
    hr = store.lpVtbl.GetValue(store, PKEY_Device_FriendlyName, pv)
    local name = "(unknown)"
    if hr == 0 and pv.vt == 31 and pv.u.pwszVal ~= nil then
        -- LPCWSTR -> UTF-8.
        local buf = ffi.new("char[1024]")
        local n = C.WideCharToMultiByte(W.CP_UTF8, 0, pv.u.pwszVal, -1, buf, 1024, nil, nil)
        if n > 0 then name = ffi.string(buf, n - 1) end
        C.CoTaskMemFree(pv.u.pwszVal)
    end
    store.lpVtbl.Release(store)
    return name
end

function Device:name()
    if self._name then return self._name end
    self._name = read_friendly_name(self._ptr)
    return self._name
end

function Device:id()
    if self._id then return self._id end
    local sp = ffi.new("LPWSTR[1]")
    local hr = self._ptr.lpVtbl.GetId(self._ptr, sp)
    if hr ~= 0 then return nil end
    local buf = ffi.new("char[1024]")
    local n = C.WideCharToMultiByte(W.CP_UTF8, 0, sp[0], -1, buf, 1024, nil, nil)
    if n > 0 then self._id = ffi.string(buf, n - 1) end
    C.CoTaskMemFree(sp[0])
    return self._id
end

function Device:is_default() return self._is_default end
function Device:direction()  return self._direction end

-- Build a WAVEFORMATEXTENSIBLE matching the requested format.
local function make_wfx(format)
    format = format or {}
    local rate     = format.sample_rate or 48000
    local channels = format.channels    or 2
    local bits     = format.bits        or 16
    local is_float = format.float or false
    local wfx = ffi.new("WAVEFORMATEXTENSIBLE")
    wfx.Format.wFormatTag      = 0xFFFE  -- WAVE_FORMAT_EXTENSIBLE
    wfx.Format.nChannels       = channels
    wfx.Format.nSamplesPerSec  = rate
    wfx.Format.wBitsPerSample  = bits
    wfx.Format.nBlockAlign     = channels * (bits // 8)
    wfx.Format.nAvgBytesPerSec = rate * wfx.Format.nBlockAlign
    wfx.Format.cbSize          = 22
    wfx.Samples.wValidBitsPerSample = bits
    -- Stereo / mono mask (FL+FR or FC).
    if channels == 1 then wfx.dwChannelMask = 0x4 else wfx.dwChannelMask = 0x3 end
    wfx.SubFormat = is_float and KSDATAFORMAT_SUBTYPE_IEEE_FLOAT or KSDATAFORMAT_SUBTYPE_PCM
    return wfx
end

local function describe_wfx(wfx)
    -- Accept either a plain WAVEFORMATEX or a WAVEFORMATEXTENSIBLE.
    local fmt = ffi.cast("WAVEFORMATEX*", wfx)
    local is_float = false
    if fmt.wFormatTag == 0xFFFE then
        local ex = ffi.cast("WAVEFORMATEXTENSIBLE*", wfx)
        is_float = (ex.SubFormat.Data1 == 3)
    elseif fmt.wFormatTag == 3 then
        is_float = true
    end
    return {
        sample_rate = tonumber(fmt.nSamplesPerSec),
        channels    = tonumber(fmt.nChannels),
        bits        = tonumber(fmt.wBitsPerSample),
        float       = is_float,
        block_align = tonumber(fmt.nBlockAlign),
    }
end

-- ===== Client (the active streaming session) ===========================

local Client = {}
Client.__index = Client

function Device:open(opts)
    opts = opts or {}
    local mode = opts.mode or "shared"
    local share = (mode == "exclusive") and AUDCLNT_SHAREMODE_EXCLUSIVE or AUDCLNT_SHAREMODE_SHARED
    local flags = 0
    if opts.loopback then
        if self._direction ~= "render" then
            error("wasapi: loopback capture requires opening a render endpoint")
        end
        flags = flags | AUDCLNT_STREAMFLAGS_LOOPBACK
    end
    if opts.auto_convert and share == AUDCLNT_SHAREMODE_SHARED then
        flags = flags | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY
    end

    -- Activate IAudioClient.
    local pp = ffi.new("void*[1]")
    local hr = self._ptr.lpVtbl.Activate(self._ptr, IID_IAudioClient, CLSCTX_ALL, nil, pp)
    check_hr(hr, "IMMDevice::Activate(IAudioClient)")
    local ac = ffi.cast("IAudioClient*", pp[0])

    -- Negotiate format. For shared mode we usually go through GetMixFormat
    -- unless the caller passed an explicit format.
    local wfx_owner  -- keeps the allocated buffer alive across Initialize
    local wfx_ptr
    if opts.format then
        wfx_owner = make_wfx(opts.format)
        wfx_ptr   = ffi.cast("WAVEFORMATEX*", wfx_owner)
    else
        local pwfx = ffi.new("WAVEFORMATEX*[1]")
        hr = ac.lpVtbl.GetMixFormat(ac, pwfx)
        if hr ~= 0 then
            ac.lpVtbl.Release(ac)
            check_hr(hr, "GetMixFormat")
        end
        wfx_ptr   = pwfx[0]
        wfx_owner = pwfx
        ffi.gc(wfx_ptr, function(p) C.CoTaskMemFree(p) end)
    end

    local buffer_ms  = opts.buffer_ms or 20
    local buffer_ref = buffer_ms * REFTIMES_PER_MS
    hr = ac.lpVtbl.Initialize(ac, share, flags, buffer_ref, 0, wfx_ptr, nil)
    if hr ~= 0 then
        ac.lpVtbl.Release(ac)
        check_hr(hr, "IAudioClient::Initialize")
    end

    -- Pull the service interface matching the direction (render / capture).
    -- Loopback capture talks IAudioCaptureClient on a render endpoint too.
    local svc_iid = (self._direction == "capture" or opts.loopback)
                    and IID_IAudioCaptureClient
                    or IID_IAudioRenderClient
    local svc_pp = ffi.new("void*[1]")
    hr = ac.lpVtbl.GetService(ac, svc_iid, svc_pp)
    if hr ~= 0 then
        ac.lpVtbl.Release(ac)
        check_hr(hr, "IAudioClient::GetService")
    end

    local buf_size = ffi.new("UINT[1]")
    hr = ac.lpVtbl.GetBufferSize(ac, buf_size)
    if hr ~= 0 then
        ac.lpVtbl.Release(ac)
        check_hr(hr, "IAudioClient::GetBufferSize")
    end

    -- Volume control endpoint (optional).
    local vol_pp = ffi.new("void*[1]")
    local vol
    local vhr = ac.lpVtbl.GetService(ac, IID_ISimpleAudioVolume, vol_pp)
    if vhr == 0 then vol = ffi.cast("ISimpleAudioVolume*", vol_pp[0]) end

    local svc
    if self._direction == "capture" or opts.loopback then
        svc = ffi.cast("IAudioCaptureClient*", svc_pp[0])
    else
        svc = ffi.cast("IAudioRenderClient*", svc_pp[0])
    end

    return setmetatable({
        _ac    = ffi.gc(ac, function(p) p.lpVtbl.Release(p) end),
        _svc   = ffi.gc(svc, function(p) p.lpVtbl.Release(p) end),
        _vol   = vol and ffi.gc(vol, function(p) p.lpVtbl.Release(p) end) or nil,
        _wfx   = wfx_owner,
        _wfx_p = wfx_ptr,
        _buf_size = tonumber(buf_size[0]),
        _is_capture = (self._direction == "capture" or opts.loopback) and true or false,
        _format = describe_wfx(wfx_ptr),
    }, Client)
end

function Client:start()
    local hr = self._ac.lpVtbl.Start(self._ac)
    check_hr(hr, "IAudioClient::Start")
end

function Client:stop()
    local hr = self._ac.lpVtbl.Stop(self._ac)
    check_hr(hr, "IAudioClient::Stop")
end

function Client:close()
    -- Releases happen via the __gc closures already attached.
    self._svc = nil
    self._ac  = nil
    self._vol = nil
end

function Client:get_format()    return self._format end
function Client:get_buffer_size() return self._buf_size end

function Client:get_padding()
    local p = ffi.new("UINT[1]")
    local hr = self._ac.lpVtbl.GetCurrentPadding(self._ac, p)
    check_hr(hr, "GetCurrentPadding")
    return tonumber(p[0])
end

function Client:write(bytes)
    if self._is_capture then error("wasapi: write() on a capture stream") end
    local frame_bytes = self._format.block_align
    local frames = math.floor(#bytes / frame_bytes)
    if frames == 0 then return 0 end
    local available = self._buf_size - self:get_padding()
    if frames > available then frames = available end
    if frames == 0 then return 0 end
    local pbuf = ffi.new("BYTE*[1]")
    local hr = self._svc.lpVtbl.GetBuffer(self._svc, frames, pbuf)
    check_hr(hr, "IAudioRenderClient::GetBuffer")
    ffi.copy(pbuf[0], bytes, frames * frame_bytes)
    hr = self._svc.lpVtbl.ReleaseBuffer(self._svc, frames, 0)
    check_hr(hr, "IAudioRenderClient::ReleaseBuffer")
    return frames
end

function Client:read(max_frames)
    if not self._is_capture then error("wasapi: read() on a render stream") end
    local next_size = ffi.new("UINT[1]")
    local hr = self._svc.lpVtbl.GetNextPacketSize(self._svc, next_size)
    check_hr(hr, "GetNextPacketSize")
    if next_size[0] == 0 then return "", 0, 0 end
    local pbuf  = ffi.new("BYTE*[1]")
    local nfrm  = ffi.new("UINT[1]")
    local flags = ffi.new("DWORD[1]")
    hr = self._svc.lpVtbl.GetBuffer(self._svc, pbuf, nfrm, flags, nil, nil)
    check_hr(hr, "IAudioCaptureClient::GetBuffer")
    local frame_bytes = self._format.block_align
    local got_frames = tonumber(nfrm[0])
    if max_frames and got_frames > max_frames then got_frames = max_frames end
    local bytes = ffi.string(pbuf[0], got_frames * frame_bytes)
    hr = self._svc.lpVtbl.ReleaseBuffer(self._svc, nfrm[0])
    check_hr(hr, "IAudioCaptureClient::ReleaseBuffer")
    return bytes, got_frames, tonumber(flags[0])
end

function Client:set_volume(level)
    if not self._vol then error("wasapi: this client has no volume control") end
    local hr = self._vol.lpVtbl.SetMasterVolume(self._vol, level, nil)
    check_hr(hr, "SetMasterVolume")
end

function Client:get_volume()
    if not self._vol then return 1.0 end
    local v = ffi.new("float[1]")
    local hr = self._vol.lpVtbl.GetMasterVolume(self._vol, v)
    check_hr(hr, "GetMasterVolume")
    return tonumber(v[0])
end

function Client:mute(yes)
    if not self._vol then return end
    self._vol.lpVtbl.SetMute(self._vol, yes and 1 or 0, nil)
end

-- ===== Public enumeration ==============================================

local function dir_to_role(dir)
    if dir == "render"  then return eRender end
    if dir == "capture" then return eCapture end
    error("wasapi: direction must be 'render' or 'capture'")
end

function M.enumerate(dir)
    local role = dir_to_role(dir)
    local e = enum()
    local pp = ffi.new("IMMDeviceCollection*[1]")
    local hr = e.lpVtbl.EnumAudioEndpoints(e, role, DEVICE_STATE_ACTIVE, pp)
    check_hr(hr, "EnumAudioEndpoints")
    local coll = pp[0]
    local count = ffi.new("UINT[1]")
    hr = coll.lpVtbl.GetCount(coll, count)
    check_hr(hr, "DeviceCollection::GetCount")

    -- Find default endpoint ID so we can tag matches.
    local default = nil
    local default_id
    local def_pp = ffi.new("IMMDevice*[1]")
    if e.lpVtbl.GetDefaultAudioEndpoint(e, role, eConsole, def_pp) == 0 then
        local sp = ffi.new("LPWSTR[1]")
        if def_pp[0].lpVtbl.GetId(def_pp[0], sp) == 0 then
            local cbuf = ffi.new("char[1024]")
            local n = C.WideCharToMultiByte(W.CP_UTF8, 0, sp[0], -1, cbuf, 1024, nil, nil)
            if n > 0 then default_id = ffi.string(cbuf, n - 1) end
            C.CoTaskMemFree(sp[0])
        end
        def_pp[0].lpVtbl.Release(def_pp[0])
    end

    local out = {}
    for i = 0, tonumber(count[0]) - 1 do
        local dp = ffi.new("IMMDevice*[1]")
        hr = coll.lpVtbl.Item(coll, i, dp)
        check_hr(hr, "DeviceCollection::Item")
        local dev = wrap_device(dp[0], false, dir)
        if default_id and dev:id() == default_id then dev._is_default = true end
        out[#out + 1] = dev
    end
    coll.lpVtbl.Release(coll)
    return out
end

function M.default(dir)
    local role = dir_to_role(dir)
    local e = enum()
    local dp = ffi.new("IMMDevice*[1]")
    local hr = e.lpVtbl.GetDefaultAudioEndpoint(e, role, eConsole, dp)
    check_hr(hr, "GetDefaultAudioEndpoint")
    return wrap_device(dp[0], true, dir)
end

-- Convenience: open the default render device, write a buffer, close.
function M.play_pcm(samples, format, opts)
    opts = opts or {}
    local dev    = M.default("render")
    local client = dev:open({
        mode      = opts.mode or "shared",
        format    = format,
        buffer_ms = opts.buffer_ms or 100,
        auto_convert = true,
    })
    client:start()
    local pos = 1
    local frame_bytes = client:get_format().block_align
    while pos <= #samples do
        local chunk = samples:sub(pos, pos + 4096 * frame_bytes - 1)
        local written = client:write(chunk)
        if written == 0 then
            ffi.C.Sleep(5)
        else
            pos = pos + written * frame_bytes
        end
    end
    -- Wait for the trailing buffer to drain before stopping.
    while client:get_padding() > 0 do ffi.C.Sleep(5) end
    client:stop()
    client:close()
end

return M
