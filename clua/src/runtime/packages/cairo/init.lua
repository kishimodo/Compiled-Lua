-- cairo -- Cairo 2D vector graphics bindings.
--
-- Public surface:
--   cairo.available()                 -- true if cairo.dll loaded
--   cairo.version()                   -- "major.minor.micro"
--   cairo.image_surface(format, w, h) -> surface  (format: "argb32"|"rgb24"|"a8"|"a1")
--   cairo.pdf_surface(path, w, h)     -> surface  (size in PostScript points)
--   cairo.svg_surface(path, w, h)     -> surface
--
-- surface:
--   :context()                        -> ctx
--   :write_png(path)                  -> bool  (image surfaces only)
--   :flush() / :finish() / :destroy()
--   :width() / :height()
--   :status()                         -> { code, message }
--
-- ctx: chainable -- every call returns self unless noted.
--   :move_to(x, y) / :line_to(x, y) / :curve_to(x1,y1,x2,y2,x3,y3)
--   :arc(cx, cy, r, a1, a2) / :arc_negative(...)
--   :rectangle(x, y, w, h) / :close_path() / :new_path() / :new_sub_path()
--   :set_source_rgb(r, g, b) / :set_source_rgba(r, g, b, a)
--   :set_color(...)                          -- alias for set_source_rgba
--   :set_line_width(w) / :set_line_cap(s) / :set_line_join(s) / :set_dash({d1,d2,...}, offset?)
--   :set_miter_limit(n)
--   :stroke() / :stroke_preserve() / :fill() / :fill_preserve()
--   :clip() / :clip_preserve() / :reset_clip()
--   :paint() / :paint_with_alpha(a)
--   :translate(dx, dy) / :rotate(rad) / :scale(sx, sy)
--   :save() / :restore()
--   :set_font(family, slant?, weight?) / :set_font_size(s)
--   :text(s)                                  -- shorthand: show_text at current pos
--   :show_text(s)
--   :text_extents(s)                          -> { x_bearing, y_bearing, width, height, x_advance, y_advance }
--   :status()                                 -> { code, message }

local M = {}

ffi.cdef[[
typedef struct _cairo         cairo_t;
typedef struct _cairo_surface cairo_surface_t;

typedef enum {
    CAIRO_FORMAT_INVALID   = -1,
    CAIRO_FORMAT_ARGB32    = 0,
    CAIRO_FORMAT_RGB24     = 1,
    CAIRO_FORMAT_A8        = 2,
    CAIRO_FORMAT_A1        = 3,
    CAIRO_FORMAT_RGB16_565 = 4,
    CAIRO_FORMAT_RGB30     = 5
} cairo_format_t;

typedef enum {
    CAIRO_LINE_CAP_BUTT   = 0,
    CAIRO_LINE_CAP_ROUND  = 1,
    CAIRO_LINE_CAP_SQUARE = 2
} cairo_line_cap_t;

typedef enum {
    CAIRO_LINE_JOIN_MITER = 0,
    CAIRO_LINE_JOIN_ROUND = 1,
    CAIRO_LINE_JOIN_BEVEL = 2
} cairo_line_join_t;

typedef enum {
    CAIRO_FONT_SLANT_NORMAL  = 0,
    CAIRO_FONT_SLANT_ITALIC  = 1,
    CAIRO_FONT_SLANT_OBLIQUE = 2
} cairo_font_slant_t;

typedef enum {
    CAIRO_FONT_WEIGHT_NORMAL = 0,
    CAIRO_FONT_WEIGHT_BOLD   = 1
} cairo_font_weight_t;

typedef struct {
    double x_bearing;
    double y_bearing;
    double width;
    double height;
    double x_advance;
    double y_advance;
} cairo_text_extents_t;

typedef int cairo_status_t;
typedef int cairo_bool_t;
typedef int (*cairo_write_func_t)(void *closure, const unsigned char *data, unsigned int length);

int          cairo_version(void);
const char  *cairo_version_string(void);
cairo_status_t cairo_status(cairo_t *cr);
const char  *cairo_status_to_string(cairo_status_t status);

cairo_surface_t *cairo_image_surface_create(cairo_format_t format, int width, int height);
cairo_surface_t *cairo_image_surface_create_for_data(unsigned char *data, cairo_format_t format,
                                                     int width, int height, int stride);
int  cairo_image_surface_get_width(cairo_surface_t *s);
int  cairo_image_surface_get_height(cairo_surface_t *s);
int  cairo_image_surface_get_stride(cairo_surface_t *s);
unsigned char *cairo_image_surface_get_data(cairo_surface_t *s);
int  cairo_format_stride_for_width(cairo_format_t format, int width);

cairo_surface_t *cairo_pdf_surface_create(const char *filename, double w, double h);
cairo_surface_t *cairo_svg_surface_create(const char *filename, double w, double h);

void cairo_surface_destroy(cairo_surface_t *s);
void cairo_surface_flush(cairo_surface_t *s);
void cairo_surface_finish(cairo_surface_t *s);
cairo_status_t cairo_surface_status(cairo_surface_t *s);
cairo_status_t cairo_surface_write_to_png(cairo_surface_t *s, const char *path);

cairo_t *cairo_create(cairo_surface_t *s);
void     cairo_destroy(cairo_t *cr);
void     cairo_save(cairo_t *cr);
void     cairo_restore(cairo_t *cr);

void cairo_move_to(cairo_t *cr, double x, double y);
void cairo_line_to(cairo_t *cr, double x, double y);
void cairo_curve_to(cairo_t *cr, double x1, double y1, double x2, double y2, double x3, double y3);
void cairo_rel_move_to(cairo_t *cr, double dx, double dy);
void cairo_rel_line_to(cairo_t *cr, double dx, double dy);
void cairo_arc(cairo_t *cr, double cx, double cy, double r, double a1, double a2);
void cairo_arc_negative(cairo_t *cr, double cx, double cy, double r, double a1, double a2);
void cairo_rectangle(cairo_t *cr, double x, double y, double w, double h);
void cairo_close_path(cairo_t *cr);
void cairo_new_path(cairo_t *cr);
void cairo_new_sub_path(cairo_t *cr);

void cairo_set_source_rgb(cairo_t *cr, double r, double g, double b);
void cairo_set_source_rgba(cairo_t *cr, double r, double g, double b, double a);
void cairo_set_line_width(cairo_t *cr, double w);
void cairo_set_line_cap(cairo_t *cr, cairo_line_cap_t c);
void cairo_set_line_join(cairo_t *cr, cairo_line_join_t j);
void cairo_set_miter_limit(cairo_t *cr, double n);
void cairo_set_dash(cairo_t *cr, const double *dashes, int num_dashes, double offset);
void cairo_set_tolerance(cairo_t *cr, double tol);
void cairo_set_operator(cairo_t *cr, int op);

void cairo_stroke(cairo_t *cr);
void cairo_stroke_preserve(cairo_t *cr);
void cairo_fill(cairo_t *cr);
void cairo_fill_preserve(cairo_t *cr);
void cairo_clip(cairo_t *cr);
void cairo_clip_preserve(cairo_t *cr);
void cairo_reset_clip(cairo_t *cr);
void cairo_paint(cairo_t *cr);
void cairo_paint_with_alpha(cairo_t *cr, double a);

void cairo_translate(cairo_t *cr, double dx, double dy);
void cairo_rotate(cairo_t *cr, double radians);
void cairo_scale(cairo_t *cr, double sx, double sy);
void cairo_identity_matrix(cairo_t *cr);

void cairo_select_font_face(cairo_t *cr, const char *family,
                            cairo_font_slant_t slant, cairo_font_weight_t weight);
void cairo_set_font_size(cairo_t *cr, double size);
void cairo_show_text(cairo_t *cr, const char *utf8);
void cairo_text_extents(cairo_t *cr, const char *utf8, cairo_text_extents_t *out);

double cairo_get_current_point_x(cairo_t *cr);
double cairo_get_current_point_y(cairo_t *cr);
void   cairo_get_current_point(cairo_t *cr, double *x, double *y);

int cairo_has_current_point(cairo_t *cr);
]]

-- ===== Constants =========================================================

M.FORMAT_ARGB32 = 0
M.FORMAT_RGB24  = 1
M.FORMAT_A8     = 2
M.FORMAT_A1     = 3

M.LINE_CAP_BUTT   = 0
M.LINE_CAP_ROUND  = 1
M.LINE_CAP_SQUARE = 2

M.LINE_JOIN_MITER = 0
M.LINE_JOIN_ROUND = 1
M.LINE_JOIN_BEVEL = 2

M.FONT_SLANT_NORMAL  = 0
M.FONT_SLANT_ITALIC  = 1
M.FONT_SLANT_OBLIQUE = 2

M.FONT_WEIGHT_NORMAL = 0
M.FONT_WEIGHT_BOLD   = 1

-- ===== Lazy DLL loader ===================================================

local _lib, _load_err

local function load_lib()
    if _lib then return _lib end
    if _load_err then return nil end
    local names = {}
    local env_dll = os.getenv("LUAVM_CAIRO_DLL")
    if env_dll and #env_dll > 0 then names[#names + 1] = env_dll end
    names[#names + 1] = "cairo"
    names[#names + 1] = "cairo.dll"
    names[#names + 1] = "libcairo"
    names[#names + 1] = "libcairo-2.dll"
    for _, n in ipairs(names) do
        local ok, lib = pcall(ffi.load, n)
        if ok then _lib = lib; return lib end
    end
    _load_err = "cairo: cairo.dll not found. Set LUAVM_CAIRO_DLL or drop cairo.dll next to LuaVM."
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
    local L = require_lib()
    local s = L.cairo_version_string()
    return s ~= nil and ffi.string(s) or ""
end

-- ===== Format-string helpers =============================================

local function format_to_enum(s)
    if s == "argb32" or s == nil then return M.FORMAT_ARGB32 end
    if s == "rgb24"               then return M.FORMAT_RGB24  end
    if s == "a8"                  then return M.FORMAT_A8     end
    if s == "a1"                  then return M.FORMAT_A1     end
    error("cairo: unknown format '" .. tostring(s) .. "'", 3)
end

local function cap_to_enum(s)
    if s == "butt"   or s == nil then return M.LINE_CAP_BUTT   end
    if s == "round"              then return M.LINE_CAP_ROUND  end
    if s == "square"             then return M.LINE_CAP_SQUARE end
    error("cairo: unknown line cap '" .. tostring(s) .. "'", 3)
end

local function join_to_enum(s)
    if s == "miter" or s == nil then return M.LINE_JOIN_MITER end
    if s == "round"             then return M.LINE_JOIN_ROUND end
    if s == "bevel"             then return M.LINE_JOIN_BEVEL end
    error("cairo: unknown line join '" .. tostring(s) .. "'", 3)
end

local function slant_to_enum(s)
    if s == "normal"  or s == nil then return M.FONT_SLANT_NORMAL  end
    if s == "italic"              then return M.FONT_SLANT_ITALIC  end
    if s == "oblique"             then return M.FONT_SLANT_OBLIQUE end
    error("cairo: unknown font slant '" .. tostring(s) .. "'", 3)
end

local function weight_to_enum(s)
    if s == "normal" or s == nil then return M.FONT_WEIGHT_NORMAL end
    if s == "bold"               then return M.FONT_WEIGHT_BOLD   end
    error("cairo: unknown font weight '" .. tostring(s) .. "'", 3)
end

-- ===== Context object ====================================================

local Ctx = {}
Ctx.__index = Ctx

local function check_status(self)
    local code = self._lib.cairo_status(self._cr)
    if code ~= 0 then
        local msg = self._lib.cairo_status_to_string(code)
        error("cairo: " .. (msg ~= nil and ffi.string(msg) or tostring(code)), 3)
    end
end

function Ctx:status()
    local code = self._lib.cairo_status(self._cr)
    local msg = self._lib.cairo_status_to_string(code)
    return { code = code, message = msg ~= nil and ffi.string(msg) or "" }
end

function Ctx:destroy()
    if self._cr ~= nil then
        self._lib.cairo_destroy(ffi.gc(self._cr, nil))
        self._cr = nil
    end
end

Ctx.__gc = Ctx.destroy

-- Path API.
function Ctx:move_to(x, y) self._lib.cairo_move_to(self._cr, x, y); return self end
function Ctx:line_to(x, y) self._lib.cairo_line_to(self._cr, x, y); return self end
function Ctx:curve_to(x1, y1, x2, y2, x3, y3)
    self._lib.cairo_curve_to(self._cr, x1, y1, x2, y2, x3, y3); return self
end
function Ctx:rel_move_to(dx, dy) self._lib.cairo_rel_move_to(self._cr, dx, dy); return self end
function Ctx:rel_line_to(dx, dy) self._lib.cairo_rel_line_to(self._cr, dx, dy); return self end
function Ctx:arc(cx, cy, r, a1, a2)
    self._lib.cairo_arc(self._cr, cx, cy, r, a1, a2); return self
end
function Ctx:arc_negative(cx, cy, r, a1, a2)
    self._lib.cairo_arc_negative(self._cr, cx, cy, r, a1, a2); return self
end
function Ctx:rect(x, y, w, h)
    self._lib.cairo_rectangle(self._cr, x, y, w, h); return self
end
Ctx.rectangle = Ctx.rect
function Ctx:close_path()   self._lib.cairo_close_path(self._cr);  return self end
function Ctx:new_path()     self._lib.cairo_new_path(self._cr);    return self end
function Ctx:new_sub_path() self._lib.cairo_new_sub_path(self._cr); return self end

-- Source / style.
function Ctx:set_source_rgb(r, g, b)
    self._lib.cairo_set_source_rgb(self._cr, r, g, b); return self
end
function Ctx:set_source_rgba(r, g, b, a)
    self._lib.cairo_set_source_rgba(self._cr, r, g, b, a); return self
end
function Ctx:set_color(r, g, b, a)
    if a == nil then a = 1.0 end
    self._lib.cairo_set_source_rgba(self._cr, r, g, b, a); return self
end
function Ctx:set_line_width(w)
    self._lib.cairo_set_line_width(self._cr, w); return self
end
function Ctx:set_line_cap(s)
    self._lib.cairo_set_line_cap(self._cr, cap_to_enum(s)); return self
end
function Ctx:set_line_join(s)
    self._lib.cairo_set_line_join(self._cr, join_to_enum(s)); return self
end
function Ctx:set_miter_limit(n)
    self._lib.cairo_set_miter_limit(self._cr, n); return self
end
function Ctx:set_dash(dashes, offset)
    offset = offset or 0
    local n = #dashes
    local arr = ffi.new("double[?]", n)
    for i = 1, n do arr[i - 1] = dashes[i] end
    self._lib.cairo_set_dash(self._cr, arr, n, offset); return self
end

-- Painting verbs.
function Ctx:stroke()           self._lib.cairo_stroke(self._cr);           return self end
function Ctx:stroke_preserve()  self._lib.cairo_stroke_preserve(self._cr);  return self end
function Ctx:fill()             self._lib.cairo_fill(self._cr);             return self end
function Ctx:fill_preserve()    self._lib.cairo_fill_preserve(self._cr);    return self end
function Ctx:clip()             self._lib.cairo_clip(self._cr);             return self end
function Ctx:clip_preserve()    self._lib.cairo_clip_preserve(self._cr);    return self end
function Ctx:reset_clip()       self._lib.cairo_reset_clip(self._cr);       return self end
function Ctx:paint()            self._lib.cairo_paint(self._cr);            return self end
function Ctx:paint_with_alpha(a) self._lib.cairo_paint_with_alpha(self._cr, a); return self end

-- Transforms.
function Ctx:translate(dx, dy) self._lib.cairo_translate(self._cr, dx, dy); return self end
function Ctx:rotate(rad)       self._lib.cairo_rotate(self._cr, rad);       return self end
function Ctx:scale(sx, sy)
    sy = sy or sx
    self._lib.cairo_scale(self._cr, sx, sy); return self
end
function Ctx:identity_matrix() self._lib.cairo_identity_matrix(self._cr); return self end
function Ctx:save()    self._lib.cairo_save(self._cr);    return self end
function Ctx:restore() self._lib.cairo_restore(self._cr); return self end

-- Text.
function Ctx:set_font(family, slant, weight)
    self._lib.cairo_select_font_face(self._cr, family,
        slant_to_enum(slant), weight_to_enum(weight))
    return self
end
function Ctx:set_font_size(s) self._lib.cairo_set_font_size(self._cr, s); return self end
function Ctx:show_text(s)
    self._lib.cairo_show_text(self._cr, s); return self
end
-- Shorthand: optionally bundle font+size before drawing.
function Ctx:text(s, font, size)
    if font then self._lib.cairo_select_font_face(self._cr, font, 0, 0) end
    if size then self._lib.cairo_set_font_size(self._cr, size) end
    self._lib.cairo_show_text(self._cr, s)
    return self
end
function Ctx:text_extents(s)
    local out = ffi.new("cairo_text_extents_t")
    self._lib.cairo_text_extents(self._cr, s, out)
    return {
        x_bearing = out.x_bearing, y_bearing = out.y_bearing,
        width     = out.width,     height    = out.height,
        x_advance = out.x_advance, y_advance = out.y_advance,
    }
end

-- Current point.
function Ctx:current_point()
    local L = self._lib
    if L.cairo_has_current_point(self._cr) == 0 then return nil end
    local xp = ffi.new("double[1]"); local yp = ffi.new("double[1]")
    L.cairo_get_current_point(self._cr, xp, yp)
    return tonumber(xp[0]), tonumber(yp[0])
end

-- ===== Surface object ====================================================

local Surface = {}
Surface.__index = Surface

local function wrap_surface(L, ptr, kind, w, h)
    return setmetatable({
        _lib  = L,
        _surf = ffi.gc(ptr, L.cairo_surface_destroy),
        _kind = kind,
        _w    = w,
        _h    = h,
    }, Surface)
end

function Surface:context()
    local L = self._lib
    local cr = L.cairo_create(self._surf)
    if cr == nil then error("cairo: cairo_create returned nil", 2) end
    local ctx = setmetatable({ _lib = L, _cr = ffi.gc(cr, L.cairo_destroy), _surface = self }, Ctx)
    check_status(ctx)
    return ctx
end

function Surface:write_png(path)
    if self._kind ~= "image" then
        error("cairo: write_png only valid on image surfaces (got '" .. self._kind .. "')", 2)
    end
    local rc = self._lib.cairo_surface_write_to_png(self._surf, path)
    if rc ~= 0 then
        local msg = self._lib.cairo_status_to_string(rc)
        error("cairo: write_png: " .. (msg ~= nil and ffi.string(msg) or tostring(rc)), 2)
    end
    return true
end

function Surface:width()  return self._w end
function Surface:height() return self._h end

function Surface:flush()   self._lib.cairo_surface_flush(self._surf);   return self end
function Surface:finish()  self._lib.cairo_surface_finish(self._surf);  return self end
function Surface:status()
    local code = self._lib.cairo_surface_status(self._surf)
    local msg  = self._lib.cairo_status_to_string(code)
    return { code = code, message = msg ~= nil and ffi.string(msg) or "" }
end
function Surface:destroy()
    if self._surf ~= nil then
        self._lib.cairo_surface_destroy(ffi.gc(self._surf, nil))
        self._surf = nil
    end
end

Surface.__gc = Surface.destroy

-- ===== Module entry points ==============================================

function M.image_surface(format, w, h)
    local L = require_lib()
    local enum = format_to_enum(format)
    local s = L.cairo_image_surface_create(enum, w, h)
    if s == nil then error("cairo: cairo_image_surface_create returned nil", 2) end
    return wrap_surface(L, s, "image", w, h)
end

function M.pdf_surface(path, w, h)
    local L = require_lib()
    local s = L.cairo_pdf_surface_create(path, w, h)
    if s == nil then error("cairo: cairo_pdf_surface_create returned nil", 2) end
    return wrap_surface(L, s, "pdf", w, h)
end

function M.svg_surface(path, w, h)
    local L = require_lib()
    local s = L.cairo_svg_surface_create(path, w, h)
    if s == nil then error("cairo: cairo_svg_surface_create returned nil", 2) end
    return wrap_surface(L, s, "svg", w, h)
end

return M
