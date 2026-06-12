-- mediafound -- Microsoft Media Foundation wrapper.
--
-- Surface:
--   mediafound.startup()                     -> nothing       (idempotent)
--   mediafound.shutdown()                    -> nothing
--   mediafound.reader_from_url(path, opts?)  -> SourceReader
--   reader:streams()                         -> { stream_info, ... }
--   reader:set_native_format(stream, gtype, subtype)  (e.g. AUDIO_PCM, AUDIO_FLOAT)
--   reader:current_media_type(stream)        -> { major, sub, ...numeric attrs... }
--   reader:read(stream)                      -> bytes, flags, ts, dur   (nil at EOS)
--   reader:close()
--
-- Stream constants:
--   mediafound.STREAM_FIRST_AUDIO
--   mediafound.STREAM_FIRST_VIDEO
--   mediafound.STREAM_ALL
--
-- COM rules:
--   * mediafound.startup() will CoInitializeEx(MULTITHREADED) for you
--     if no apartment is active. Once started, MFShutdown is matched
--     against startup() in 1:1 fashion via reference count.
--
-- This file is consumed by the `audio` package and also exposed to user
-- code that wants raw MF demux/decode of audio+video.

local ffi = ffi
local W   = require "windows"
require "windows.com"

local C = ffi.C
local M = {}

-- ===== cdef ============================================================

ffi.cdef[[
typedef struct IMFSourceReader IMFSourceReader;
typedef struct IMFMediaType    IMFMediaType;
typedef struct IMFSample       IMFSample;
typedef struct IMFMediaBuffer  IMFMediaBuffer;
typedef struct IMFAttributes   IMFAttributes;

typedef struct IMFAttributesVtbl {
    HRESULT (__stdcall *QueryInterface)(IMFAttributes*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IMFAttributes*);
    ULONG   (__stdcall *Release)(IMFAttributes*);
    HRESULT (__stdcall *GetItem)(IMFAttributes*, GUID_W*, void*);
    HRESULT (__stdcall *GetItemType)(IMFAttributes*, GUID_W*, DWORD*);
    HRESULT (__stdcall *CompareItem)(IMFAttributes*, GUID_W*, void*, BOOL*);
    HRESULT (__stdcall *Compare)(IMFAttributes*, IMFAttributes*, DWORD, BOOL*);
    HRESULT (__stdcall *GetUINT32)(IMFAttributes*, GUID_W*, UINT*);
    HRESULT (__stdcall *GetUINT64)(IMFAttributes*, GUID_W*, ULONGLONG*);
    HRESULT (__stdcall *GetDouble)(IMFAttributes*, GUID_W*, double*);
    HRESULT (__stdcall *GetGUID)(IMFAttributes*, GUID_W*, GUID_W*);
    HRESULT (__stdcall *GetStringLength)(IMFAttributes*, GUID_W*, UINT*);
    HRESULT (__stdcall *GetString)(IMFAttributes*, GUID_W*, LPWSTR, UINT, UINT*);
    HRESULT (__stdcall *GetAllocatedString)(IMFAttributes*, GUID_W*, LPWSTR*, UINT*);
    HRESULT (__stdcall *GetBlobSize)(IMFAttributes*, GUID_W*, UINT*);
    HRESULT (__stdcall *GetBlob)(IMFAttributes*, GUID_W*, BYTE*, UINT, UINT*);
    HRESULT (__stdcall *GetAllocatedBlob)(IMFAttributes*, GUID_W*, BYTE**, UINT*);
    HRESULT (__stdcall *GetUnknown)(IMFAttributes*, GUID_W*, GUID_W*, void**);
    HRESULT (__stdcall *SetItem)(IMFAttributes*, GUID_W*, void*);
    HRESULT (__stdcall *DeleteItem)(IMFAttributes*, GUID_W*);
    HRESULT (__stdcall *DeleteAllItems)(IMFAttributes*);
    HRESULT (__stdcall *SetUINT32)(IMFAttributes*, GUID_W*, UINT);
    HRESULT (__stdcall *SetUINT64)(IMFAttributes*, GUID_W*, ULONGLONG);
    HRESULT (__stdcall *SetDouble)(IMFAttributes*, GUID_W*, double);
    HRESULT (__stdcall *SetGUID)(IMFAttributes*, GUID_W*, GUID_W*);
    HRESULT (__stdcall *SetString)(IMFAttributes*, GUID_W*, LPCWSTR);
    HRESULT (__stdcall *SetBlob)(IMFAttributes*, GUID_W*, BYTE*, UINT);
    HRESULT (__stdcall *SetUnknown)(IMFAttributes*, GUID_W*, void*);
    HRESULT (__stdcall *LockStore)(IMFAttributes*);
    HRESULT (__stdcall *UnlockStore)(IMFAttributes*);
    HRESULT (__stdcall *GetCount)(IMFAttributes*, UINT*);
    HRESULT (__stdcall *GetItemByIndex)(IMFAttributes*, UINT, GUID_W*, void*);
    HRESULT (__stdcall *CopyAllItems)(IMFAttributes*, IMFAttributes*);
} IMFAttributesVtbl;
struct IMFAttributes { IMFAttributesVtbl *lpVtbl; };

typedef struct IMFMediaTypeVtbl {
    HRESULT (__stdcall *QueryInterface)(IMFMediaType*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IMFMediaType*);
    ULONG   (__stdcall *Release)(IMFMediaType*);
    /* trailing IMFAttributes methods omitted; we only need QI/AddRef/Release */
} IMFMediaTypeVtbl;
struct IMFMediaType { IMFMediaTypeVtbl *lpVtbl; };

typedef struct IMFMediaBufferVtbl {
    HRESULT (__stdcall *QueryInterface)(IMFMediaBuffer*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IMFMediaBuffer*);
    ULONG   (__stdcall *Release)(IMFMediaBuffer*);
    HRESULT (__stdcall *Lock)(IMFMediaBuffer*, BYTE**, DWORD*, DWORD*);
    HRESULT (__stdcall *Unlock)(IMFMediaBuffer*);
    HRESULT (__stdcall *GetCurrentLength)(IMFMediaBuffer*, DWORD*);
    HRESULT (__stdcall *SetCurrentLength)(IMFMediaBuffer*, DWORD);
    HRESULT (__stdcall *GetMaxLength)(IMFMediaBuffer*, DWORD*);
} IMFMediaBufferVtbl;
struct IMFMediaBuffer { IMFMediaBufferVtbl *lpVtbl; };

typedef struct IMFSampleVtbl {
    HRESULT (__stdcall *QueryInterface)(IMFSample*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IMFSample*);
    ULONG   (__stdcall *Release)(IMFSample*);
    /* skip attribute methods (vtable slots 3..32) */
    HRESULT (__stdcall *_pad03)(void);
    HRESULT (__stdcall *_pad04)(void);
    HRESULT (__stdcall *_pad05)(void);
    HRESULT (__stdcall *_pad06)(void);
    HRESULT (__stdcall *_pad07)(void);
    HRESULT (__stdcall *_pad08)(void);
    HRESULT (__stdcall *_pad09)(void);
    HRESULT (__stdcall *_pad10)(void);
    HRESULT (__stdcall *_pad11)(void);
    HRESULT (__stdcall *_pad12)(void);
    HRESULT (__stdcall *_pad13)(void);
    HRESULT (__stdcall *_pad14)(void);
    HRESULT (__stdcall *_pad15)(void);
    HRESULT (__stdcall *_pad16)(void);
    HRESULT (__stdcall *_pad17)(void);
    HRESULT (__stdcall *_pad18)(void);
    HRESULT (__stdcall *_pad19)(void);
    HRESULT (__stdcall *_pad20)(void);
    HRESULT (__stdcall *_pad21)(void);
    HRESULT (__stdcall *_pad22)(void);
    HRESULT (__stdcall *_pad23)(void);
    HRESULT (__stdcall *_pad24)(void);
    HRESULT (__stdcall *_pad25)(void);
    HRESULT (__stdcall *_pad26)(void);
    HRESULT (__stdcall *_pad27)(void);
    HRESULT (__stdcall *_pad28)(void);
    HRESULT (__stdcall *_pad29)(void);
    HRESULT (__stdcall *_pad30)(void);
    HRESULT (__stdcall *_pad31)(void);
    HRESULT (__stdcall *_pad32)(void);
    /* IMFSample methods proper */
    HRESULT (__stdcall *GetSampleFlags)(IMFSample*, DWORD*);
    HRESULT (__stdcall *SetSampleFlags)(IMFSample*, DWORD);
    HRESULT (__stdcall *GetSampleTime)(IMFSample*, LONGLONG*);
    HRESULT (__stdcall *SetSampleTime)(IMFSample*, LONGLONG);
    HRESULT (__stdcall *GetSampleDuration)(IMFSample*, LONGLONG*);
    HRESULT (__stdcall *SetSampleDuration)(IMFSample*, LONGLONG);
    HRESULT (__stdcall *GetBufferCount)(IMFSample*, DWORD*);
    HRESULT (__stdcall *GetBufferByIndex)(IMFSample*, DWORD, IMFMediaBuffer**);
    HRESULT (__stdcall *ConvertToContiguousBuffer)(IMFSample*, IMFMediaBuffer**);
    HRESULT (__stdcall *AddBuffer)(IMFSample*, IMFMediaBuffer*);
    HRESULT (__stdcall *RemoveBufferByIndex)(IMFSample*, DWORD);
    HRESULT (__stdcall *RemoveAllBuffers)(IMFSample*);
    HRESULT (__stdcall *GetTotalLength)(IMFSample*, DWORD*);
    HRESULT (__stdcall *CopyToBuffer)(IMFSample*, IMFMediaBuffer*);
} IMFSampleVtbl;
struct IMFSample { IMFSampleVtbl *lpVtbl; };

typedef struct IMFSourceReaderVtbl {
    HRESULT (__stdcall *QueryInterface)(IMFSourceReader*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IMFSourceReader*);
    ULONG   (__stdcall *Release)(IMFSourceReader*);
    HRESULT (__stdcall *GetStreamSelection)(IMFSourceReader*, DWORD, BOOL*);
    HRESULT (__stdcall *SetStreamSelection)(IMFSourceReader*, DWORD, BOOL);
    HRESULT (__stdcall *GetNativeMediaType)(IMFSourceReader*, DWORD, DWORD, IMFMediaType**);
    HRESULT (__stdcall *GetCurrentMediaType)(IMFSourceReader*, DWORD, IMFMediaType**);
    HRESULT (__stdcall *SetCurrentMediaType)(IMFSourceReader*, DWORD, DWORD*, IMFMediaType*);
    HRESULT (__stdcall *SetCurrentPosition)(IMFSourceReader*, GUID_W*, void*);
    HRESULT (__stdcall *ReadSample)(IMFSourceReader*, DWORD, DWORD, DWORD*, DWORD*, LONGLONG*, IMFSample**);
    HRESULT (__stdcall *Flush)(IMFSourceReader*, DWORD);
    HRESULT (__stdcall *GetServiceForStream)(IMFSourceReader*, DWORD, GUID_W*, GUID_W*, void**);
    HRESULT (__stdcall *GetPresentationAttribute)(IMFSourceReader*, DWORD, GUID_W*, void*);
} IMFSourceReaderVtbl;
struct IMFSourceReader { IMFSourceReaderVtbl *lpVtbl; };

/* mfplat.dll */
HRESULT MFStartup(ULONG version, DWORD flags);
HRESULT MFShutdown(void);
HRESULT MFCreateAttributes(IMFAttributes **ppAttributes, UINT cInitialSize);
HRESULT MFCreateMediaType(IMFMediaType **ppMFType);

/* mfreadwrite.dll */
HRESULT MFCreateSourceReaderFromURL(LPCWSTR pwszURL, IMFAttributes *pAttributes, IMFSourceReader **ppReader);
]]

pcall(ffi.load, "mfplat")
pcall(ffi.load, "mfreadwrite")
pcall(ffi.load, "mf")
pcall(ffi.load, "mfuuid")

-- ===== GUID helpers ====================================================

local function make_guid(d1, d2, d3, d4)
    local g = ffi.new("GUID_W")
    g.Data1 = d1; g.Data2 = d2; g.Data3 = d3
    for i = 0, 7 do g.Data4[i] = d4[i + 1] end
    return g
end

-- Major-type GUIDs.
M.MFMediaType_Audio = make_guid(0x73647561, 0x0000, 0x0010, {0x80,0x00,0x00,0xAA,0x00,0x38,0x9B,0x71})
M.MFMediaType_Video = make_guid(0x73646976, 0x0000, 0x0010, {0x80,0x00,0x00,0xAA,0x00,0x38,0x9B,0x71})

-- Audio subtype GUIDs.
M.MFAudioFormat_PCM    = make_guid(0x00000001, 0x0000, 0x0010, {0x80,0x00,0x00,0xAA,0x00,0x38,0x9B,0x71})
M.MFAudioFormat_Float  = make_guid(0x00000003, 0x0000, 0x0010, {0x80,0x00,0x00,0xAA,0x00,0x38,0x9B,0x71})
M.MFAudioFormat_AAC    = make_guid(0x00001610, 0x0000, 0x0010, {0x80,0x00,0x00,0xAA,0x00,0x38,0x9B,0x71})
M.MFAudioFormat_MP3    = make_guid(0x00000055, 0x0000, 0x0010, {0x80,0x00,0x00,0xAA,0x00,0x38,0x9B,0x71})
M.MFAudioFormat_FLAC   = make_guid(0x0000F1AC, 0x0000, 0x0010, {0x80,0x00,0x00,0xAA,0x00,0x38,0x9B,0x71})

-- Video subtype GUIDs (subset).
M.MFVideoFormat_RGB32  = make_guid(0x00000016, 0x0000, 0x0010, {0x80,0x00,0x00,0xAA,0x00,0x38,0x9B,0x71})
M.MFVideoFormat_NV12   = make_guid(0x3231564E, 0x0000, 0x0010, {0x80,0x00,0x00,0xAA,0x00,0x38,0x9B,0x71})
M.MFVideoFormat_H264   = make_guid(0x34363248, 0x0000, 0x0010, {0x80,0x00,0x00,0xAA,0x00,0x38,0x9B,0x71})

-- Attribute GUIDs we read.
M.MF_MT_MAJOR_TYPE              = make_guid(0x48eba18e, 0xf8c9, 0x4687, {0xbf,0x11,0x0a,0x74,0xc9,0xf9,0x6a,0x8f})
M.MF_MT_SUBTYPE                 = make_guid(0xf7e34c9a, 0x42e8, 0x4714, {0xb7,0x4b,0xcb,0x29,0xd7,0x2c,0x35,0xe5})
M.MF_MT_AUDIO_SAMPLES_PER_SECOND = make_guid(0x5faeeae7, 0x0290, 0x4c31, {0x9e,0x8a,0xc5,0x34,0xf6,0x8d,0x9d,0xba})
M.MF_MT_AUDIO_NUM_CHANNELS       = make_guid(0x37e48bf5, 0x645e, 0x4c5b, {0x89,0xde,0xad,0xa9,0xe2,0x9b,0x69,0x6a})
M.MF_MT_AUDIO_BITS_PER_SAMPLE    = make_guid(0xf2deb57f, 0x40fa, 0x4764, {0xaa,0x33,0xed,0x4f,0x2d,0x1f,0xf6,0x69})
M.MF_MT_AUDIO_BLOCK_ALIGNMENT    = make_guid(0x322de230, 0x9eeb, 0x43bd, {0xab,0x7a,0xff,0x41,0x22,0x51,0x54,0x1d})
M.MF_MT_FRAME_SIZE               = make_guid(0x1652c33d, 0xd6b2, 0x4012, {0xb8,0x34,0x72,0x03,0x08,0x49,0xa3,0x7d})
M.MF_MT_FRAME_RATE               = make_guid(0xc459a2e8, 0x3d2c, 0x4e44, {0xb1,0x32,0xfe,0xe5,0x15,0x6c,0x7b,0xb0})

-- Stream selection sentinels.
M.STREAM_FIRST_AUDIO = 0xFFFFFFFD  -- MF_SOURCE_READER_FIRST_AUDIO_STREAM
M.STREAM_FIRST_VIDEO = 0xFFFFFFFC  -- MF_SOURCE_READER_FIRST_VIDEO_STREAM
M.STREAM_ALL         = 0xFFFFFFFE  -- MF_SOURCE_READER_ALL_STREAMS

-- ReadSample flag bits we surface.
M.READSAMPLE_ENDOFSTREAM         = 0x02
M.READSAMPLE_NEWSTREAM           = 0x04
M.READSAMPLE_NATIVEMEDIATYPECHANGED = 0x10
M.READSAMPLE_CURRENTMEDIATYPECHANGED = 0x20
M.READSAMPLE_STREAMTICK          = 0x100

-- Startup version constant.
local MF_VERSION = 0x00020070

-- ===== Lifecycle =======================================================

local _startup_count = 0
local _coinit_did    = false

local function ensure_coinit()
    if _coinit_did then return end
    -- COINIT_MULTITHREADED = 0
    local hr = C.CoInitializeEx(nil, 0)
    -- RPC_E_CHANGED_MODE = 0x80010106 just means another mode is already
    -- live on this thread; either way our existing apartment is fine.
    if hr ~= 0 and tonumber(ffi.cast("DWORD", hr)) ~= 0x80010106 and hr ~= 1 then
        -- S_FALSE (1) just means "already initialised".
        error(string.format("mediafound: CoInitializeEx failed (0x%08x)",
              tonumber(ffi.cast("DWORD", hr))))
    end
    _coinit_did = true
end

function M.startup()
    if _startup_count == 0 then
        ensure_coinit()
        local hr = C.MFStartup(MF_VERSION, 0)
        if hr ~= 0 then
            error(string.format("mediafound: MFStartup failed (0x%08x)",
                  tonumber(ffi.cast("DWORD", hr))))
        end
    end
    _startup_count = _startup_count + 1
end

function M.shutdown()
    if _startup_count == 0 then return end
    _startup_count = _startup_count - 1
    if _startup_count == 0 then
        C.MFShutdown()
    end
end

-- ===== HRESULT helper ==================================================

local function check_hr(hr, where)
    if hr ~= 0 then
        local u = tonumber(ffi.cast("DWORD", hr))
        error(string.format("mediafound: %s failed (HRESULT 0x%08x)", where, u), 2)
    end
end

-- ===== Wide-string helper ==============================================

local function to_wide(path)
    local n = #path
    local buf = ffi.new("unsigned short[?]", n + 1)
    -- Reuse MultiByteToWideChar so we handle UTF-8 paths correctly.
    local got = C.MultiByteToWideChar(W.CP_UTF8, 0, path, n, buf, n)
    if got <= 0 then
        -- Fallback: ASCII byte copy.
        for i = 1, n do buf[i - 1] = path:byte(i) end
        buf[n] = 0
    else
        buf[got] = 0
    end
    return buf
end

-- ===== Attribute readers ===============================================

local function get_uint32(attrs, key)
    local v = ffi.new("UINT[1]")
    local hr = attrs.lpVtbl.GetUINT32(ffi.cast("IMFAttributes*", attrs), key, v)
    if hr ~= 0 then return nil end
    return tonumber(v[0])
end

local function get_uint64(attrs, key)
    local v = ffi.new("ULONGLONG[1]")
    local hr = attrs.lpVtbl.GetUINT64(ffi.cast("IMFAttributes*", attrs), key, v)
    if hr ~= 0 then return nil end
    return tonumber(v[0])
end

local function get_guid(attrs, key)
    local g = ffi.new("GUID_W")
    local hr = attrs.lpVtbl.GetGUID(ffi.cast("IMFAttributes*", attrs), key, g)
    if hr ~= 0 then return nil end
    return g
end

local function guid_eq(a, b)
    if not a or not b then return false end
    if a.Data1 ~= b.Data1 or a.Data2 ~= b.Data2 or a.Data3 ~= b.Data3 then return false end
    for i = 0, 7 do if a.Data4[i] ~= b.Data4[i] then return false end end
    return true
end

M.get_uint32 = get_uint32
M.get_uint64 = get_uint64
M.get_guid   = get_guid
M.guid_eq    = guid_eq

local function major_label(g)
    if guid_eq(g, M.MFMediaType_Audio) then return "audio" end
    if guid_eq(g, M.MFMediaType_Video) then return "video" end
    return "other"
end

local function sub_label(g)
    if guid_eq(g, M.MFAudioFormat_PCM)   then return "pcm" end
    if guid_eq(g, M.MFAudioFormat_Float) then return "float" end
    if guid_eq(g, M.MFAudioFormat_AAC)   then return "aac" end
    if guid_eq(g, M.MFAudioFormat_MP3)   then return "mp3" end
    if guid_eq(g, M.MFAudioFormat_FLAC)  then return "flac" end
    if guid_eq(g, M.MFVideoFormat_H264)  then return "h264" end
    if guid_eq(g, M.MFVideoFormat_NV12)  then return "nv12" end
    if guid_eq(g, M.MFVideoFormat_RGB32) then return "rgb32" end
    return "unknown"
end

-- ===== Source Reader object ============================================

local Reader = {}
Reader.__index = Reader

function Reader:streams()
    local out = {}
    local idx = 0
    while true do
        local pp = ffi.new("IMFMediaType*[1]")
        local hr = self._ptr.lpVtbl.GetNativeMediaType(self._ptr, idx, 0, pp)
        if hr ~= 0 then break end
        local mt = pp[0]
        local mt_attrs = ffi.cast("IMFAttributes*", mt)
        local info = {
            index    = idx,
            major    = major_label(get_guid(mt_attrs, M.MF_MT_MAJOR_TYPE)),
            sub      = sub_label(get_guid(mt_attrs, M.MF_MT_SUBTYPE)),
        }
        if info.major == "audio" then
            info.sample_rate = get_uint32(mt_attrs, M.MF_MT_AUDIO_SAMPLES_PER_SECOND)
            info.channels    = get_uint32(mt_attrs, M.MF_MT_AUDIO_NUM_CHANNELS)
            info.bits        = get_uint32(mt_attrs, M.MF_MT_AUDIO_BITS_PER_SAMPLE)
        elseif info.major == "video" then
            local fs = get_uint64(mt_attrs, M.MF_MT_FRAME_SIZE)
            if fs then
                info.width  = math.floor(fs / 0x100000000)
                info.height = fs % 0x100000000
            end
        end
        mt.lpVtbl.Release(mt)
        out[#out + 1] = info
        idx = idx + 1
    end
    return out
end

function Reader:set_native_format(stream, major_type, subtype)
    -- Build a fresh IMFMediaType with major + subtype set, then push it
    -- via SetCurrentMediaType. This is how you ask MF to decode an MP3
    -- to PCM, AAC to float, NV12 to RGB32, etc.
    local pp = ffi.new("IMFMediaType*[1]")
    local hr = C.MFCreateMediaType(pp)
    check_hr(hr, "MFCreateMediaType")
    local mt = pp[0]
    local attrs = ffi.cast("IMFAttributes*", mt)
    attrs.lpVtbl.SetGUID(attrs, M.MF_MT_MAJOR_TYPE, major_type)
    attrs.lpVtbl.SetGUID(attrs, M.MF_MT_SUBTYPE,    subtype)
    hr = self._ptr.lpVtbl.SetCurrentMediaType(self._ptr, stream, nil, mt)
    mt.lpVtbl.Release(mt)
    check_hr(hr, "SetCurrentMediaType")
end

function Reader:current_media_type(stream)
    local pp = ffi.new("IMFMediaType*[1]")
    local hr = self._ptr.lpVtbl.GetCurrentMediaType(self._ptr, stream, pp)
    check_hr(hr, "GetCurrentMediaType")
    local mt = pp[0]
    local attrs = ffi.cast("IMFAttributes*", mt)
    local out = {
        major = major_label(get_guid(attrs, M.MF_MT_MAJOR_TYPE)),
        sub   = sub_label(get_guid(attrs, M.MF_MT_SUBTYPE)),
        sample_rate = get_uint32(attrs, M.MF_MT_AUDIO_SAMPLES_PER_SECOND),
        channels    = get_uint32(attrs, M.MF_MT_AUDIO_NUM_CHANNELS),
        bits        = get_uint32(attrs, M.MF_MT_AUDIO_BITS_PER_SAMPLE),
        block_align = get_uint32(attrs, M.MF_MT_AUDIO_BLOCK_ALIGNMENT),
    }
    mt.lpVtbl.Release(mt)
    return out
end

function Reader:read(stream)
    local flags   = ffi.new("DWORD[1]")
    local actual  = ffi.new("DWORD[1]")
    local ts      = ffi.new("LONGLONG[1]")
    local samplep = ffi.new("IMFSample*[1]")
    local hr = self._ptr.lpVtbl.ReadSample(self._ptr, stream, 0, actual, flags, ts, samplep)
    check_hr(hr, "ReadSample")
    local flagval = tonumber(flags[0])
    if (flagval & M.READSAMPLE_ENDOFSTREAM) ~= 0 then
        if samplep[0] ~= nil then samplep[0].lpVtbl.Release(samplep[0]) end
        return nil, flagval
    end
    if samplep[0] == nil then
        return "", flagval, tonumber(ts[0]), 0
    end
    local sample = samplep[0]
    local bufp = ffi.new("IMFMediaBuffer*[1]")
    hr = sample.lpVtbl.ConvertToContiguousBuffer(sample, bufp)
    if hr ~= 0 then
        sample.lpVtbl.Release(sample)
        check_hr(hr, "ConvertToContiguousBuffer")
    end
    local buf = bufp[0]
    local data = ffi.new("BYTE*[1]")
    local max_len = ffi.new("DWORD[1]")
    local cur_len = ffi.new("DWORD[1]")
    hr = buf.lpVtbl.Lock(buf, data, max_len, cur_len)
    if hr ~= 0 then
        buf.lpVtbl.Release(buf); sample.lpVtbl.Release(sample)
        check_hr(hr, "MediaBuffer::Lock")
    end
    local bytes = ffi.string(data[0], tonumber(cur_len[0]))
    buf.lpVtbl.Unlock(buf)
    local dur = ffi.new("LONGLONG[1]")
    sample.lpVtbl.GetSampleDuration(sample, dur)
    buf.lpVtbl.Release(buf)
    sample.lpVtbl.Release(sample)
    return bytes, flagval, tonumber(ts[0]), tonumber(dur[0])
end

function Reader:close()
    if self._ptr ~= nil then
        self._ptr.lpVtbl.Release(self._ptr)
        self._ptr = nil
    end
end

local Reader_mt = {
    __index = Reader,
    __gc    = function(self) Reader.close(self) end,
}

function M.reader_from_url(path, opts)
    opts = opts or {}
    M.startup()
    local wpath = to_wide(path)
    local pp = ffi.new("IMFSourceReader*[1]")
    -- A null IMFAttributes parameter means "default reader settings".
    local hr = C.MFCreateSourceReaderFromURL(wpath, nil, pp)
    check_hr(hr, "MFCreateSourceReaderFromURL")
    return setmetatable({ _ptr = pp[0], _path = path }, Reader_mt)
end

return M
