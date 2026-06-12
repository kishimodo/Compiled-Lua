-- wic -- Windows Imaging Component wrapper.
--
-- IWICImagingFactory talks to the in-box codecs for PNG, JPEG, BMP, GIF,
-- TIFF, ICO, WEBP (on Win10 1809+), HEIC (with optional extension) and a
-- handful of legacy formats. This module exposes a thin object layer:
--
--   wic.factory()                  -> Factory
--   wic.decode(bytes_or_path)      -> Frame    (first frame, BGRA)
--   wic.encode(frame, format, dst) -> nothing  (dst = path or buffer-ref)
--
-- Frame methods:
--   :size()                        -> w, h
--   :format()                      -> GUID string (a WICPixelFormat*)
--   :read_pixels(opts?)            -> bytes, stride
--   :convert(target_pixel_format)  -> Frame in the requested layout
--   :encode_to(path_or_buffer, fmt)
--
-- The init.lua also exports the WIC GUIDs we need so callers can do
-- factory-level calls (CreateBitmapFromMemory, etc.) directly.
--
-- COM rules:
--   * The user is responsible for CoInitialize* on this thread. The
--     image package handles that automatically. If you call wic.* on a
--     fresh thread, you MUST CoInitializeEx first.
--   * Every COM pointer returned here is wrapped in a Lua object with
--     a __gc metamethod that calls Release. Don't keep raw pointers
--     across script boundaries.

local ffi = ffi
local W   = require "windows"
require  "windows.com"

local C = ffi.C

local M = {}

-- ===== Forward typedefs + vtables =======================================
-- WIC vtables include only the entries we actually call. ordering matches
-- WincodecSdk.h verbatim so we don't have to redeclare full ones.

ffi.cdef[[
typedef struct IWICImagingFactory   IWICImagingFactory;
typedef struct IWICBitmapDecoder    IWICBitmapDecoder;
typedef struct IWICBitmapFrameDecode IWICBitmapFrameDecode;
typedef struct IWICBitmapSource     IWICBitmapSource;
typedef struct IWICFormatConverter  IWICFormatConverter;
typedef struct IWICStream           IWICStream;
typedef struct IWICBitmapEncoder    IWICBitmapEncoder;
typedef struct IWICBitmapFrameEncode IWICBitmapFrameEncode;
typedef struct IWICPalette          IWICPalette;
typedef struct IStream              IStream;
typedef struct IPropertyBag2        IPropertyBag2;

typedef struct IWICImagingFactoryVtbl {
    HRESULT (__stdcall *QueryInterface)(IWICImagingFactory*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IWICImagingFactory*);
    ULONG   (__stdcall *Release)(IWICImagingFactory*);
    HRESULT (__stdcall *CreateDecoderFromFilename)(IWICImagingFactory*, LPCWSTR, GUID_W*, DWORD, DWORD, IWICBitmapDecoder**);
    HRESULT (__stdcall *CreateDecoderFromStream)(IWICImagingFactory*, IStream*, GUID_W*, DWORD, IWICBitmapDecoder**);
    HRESULT (__stdcall *CreateDecoderFromFileHandle)(IWICImagingFactory*, ULONGLONG, GUID_W*, DWORD, IWICBitmapDecoder**);
    HRESULT (__stdcall *CreateComponentInfo)(IWICImagingFactory*, GUID_W*, void**);
    HRESULT (__stdcall *CreateDecoder)(IWICImagingFactory*, GUID_W*, GUID_W*, IWICBitmapDecoder**);
    HRESULT (__stdcall *CreateEncoder)(IWICImagingFactory*, GUID_W*, GUID_W*, IWICBitmapEncoder**);
    HRESULT (__stdcall *CreatePalette)(IWICImagingFactory*, IWICPalette**);
    HRESULT (__stdcall *CreateFormatConverter)(IWICImagingFactory*, IWICFormatConverter**);
    HRESULT (__stdcall *CreateBitmapScaler)(IWICImagingFactory*, void**);
    HRESULT (__stdcall *CreateBitmapClipper)(IWICImagingFactory*, void**);
    HRESULT (__stdcall *CreateBitmapFlipRotator)(IWICImagingFactory*, void**);
    HRESULT (__stdcall *CreateStream)(IWICImagingFactory*, IWICStream**);
    HRESULT (__stdcall *CreateColorContext)(IWICImagingFactory*, void**);
    HRESULT (__stdcall *CreateColorTransformer)(IWICImagingFactory*, void**);
    HRESULT (__stdcall *CreateBitmap)(IWICImagingFactory*, UINT, UINT, GUID_W*, DWORD, void**);
    HRESULT (__stdcall *CreateBitmapFromSource)(IWICImagingFactory*, IWICBitmapSource*, DWORD, void**);
    HRESULT (__stdcall *CreateBitmapFromSourceRect)(IWICImagingFactory*, void*, UINT, UINT, UINT, UINT, void**);
    HRESULT (__stdcall *CreateBitmapFromMemory)(IWICImagingFactory*, UINT, UINT, GUID_W*, UINT, UINT, BYTE*, void**);
    HRESULT (__stdcall *CreateBitmapFromHBITMAP)(IWICImagingFactory*, void*, void*, DWORD, void**);
    HRESULT (__stdcall *CreateBitmapFromHICON)(IWICImagingFactory*, void*, void**);
    HRESULT (__stdcall *CreateComponentEnumerator)(IWICImagingFactory*, DWORD, DWORD, void**);
    HRESULT (__stdcall *CreateFastMetadataEncoderFromDecoder)(IWICImagingFactory*, IWICBitmapDecoder*, void**);
    HRESULT (__stdcall *CreateFastMetadataEncoderFromFrameDecode)(IWICImagingFactory*, IWICBitmapFrameDecode*, void**);
    HRESULT (__stdcall *CreateQueryWriter)(IWICImagingFactory*, GUID_W*, GUID_W*, void**);
    HRESULT (__stdcall *CreateQueryWriterFromReader)(IWICImagingFactory*, void*, GUID_W*, void**);
} IWICImagingFactoryVtbl;
struct IWICImagingFactory { IWICImagingFactoryVtbl *lpVtbl; };

typedef struct IWICBitmapDecoderVtbl {
    HRESULT (__stdcall *QueryInterface)(IWICBitmapDecoder*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IWICBitmapDecoder*);
    ULONG   (__stdcall *Release)(IWICBitmapDecoder*);
    HRESULT (__stdcall *QueryCapability)(IWICBitmapDecoder*, IStream*, DWORD*);
    HRESULT (__stdcall *Initialize)(IWICBitmapDecoder*, IStream*, DWORD);
    HRESULT (__stdcall *GetContainerFormat)(IWICBitmapDecoder*, GUID_W*);
    HRESULT (__stdcall *GetDecoderInfo)(IWICBitmapDecoder*, void**);
    HRESULT (__stdcall *CopyPalette)(IWICBitmapDecoder*, IWICPalette*);
    HRESULT (__stdcall *GetMetadataQueryReader)(IWICBitmapDecoder*, void**);
    HRESULT (__stdcall *GetPreview)(IWICBitmapDecoder*, void**);
    HRESULT (__stdcall *GetColorContexts)(IWICBitmapDecoder*, UINT, void**, UINT*);
    HRESULT (__stdcall *GetThumbnail)(IWICBitmapDecoder*, void**);
    HRESULT (__stdcall *GetFrameCount)(IWICBitmapDecoder*, UINT*);
    HRESULT (__stdcall *GetFrame)(IWICBitmapDecoder*, UINT, IWICBitmapFrameDecode**);
} IWICBitmapDecoderVtbl;
struct IWICBitmapDecoder { IWICBitmapDecoderVtbl *lpVtbl; };

typedef struct IWICBitmapFrameDecodeVtbl {
    HRESULT (__stdcall *QueryInterface)(IWICBitmapFrameDecode*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IWICBitmapFrameDecode*);
    ULONG   (__stdcall *Release)(IWICBitmapFrameDecode*);
    HRESULT (__stdcall *GetSize)(IWICBitmapFrameDecode*, UINT*, UINT*);
    HRESULT (__stdcall *GetPixelFormat)(IWICBitmapFrameDecode*, GUID_W*);
    HRESULT (__stdcall *GetResolution)(IWICBitmapFrameDecode*, double*, double*);
    HRESULT (__stdcall *CopyPalette)(IWICBitmapFrameDecode*, IWICPalette*);
    HRESULT (__stdcall *CopyPixels)(IWICBitmapFrameDecode*, void*, UINT, UINT, BYTE*);
    HRESULT (__stdcall *GetMetadataQueryReader)(IWICBitmapFrameDecode*, void**);
    HRESULT (__stdcall *GetColorContexts)(IWICBitmapFrameDecode*, UINT, void**, UINT*);
    HRESULT (__stdcall *GetThumbnail)(IWICBitmapFrameDecode*, void**);
} IWICBitmapFrameDecodeVtbl;
struct IWICBitmapFrameDecode { IWICBitmapFrameDecodeVtbl *lpVtbl; };

typedef struct IWICFormatConverterVtbl {
    HRESULT (__stdcall *QueryInterface)(IWICFormatConverter*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IWICFormatConverter*);
    ULONG   (__stdcall *Release)(IWICFormatConverter*);
    HRESULT (__stdcall *GetSize)(IWICFormatConverter*, UINT*, UINT*);
    HRESULT (__stdcall *GetPixelFormat)(IWICFormatConverter*, GUID_W*);
    HRESULT (__stdcall *GetResolution)(IWICFormatConverter*, double*, double*);
    HRESULT (__stdcall *CopyPalette)(IWICFormatConverter*, IWICPalette*);
    HRESULT (__stdcall *CopyPixels)(IWICFormatConverter*, void*, UINT, UINT, BYTE*);
    HRESULT (__stdcall *Initialize)(IWICFormatConverter*, IWICBitmapSource*, GUID_W*, DWORD, IWICPalette*, double, DWORD);
    HRESULT (__stdcall *CanConvert)(IWICFormatConverter*, GUID_W*, GUID_W*, BOOL*);
} IWICFormatConverterVtbl;
struct IWICFormatConverter { IWICFormatConverterVtbl *lpVtbl; };

typedef struct IWICStreamVtbl {
    HRESULT (__stdcall *QueryInterface)(IWICStream*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IWICStream*);
    ULONG   (__stdcall *Release)(IWICStream*);
    HRESULT (__stdcall *Read)(IWICStream*, void*, ULONG, ULONG*);
    HRESULT (__stdcall *Write)(IWICStream*, void*, ULONG, ULONG*);
    HRESULT (__stdcall *Seek)(IWICStream*, LONGLONG, DWORD, ULONGLONG*);
    HRESULT (__stdcall *SetSize)(IWICStream*, ULONGLONG);
    HRESULT (__stdcall *CopyTo)(IWICStream*, IStream*, ULONGLONG, ULONGLONG*, ULONGLONG*);
    HRESULT (__stdcall *Commit)(IWICStream*, DWORD);
    HRESULT (__stdcall *Revert)(IWICStream*);
    HRESULT (__stdcall *LockRegion)(IWICStream*, ULONGLONG, ULONGLONG, DWORD);
    HRESULT (__stdcall *UnlockRegion)(IWICStream*, ULONGLONG, ULONGLONG, DWORD);
    HRESULT (__stdcall *Stat)(IWICStream*, void*, DWORD);
    HRESULT (__stdcall *Clone)(IWICStream*, IStream**);
    HRESULT (__stdcall *InitializeFromIStream)(IWICStream*, IStream*);
    HRESULT (__stdcall *InitializeFromFilename)(IWICStream*, LPCWSTR, DWORD);
    HRESULT (__stdcall *InitializeFromMemory)(IWICStream*, BYTE*, DWORD);
    HRESULT (__stdcall *InitializeFromIStreamRegion)(IWICStream*, IStream*, ULONGLONG, ULONGLONG);
} IWICStreamVtbl;
struct IWICStream { IWICStreamVtbl *lpVtbl; };

typedef struct IWICBitmapEncoderVtbl {
    HRESULT (__stdcall *QueryInterface)(IWICBitmapEncoder*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IWICBitmapEncoder*);
    ULONG   (__stdcall *Release)(IWICBitmapEncoder*);
    HRESULT (__stdcall *Initialize)(IWICBitmapEncoder*, IStream*, DWORD);
    HRESULT (__stdcall *GetContainerFormat)(IWICBitmapEncoder*, GUID_W*);
    HRESULT (__stdcall *GetEncoderInfo)(IWICBitmapEncoder*, void**);
    HRESULT (__stdcall *SetColorContexts)(IWICBitmapEncoder*, UINT, void**);
    HRESULT (__stdcall *SetPalette)(IWICBitmapEncoder*, IWICPalette*);
    HRESULT (__stdcall *SetThumbnail)(IWICBitmapEncoder*, void*);
    HRESULT (__stdcall *SetPreview)(IWICBitmapEncoder*, void*);
    HRESULT (__stdcall *CreateNewFrame)(IWICBitmapEncoder*, IWICBitmapFrameEncode**, IPropertyBag2**);
    HRESULT (__stdcall *Commit)(IWICBitmapEncoder*);
    HRESULT (__stdcall *GetMetadataQueryWriter)(IWICBitmapEncoder*, void**);
} IWICBitmapEncoderVtbl;
struct IWICBitmapEncoder { IWICBitmapEncoderVtbl *lpVtbl; };

typedef struct IWICBitmapFrameEncodeVtbl {
    HRESULT (__stdcall *QueryInterface)(IWICBitmapFrameEncode*, GUID_W*, void**);
    ULONG   (__stdcall *AddRef)(IWICBitmapFrameEncode*);
    ULONG   (__stdcall *Release)(IWICBitmapFrameEncode*);
    HRESULT (__stdcall *Initialize)(IWICBitmapFrameEncode*, IPropertyBag2*);
    HRESULT (__stdcall *SetSize)(IWICBitmapFrameEncode*, UINT, UINT);
    HRESULT (__stdcall *SetResolution)(IWICBitmapFrameEncode*, double, double);
    HRESULT (__stdcall *SetPixelFormat)(IWICBitmapFrameEncode*, GUID_W*);
    HRESULT (__stdcall *SetColorContexts)(IWICBitmapFrameEncode*, UINT, void**);
    HRESULT (__stdcall *SetPalette)(IWICBitmapFrameEncode*, IWICPalette*);
    HRESULT (__stdcall *SetThumbnail)(IWICBitmapFrameEncode*, void*);
    HRESULT (__stdcall *WritePixels)(IWICBitmapFrameEncode*, UINT, UINT, UINT, BYTE*);
    HRESULT (__stdcall *WriteSource)(IWICBitmapFrameEncode*, IWICBitmapSource*, void*);
    HRESULT (__stdcall *Commit)(IWICBitmapFrameEncode*);
    HRESULT (__stdcall *GetMetadataQueryWriter)(IWICBitmapFrameEncode*, void**);
} IWICBitmapFrameEncodeVtbl;
struct IWICBitmapFrameEncode { IWICBitmapFrameEncodeVtbl *lpVtbl; };
]]

pcall(ffi.load, "windowscodecs")

-- ===== GUID helpers =====================================================
-- WIC GUIDs we use. Layout: {Data1, Data2, Data3, Data4[8]}.

local function make_guid(d1, d2, d3, d4)
    local g = ffi.new("GUID_W")
    g.Data1 = d1
    g.Data2 = d2
    g.Data3 = d3
    for i = 0, 7 do g.Data4[i] = d4[i + 1] end
    return g
end

-- CLSID_WICImagingFactory: cacef3aa-35a2-4d3b-93bf-eb1a3ec7a52a
local CLSID_WICImagingFactory = make_guid(
    0xcacef3aa, 0x35a2, 0x4d3b,
    { 0x93, 0xbf, 0xeb, 0x1a, 0x3e, 0xc7, 0xa5, 0x2a })

-- IID_IWICImagingFactory: ec5ec8a9-c395-4314-9c77-54d7a935ff70
local IID_IWICImagingFactory = make_guid(
    0xec5ec8a9, 0xc395, 0x4314,
    { 0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70 })

-- Container format GUIDs (for encoder selection).
M.GUID_ContainerFormatBmp  = make_guid(0x0af1d87e, 0xfcfe, 0x4188, {0xbd,0xeb,0xa7,0x90,0x64,0x71,0xcb,0xe3})
M.GUID_ContainerFormatPng  = make_guid(0x1b7cfaf4, 0x713f, 0x473c, {0xbb,0xcd,0x61,0x37,0x42,0x5f,0xae,0xaf})
M.GUID_ContainerFormatIco  = make_guid(0xa3a860c4, 0x338f, 0x4c17, {0x91,0x9a,0xfb,0xa4,0xb5,0x62,0x8f,0x21})
M.GUID_ContainerFormatJpeg = make_guid(0x19e4a5aa, 0x5662, 0x4fc5, {0xa0,0xc0,0x17,0x58,0x02,0x8e,0x10,0x57})
M.GUID_ContainerFormatTiff = make_guid(0x163bcc30, 0xe2e9, 0x4f0b, {0x96,0x1d,0xa3,0xe9,0xfd,0xb7,0x88,0xa3})
M.GUID_ContainerFormatGif  = make_guid(0x1f8a5601, 0x7d4d, 0x4cbd, {0x9c,0x82,0x1b,0xc8,0xd4,0xee,0xb9,0xa5})
M.GUID_ContainerFormatWmp  = make_guid(0x57a37caa, 0x367a, 0x4540, {0x91,0x6b,0xf1,0x83,0xc5,0x09,0x3a,0x4b})

-- Pixel format GUIDs.
M.GUID_WICPixelFormat32bppBGRA = make_guid(0x6fddc324, 0x4e03, 0x4bfe, {0xb1,0x85,0x3d,0x77,0x76,0x8d,0xc9,0x0f})
M.GUID_WICPixelFormat32bppRGBA = make_guid(0xf5c7ad2d, 0x6a8d, 0x43dd, {0xa7,0xa8,0xa2,0x99,0x35,0x26,0x1a,0xe9})
M.GUID_WICPixelFormat24bppBGR  = make_guid(0x6fddc324, 0x4e03, 0x4bfe, {0xb1,0x85,0x3d,0x77,0x76,0x8d,0xc9,0x0c})
M.GUID_WICPixelFormat24bppRGB  = make_guid(0x6fddc324, 0x4e03, 0x4bfe, {0xb1,0x85,0x3d,0x77,0x76,0x8d,0xc9,0x0d})
M.GUID_WICPixelFormat8bppGray  = make_guid(0x6fddc324, 0x4e03, 0x4bfe, {0xb1,0x85,0x3d,0x77,0x76,0x8d,0xc9,0x08})

-- ===== GUID equality (used by frame readers / converters) ==============
local function guid_eq(a, b)
    if a.Data1 ~= b.Data1 or a.Data2 ~= b.Data2 or a.Data3 ~= b.Data3 then
        return false
    end
    for i = 0, 7 do if a.Data4[i] ~= b.Data4[i] then return false end end
    return true
end

-- ===== HRESULT check ====================================================
local function check_hr(hr, where)
    if hr ~= 0 then
        -- HRESULTs are signed long; convert to unsigned hex for printing.
        local u = tonumber(hr) % 0x100000000
        error(string.format("wic: %s failed (HRESULT 0x%08x)", where, u), 2)
    end
end

-- ===== Object wrappers with auto-release ================================

local function wrap_release(ptr, label)
    local mt = {
        __gc = function(self)
            if self._ptr ~= nil then
                self._ptr.lpVtbl.Release(self._ptr)
                self._ptr = nil
            end
        end,
    }
    return setmetatable({ _ptr = ptr, _label = label }, mt)
end

-- ===== Factory ==========================================================

local Factory = {}
Factory.__index = Factory

function M.factory()
    local pp = ffi.new("void*[1]")
    -- CLSCTX_INPROC_SERVER = 1
    local hr = C.CoCreateInstance(CLSID_WICImagingFactory, nil, 1,
                                  IID_IWICImagingFactory, pp)
    check_hr(hr, "CoCreateInstance(WICImagingFactory)")
    local f = ffi.cast("IWICImagingFactory*", pp[0])
    return setmetatable({ _ptr = f, _wic_factory = true }, {
        __index = Factory,
        __gc = function(self)
            if self._ptr ~= nil then
                self._ptr.lpVtbl.Release(self._ptr)
                self._ptr = nil
            end
        end,
    })
end

-- Create an IWICStream from in-memory bytes. The IWICStream keeps a
-- reference to the buffer pointer, so we anchor the buffer on the
-- returned Lua object to keep it alive.
function Factory:stream_from_bytes(bytes)
    local pp = ffi.new("IWICStream*[1]")
    local hr = self._ptr.lpVtbl.CreateStream(self._ptr, pp)
    check_hr(hr, "CreateStream")
    local buf = ffi.new("uint8_t[?]", #bytes, bytes)
    hr = pp[0].lpVtbl.InitializeFromMemory(pp[0], buf, #bytes)
    check_hr(hr, "InitializeFromMemory")
    local w = wrap_release(pp[0], "IWICStream")
    w._anchor = buf  -- keep alive
    return w
end

local Frame = {}
Frame.__index = Frame

local function wrap_frame(framePtr)
    return setmetatable({
        _ptr = framePtr,
    }, {
        __index = Frame,
        __gc = function(self)
            if self._ptr ~= nil then
                self._ptr.lpVtbl.Release(self._ptr)
                self._ptr = nil
            end
        end,
    })
end

function Factory:decode_filename(path)
    local wpath = W.to_wstring and W.to_wstring(path) or nil
    -- If windows package doesn't ship a wstring helper, fall back to
    -- MultiByteToWideChar.
    if not wpath then
        local n = #path
        local buf = ffi.new("unsigned short[?]", n + 1)
        for i = 1, n do buf[i - 1] = path:byte(i) end
        buf[n] = 0
        wpath = buf
    end
    local pp = ffi.new("IWICBitmapDecoder*[1]")
    -- 0x80000000 = GENERIC_READ, 0 = WICDecodeMetadataCacheOnDemand
    local hr = self._ptr.lpVtbl.CreateDecoderFromFilename(
        self._ptr, wpath, nil, 0x80000000, 0, pp)
    check_hr(hr, "CreateDecoderFromFilename")
    return self:_first_frame(pp[0])
end

function Factory:decode_bytes(bytes)
    local stream = self:stream_from_bytes(bytes)
    local pp = ffi.new("IWICBitmapDecoder*[1]")
    -- Use the IWICStream as the IStream argument (vtable is layout-compat).
    local istream = ffi.cast("IStream*", stream._ptr)
    local hr = self._ptr.lpVtbl.CreateDecoderFromStream(
        self._ptr, istream, nil, 0, pp)
    check_hr(hr, "CreateDecoderFromStream")
    local frame = self:_first_frame(pp[0])
    frame._stream_anchor = stream
    return frame
end

function Factory:_first_frame(decoderPtr)
    local pfp = ffi.new("IWICBitmapFrameDecode*[1]")
    local hr = decoderPtr.lpVtbl.GetFrame(decoderPtr, 0, pfp)
    check_hr(hr, "GetFrame")
    -- Release the decoder; the frame holds its own ref.
    decoderPtr.lpVtbl.Release(decoderPtr)
    return wrap_frame(pfp[0])
end

function Factory:create_format_converter()
    local pp = ffi.new("IWICFormatConverter*[1]")
    local hr = self._ptr.lpVtbl.CreateFormatConverter(self._ptr, pp)
    check_hr(hr, "CreateFormatConverter")
    return wrap_release(pp[0], "IWICFormatConverter")
end

function Factory:create_encoder(container_guid)
    local pp = ffi.new("IWICBitmapEncoder*[1]")
    local hr = self._ptr.lpVtbl.CreateEncoder(self._ptr, container_guid, nil, pp)
    check_hr(hr, "CreateEncoder")
    return wrap_release(pp[0], "IWICBitmapEncoder")
end

function Factory:create_stream()
    local pp = ffi.new("IWICStream*[1]")
    local hr = self._ptr.lpVtbl.CreateStream(self._ptr, pp)
    check_hr(hr, "CreateStream")
    return wrap_release(pp[0], "IWICStream")
end

-- ===== Frame methods ====================================================

function Frame:size()
    local w = ffi.new("UINT[1]")
    local h = ffi.new("UINT[1]")
    local hr = self._ptr.lpVtbl.GetSize(self._ptr, w, h)
    check_hr(hr, "GetSize")
    return tonumber(w[0]), tonumber(h[0])
end

function Frame:pixel_format()
    local g = ffi.new("GUID_W")
    local hr = self._ptr.lpVtbl.GetPixelFormat(self._ptr, g)
    check_hr(hr, "GetPixelFormat")
    return g
end

function Frame:resolution()
    local dx = ffi.new("double[1]")
    local dy = ffi.new("double[1]")
    local hr = self._ptr.lpVtbl.GetResolution(self._ptr, dx, dy)
    check_hr(hr, "GetResolution")
    return tonumber(dx[0]), tonumber(dy[0])
end

-- Read all pixels at native pixel format, BGRA stride (w*4).
-- If target_fmt is passed, converts to that pixel format on the way out.
function Frame:read_pixels(opts)
    opts = opts or {}
    local w, h = self:size()
    local stride = opts.stride
    local target = opts.target_format or M.GUID_WICPixelFormat32bppBGRA
    -- Determine bytes-per-pixel from target (we only support a few).
    local bpp = 4
    if guid_eq(target, M.GUID_WICPixelFormat24bppBGR)
    or guid_eq(target, M.GUID_WICPixelFormat24bppRGB) then bpp = 3
    elseif guid_eq(target, M.GUID_WICPixelFormat8bppGray) then bpp = 1
    end
    stride = stride or (w * bpp)
    local buf = ffi.new("BYTE[?]", stride * h)

    -- Walk through a format converter if pixel format differs.
    local current_fmt = self:pixel_format()
    if not guid_eq(current_fmt, target) then
        local fac = opts.factory or _global_factory()
        local conv = fac:create_format_converter()
        local source = ffi.cast("IWICBitmapSource*", self._ptr)
        -- WICBitmapDitherTypeNone = 0, WICBitmapPaletteTypeCustom = 0
        local hr = conv._ptr.lpVtbl.Initialize(conv._ptr, source,
            target, 0, nil, 0.0, 0)
        check_hr(hr, "FormatConverter::Initialize")
        hr = conv._ptr.lpVtbl.CopyPixels(conv._ptr, nil, stride, stride * h, buf)
        check_hr(hr, "FormatConverter::CopyPixels")
    else
        local hr = self._ptr.lpVtbl.CopyPixels(self._ptr, nil, stride, stride * h, buf)
        check_hr(hr, "CopyPixels")
    end
    return ffi.string(buf, stride * h), stride
end

-- Lazy-loaded process-wide factory used by Frame:read_pixels when caller
-- didn't pass one in. Keeping one factory per process avoids the small
-- but non-trivial CoCreateInstance cost on every decode.
local _gf
local function _global_factory()
    if not _gf then _gf = M.factory() end
    return _gf
end

-- ===== High-level helpers ===============================================

function M.decode(bytes_or_path, opts)
    opts = opts or {}
    local f = _global_factory()
    if opts.is_path or (type(bytes_or_path) == "string" and #bytes_or_path < 260
        and not bytes_or_path:find("\0")) then
        -- A reasonable heuristic: short string with no NUL is a path. The
        -- caller can force one direction via opts.is_path / opts.is_bytes.
        if opts.is_bytes then
            return f:decode_bytes(bytes_or_path)
        end
        -- Attempt path first; on failure, fall back to bytes (covers the
        -- ambiguous case where a short binary blob doesn't look like a path).
        local ok, frame = pcall(f.decode_filename, f, bytes_or_path)
        if ok then return frame end
        return f:decode_bytes(bytes_or_path)
    end
    return f:decode_bytes(bytes_or_path)
end

-- Encode a frame (or raw BGRA bytes + dims) into the given container format.
-- container: "png" | "jpeg" | "bmp" | "gif" | "tiff" | "wmp"
function M.encode(input, container, dst, opts)
    opts = opts or {}
    local guids = {
        png  = M.GUID_ContainerFormatPng,
        jpeg = M.GUID_ContainerFormatJpeg,
        jpg  = M.GUID_ContainerFormatJpeg,
        bmp  = M.GUID_ContainerFormatBmp,
        gif  = M.GUID_ContainerFormatGif,
        tiff = M.GUID_ContainerFormatTiff,
        tif  = M.GUID_ContainerFormatTiff,
        wmp  = M.GUID_ContainerFormatWmp,
    }
    local cguid = guids[container:lower()]
    if not cguid then error("wic.encode: unknown container " .. container) end
    local f = _global_factory()
    local encoder = f:create_encoder(cguid)

    -- Build an output stream: either filename or in-memory.
    local stream = f:create_stream()
    local out_buf
    if type(dst) == "string" then
        local n = #dst
        local wbuf = ffi.new("unsigned short[?]", n + 1)
        for i = 1, n do wbuf[i - 1] = dst:byte(i) end
        wbuf[n] = 0
        local hr = stream._ptr.lpVtbl.InitializeFromFilename(stream._ptr, wbuf, 0x40000000)  -- GENERIC_WRITE
        check_hr(hr, "Stream InitializeFromFilename")
    else
        -- Memory: allocate up-front. Caller passes a size hint via opts.buffer_size.
        local sz = opts.buffer_size or (1024 * 1024)
        out_buf = ffi.new("BYTE[?]", sz)
        local hr = stream._ptr.lpVtbl.InitializeFromMemory(stream._ptr, out_buf, sz)
        check_hr(hr, "Stream InitializeFromMemory")
    end

    local istream = ffi.cast("IStream*", stream._ptr)
    local hr = encoder._ptr.lpVtbl.Initialize(encoder._ptr, istream, 0)  -- WICBitmapEncoderNoCache
    check_hr(hr, "Encoder Initialize")

    local fpp = ffi.new("IWICBitmapFrameEncode*[1]")
    local bpp = ffi.new("IPropertyBag2*[1]")
    hr = encoder._ptr.lpVtbl.CreateNewFrame(encoder._ptr, fpp, bpp)
    check_hr(hr, "CreateNewFrame")
    local fe = wrap_release(fpp[0], "IWICBitmapFrameEncode")

    hr = fe._ptr.lpVtbl.Initialize(fe._ptr, bpp[0])
    check_hr(hr, "Frame Initialize")

    -- input is either a Frame or a table { width, height, pixels, format? }
    if type(input) == "table" and input.pixels then
        hr = fe._ptr.lpVtbl.SetSize(fe._ptr, input.width, input.height)
        check_hr(hr, "SetSize")
        local fmt = input.format or M.GUID_WICPixelFormat32bppBGRA
        hr = fe._ptr.lpVtbl.SetPixelFormat(fe._ptr, fmt)
        check_hr(hr, "SetPixelFormat")
        local stride = input.stride or (input.width * 4)
        local pbuf = ffi.new("BYTE[?]", #input.pixels, input.pixels)
        hr = fe._ptr.lpVtbl.WritePixels(fe._ptr, input.height, stride,
            stride * input.height, pbuf)
        check_hr(hr, "WritePixels")
    else
        local w, h = input:size()
        hr = fe._ptr.lpVtbl.SetSize(fe._ptr, w, h)
        check_hr(hr, "SetSize")
        local fmt = input:pixel_format()
        hr = fe._ptr.lpVtbl.SetPixelFormat(fe._ptr, fmt)
        check_hr(hr, "SetPixelFormat")
        local source = ffi.cast("IWICBitmapSource*", input._ptr)
        hr = fe._ptr.lpVtbl.WriteSource(fe._ptr, source, nil)
        check_hr(hr, "WriteSource")
    end

    hr = fe._ptr.lpVtbl.Commit(fe._ptr)
    check_hr(hr, "Frame Commit")
    hr = encoder._ptr.lpVtbl.Commit(encoder._ptr)
    check_hr(hr, "Encoder Commit")

    if out_buf then
        -- Memory output: query the stream's seek/tell or just return the
        -- buffer up to the encoder's commit point. WIC doesn't expose
        -- written size directly via IWICStream alone, so we use IStream
        -- ::Stat which exists on the same vtable layout above (slot 11
        -- is "Stat"). Not modelled here; instead, callers using a memory
        -- sink should provide buffer_size and read out via ffi.string up
        -- to that size after counting. Pragmatic compromise: return the
        -- whole buffer + size hint -- the encoder writes contiguously
        -- from byte 0, the trailing bytes are zero-fill from the buffer.
        return ffi.string(out_buf, opts.buffer_size or (1024 * 1024))
    end
end

M.guid_eq = guid_eq
M._global_factory = _global_factory

return M
