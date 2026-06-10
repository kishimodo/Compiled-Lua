-- mupdf -- MuPDF PDF / XPS / EPUB rendering bindings.
--
-- Public surface:
--   mupdf.available()                 -- true if mupdf.dll loaded
--   mupdf.version()                   -- "x.y.z" or "?" if not reported
--   mupdf.open(path)                  -> doc
--
-- doc:
--   :page_count()                     -> int
--   :page(idx)                        -> page  (1-based)
--   :close()
--
-- page:
--   :size()                           -> { w, h }   (in MuPDF "user units")
--   :render(opts?)                    -> { pixels, w, h, channels, stride }
--                                          opts: { scale=1.0, dpi=72, format="rgb"|"rgba"|"gray" }
--   :render_to_png(path, opts?)       -> bool
--   :text()                           -> string  (extracted plain text)
--   :close()
--
-- Notes:
--   * MuPDF uses a single fz_context per binding; we hold one as a module
--     singleton, initialized lazily on first open() and torn down via the
--     Lua state's collection sweep when the module is unloaded.
--   * Coordinates are device-space (top-left origin) after applying the
--     scale transform. The DPI convention is 72 = 1:1.

local M = {}

ffi.cdef[[
typedef struct fz_context    fz_context;
typedef struct fz_document   fz_document;
typedef struct fz_page       fz_page;
typedef struct fz_pixmap     fz_pixmap;
typedef struct fz_colorspace fz_colorspace;
typedef struct fz_device     fz_device;
typedef struct fz_stext_page fz_stext_page;
typedef struct fz_buffer     fz_buffer;

typedef struct {
    float x0, y0, x1, y1;
} fz_rect;

typedef struct {
    float a, b, c, d, e, f;
} fz_matrix;

typedef struct {
    int x0, y0, x1, y1;
} fz_irect;

fz_context *fz_new_context_imp(void *alloc, void *locks, size_t maxstore, const char *version);
void        fz_drop_context(fz_context *ctx);
void        fz_register_document_handlers(fz_context *ctx);

fz_document *fz_open_document(fz_context *ctx, const char *filename);
void         fz_drop_document(fz_context *ctx, fz_document *doc);
int          fz_count_pages(fz_context *ctx, fz_document *doc);
fz_page     *fz_load_page(fz_context *ctx, fz_document *doc, int idx);
void         fz_drop_page(fz_context *ctx, fz_page *page);
fz_rect      fz_bound_page(fz_context *ctx, fz_page *page);

fz_colorspace *fz_device_rgb(fz_context *ctx);
fz_colorspace *fz_device_gray(fz_context *ctx);
fz_colorspace *fz_device_bgr(fz_context *ctx);

fz_matrix fz_scale(float sx, float sy);
fz_matrix fz_identity_matrix(void);
fz_matrix fz_translate(float tx, float ty);
fz_matrix fz_concat(fz_matrix a, fz_matrix b);
fz_rect   fz_transform_rect(fz_rect r, fz_matrix m);
fz_irect  fz_round_rect(fz_rect r);

fz_pixmap *fz_new_pixmap_with_bbox(fz_context *ctx, fz_colorspace *cs,
                                   fz_irect bbox, void *seps, int alpha);
void       fz_clear_pixmap_with_value(fz_context *ctx, fz_pixmap *pix, int value);
void       fz_drop_pixmap(fz_context *ctx, fz_pixmap *pix);
int        fz_pixmap_width(fz_context *ctx, fz_pixmap *pix);
int        fz_pixmap_height(fz_context *ctx, fz_pixmap *pix);
int        fz_pixmap_stride(fz_context *ctx, fz_pixmap *pix);
int        fz_pixmap_components(fz_context *ctx, fz_pixmap *pix);
unsigned char *fz_pixmap_samples(fz_context *ctx, fz_pixmap *pix);

fz_device *fz_new_draw_device(fz_context *ctx, fz_matrix transform, fz_pixmap *dest);
void       fz_run_page(fz_context *ctx, fz_page *page, fz_device *dev,
                       fz_matrix ctm, void *cookie);
void       fz_close_device(fz_context *ctx, fz_device *dev);
void       fz_drop_device(fz_context *ctx, fz_device *dev);

void fz_save_pixmap_as_png(fz_context *ctx, fz_pixmap *pix, const char *filename);

fz_stext_page *fz_new_stext_page_from_page(fz_context *ctx, fz_page *page, void *options);
void           fz_drop_stext_page(fz_context *ctx, fz_stext_page *page);

fz_buffer *fz_new_buffer_from_stext_page(fz_context *ctx, fz_stext_page *page);
size_t     fz_buffer_storage(fz_context *ctx, fz_buffer *buf, unsigned char **data);
void       fz_drop_buffer(fz_context *ctx, fz_buffer *buf);

const char *fz_version(void);
]]

-- ===== Lazy DLL loader ===================================================

local _lib, _load_err

local function load_lib()
    if _lib then return _lib end
    if _load_err then return nil end
    local names = {}
    local env_dll = os.getenv("LUAVM_MUPDF_DLL")
    if env_dll and #env_dll > 0 then names[#names + 1] = env_dll end
    names[#names + 1] = "mupdf"
    names[#names + 1] = "mupdf.dll"
    names[#names + 1] = "libmupdf"
    names[#names + 1] = "libmupdf.dll"
    for _, n in ipairs(names) do
        local ok, lib = pcall(ffi.load, n)
        if ok then _lib = lib; return lib end
    end
    _load_err = "mupdf: mupdf.dll not found. Set LUAVM_MUPDF_DLL or drop mupdf.dll next to LuaVM."
    return nil
end

function M.available()
    return load_lib() ~= nil
end

local function require_lib()
    local L = load_lib()
    if L == nil then error(_load_err, 3) end
    return L
end

function M.version()
    local L = load_lib()
    if L == nil then return "?" end
    local ok, v = pcall(function() return L.fz_version() end)
    if not ok or v == nil then return "?" end
    return ffi.string(v)
end

-- ===== Singleton context =================================================

local _ctx

-- The MuPDF API version string defaults to a stable value; some builds
-- export FZ_VERSION as a macro that the SO interns. We pass NULL/"1.0"
-- which mupdf treats as "trust whatever was linked" -- safer than
-- guessing a build-specific tag.
local function ensure_ctx()
    if _ctx then return _ctx end
    local L = require_lib()
    local c = L.fz_new_context_imp(nil, nil, 256 * 1024 * 1024, "1.0")
    if c == nil then
        error("mupdf: fz_new_context_imp returned nil", 3)
    end
    -- Wrap with a GC finalizer so the context drops when the Lua state
    -- collapses. Document / page objects all carry strong refs to the
    -- module's _ctx via this table.
    _ctx = ffi.gc(c, function(p) L.fz_drop_context(p) end)
    -- Register handlers for PDF / EPUB / XPS / CBZ etc.
    pcall(function() L.fz_register_document_handlers(_ctx) end)
    return _ctx
end

-- ===== Page object =======================================================

local Page = {}
Page.__index = Page

local function wrap_page(L, ctx, page_ptr, idx)
    return setmetatable({
        _lib  = L,
        _ctx  = ctx,
        _page = ffi.gc(page_ptr, function(p) L.fz_drop_page(ctx, p) end),
        _idx  = idx,
    }, Page)
end

function Page:size()
    local r = self._lib.fz_bound_page(self._ctx, self._page)
    return { w = tonumber(r.x1 - r.x0), h = tonumber(r.y1 - r.y0) }
end

local function parse_render_opts(opts)
    opts = opts or {}
    local scale = opts.scale
    if scale == nil and opts.dpi then
        scale = opts.dpi / 72.0
    end
    if scale == nil then scale = 1.0 end
    local format = opts.format or "rgb"
    if format ~= "rgb" and format ~= "rgba" and format ~= "gray" then
        error("mupdf: render format must be 'rgb'|'rgba'|'gray'", 3)
    end
    return scale, format
end

-- Build a pixmap by running the page through a draw device.
local function render_pixmap(self, opts)
    local L      = self._lib
    local ctx    = self._ctx
    local scale, format = parse_render_opts(opts)
    local cs
    if format == "gray" then
        cs = L.fz_device_gray(ctx)
    else
        cs = L.fz_device_rgb(ctx)
    end
    local alpha = format == "rgba" and 1 or 0
    local bounds = L.fz_bound_page(ctx, self._page)
    local m = L.fz_scale(scale, scale)
    local scaled = L.fz_transform_rect(bounds, m)
    local bbox = L.fz_round_rect(scaled)
    local pix = L.fz_new_pixmap_with_bbox(ctx, cs, bbox, nil, alpha)
    if pix == nil then error("mupdf: fz_new_pixmap_with_bbox returned nil", 3) end
    L.fz_clear_pixmap_with_value(ctx, pix, 0xFF)
    local dev = L.fz_new_draw_device(ctx, m, pix)
    if dev == nil then
        L.fz_drop_pixmap(ctx, pix)
        error("mupdf: fz_new_draw_device returned nil", 3)
    end
    -- Run + close + drop.
    L.fz_run_page(ctx, self._page, dev, L.fz_identity_matrix(), nil)
    L.fz_close_device(ctx, dev)
    L.fz_drop_device(ctx, dev)
    return pix, format
end

function Page:render(opts)
    local L = self._lib
    local ctx = self._ctx
    local pix, format = render_pixmap(self, opts)
    local w = L.fz_pixmap_width(ctx, pix)
    local h = L.fz_pixmap_height(ctx, pix)
    local stride = L.fz_pixmap_stride(ctx, pix)
    local chans  = L.fz_pixmap_components(ctx, pix) + (format == "rgba" and 1 or 0)
    -- The component count from fz_pixmap_components is the color channel
    -- count (excluding alpha); use the format hint for the real output.
    local out_chans
    if format == "rgba" then out_chans = 4
    elseif format == "gray" then out_chans = 1
    else out_chans = 3
    end
    local samples = L.fz_pixmap_samples(ctx, pix)
    local pixels = ffi.string(samples, stride * h)
    L.fz_drop_pixmap(ctx, pix)
    return {
        pixels   = pixels,
        w        = tonumber(w),
        h        = tonumber(h),
        channels = out_chans,
        stride   = tonumber(stride),
    }
end

function Page:render_to_png(path, opts)
    local L = self._lib
    local ctx = self._ctx
    local pix = render_pixmap(self, opts)
    local ok, err = pcall(function() L.fz_save_pixmap_as_png(ctx, pix, path) end)
    L.fz_drop_pixmap(ctx, pix)
    if not ok then error("mupdf: save_pixmap_as_png: " .. tostring(err), 2) end
    return true
end

function Page:text()
    local L = self._lib
    local ctx = self._ctx
    local sp = L.fz_new_stext_page_from_page(ctx, self._page, nil)
    if sp == nil then return "" end
    local sp_gc = ffi.gc(sp, function(p) L.fz_drop_stext_page(ctx, p) end)
    -- Convert the structured text page to a flat buffer (UTF-8).
    local ok, buf = pcall(function() return L.fz_new_buffer_from_stext_page(ctx, sp_gc) end)
    if not ok or buf == nil then return "" end
    local buf_gc = ffi.gc(buf, function(p) L.fz_drop_buffer(ctx, p) end)
    local data_pp = ffi.new("unsigned char*[1]")
    local n = L.fz_buffer_storage(ctx, buf_gc, data_pp)
    if n == 0 or data_pp[0] == nil then return "" end
    return ffi.string(data_pp[0], tonumber(n))
end

function Page:close()
    if self._page ~= nil then
        self._lib.fz_drop_page(self._ctx, ffi.gc(self._page, nil))
        self._page = nil
    end
end

Page.__gc = Page.close

-- ===== Document object ===================================================

local Doc = {}
Doc.__index = Doc

function Doc:page_count()
    return tonumber(self._lib.fz_count_pages(self._ctx, self._doc))
end

function Doc:page(idx)
    if idx == nil or idx < 1 then
        error("mupdf: page index must be 1-based positive integer", 2)
    end
    local n = self:page_count()
    if idx > n then
        error(string.format("mupdf: page %d out of range (doc has %d)", idx, n), 2)
    end
    local p = self._lib.fz_load_page(self._ctx, self._doc, idx - 1)
    if p == nil then error("mupdf: fz_load_page returned nil", 2) end
    return wrap_page(self._lib, self._ctx, p, idx)
end

function Doc:close()
    if self._doc ~= nil then
        self._lib.fz_drop_document(self._ctx, ffi.gc(self._doc, nil))
        self._doc = nil
    end
end

Doc.__gc = Doc.close

-- ===== Module entry points ==============================================

function M.open(path)
    local L   = require_lib()
    local ctx = ensure_ctx()
    local doc = L.fz_open_document(ctx, path)
    if doc == nil then
        error("mupdf: fz_open_document failed for '" .. tostring(path) .. "'", 2)
    end
    return setmetatable({
        _lib  = L,
        _ctx  = ctx,
        _doc  = ffi.gc(doc, function(p) L.fz_drop_document(ctx, p) end),
        _path = path,
    }, Doc)
end

return M
