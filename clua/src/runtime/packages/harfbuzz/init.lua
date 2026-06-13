-- harfbuzz -- HarfBuzz text shaping bindings.
--
-- Public surface:
--   harfbuzz.available()            -- true if harfbuzz.dll loaded
--   harfbuzz.version()              -- "x.y.z"
--   harfbuzz.face(path_or_bytes)    -> face   (path: file; bytes: raw font data)
--   harfbuzz.language(code)         -> language tag handle (cached)
--   harfbuzz.script(four_cc)        -> script tag handle (e.g. "latn", "arab")
--
-- face:
--   :font(size?)                    -> font    (size in font units; default 1024)
--   :destroy()
--
-- font:
--   :shape(text, opts?)             -> list of {
--                                          glyph_id, cluster,
--                                          x_offset, y_offset,
--                                          x_advance, y_advance,
--                                          codepoint
--                                      }
--     opts: {
--       script    = "latn",                 -- 4-char ISO 15924 tag
--       language  = "en",
--       direction = "ltr"|"rtl"|"ttb"|"btt" (default "ltr"),
--       features  = { "liga", "kern", "-liga", "frac" }
--     }
--   :set_size(size)
--   :destroy()
--
-- Notes:
--   * HarfBuzz returns glyph cluster info that maps back to byte offsets
--     in the input string -- preserved verbatim in the result table.
--   * Font units default to 1024 (the HB default upem); for pixel
--     rendering set size to your target px.

local M = {}

ffi.cdef[[
typedef struct hb_blob_t        hb_blob_t;
typedef struct hb_face_t        hb_face_t;
typedef struct hb_font_t        hb_font_t;
typedef struct hb_buffer_t      hb_buffer_t;
typedef struct hb_unicode_funcs hb_unicode_funcs_t;
typedef int                     hb_bool_t;
typedef unsigned int            hb_codepoint_t;
typedef unsigned int            hb_position_t;
typedef unsigned int            hb_mask_t;
typedef unsigned int            hb_tag_t;
typedef const void             *hb_language_t;

typedef struct {
    hb_codepoint_t codepoint;
    hb_mask_t      mask;
    unsigned int   cluster;
    unsigned int   var1;
    unsigned int   var2;
} hb_glyph_info_t;

typedef struct {
    hb_position_t x_advance;
    hb_position_t y_advance;
    hb_position_t x_offset;
    hb_position_t y_offset;
    unsigned int  var;
} hb_glyph_position_t;

typedef struct {
    hb_tag_t     tag;
    unsigned int value;
    unsigned int start;
    unsigned int end_;
} hb_feature_t;

typedef enum {
    HB_DIRECTION_INVALID = 0,
    HB_DIRECTION_LTR     = 4,
    HB_DIRECTION_RTL     = 5,
    HB_DIRECTION_TTB     = 6,
    HB_DIRECTION_BTT     = 7
} hb_direction_t;

typedef enum {
    HB_MEMORY_MODE_DUPLICATE          = 0,
    HB_MEMORY_MODE_READONLY           = 1,
    HB_MEMORY_MODE_WRITABLE           = 2,
    HB_MEMORY_MODE_READONLY_MAY_MAKE_WRITABLE = 3
} hb_memory_mode_t;

const char *hb_version_string(void);
void        hb_version(unsigned int *major, unsigned int *minor, unsigned int *micro);

hb_blob_t  *hb_blob_create(const char *data, unsigned int length,
                           hb_memory_mode_t mode, void *user_data, void *destroy);
hb_blob_t  *hb_blob_create_from_file(const char *file_name);
void        hb_blob_destroy(hb_blob_t *blob);

hb_face_t  *hb_face_create(hb_blob_t *blob, unsigned int index);
void        hb_face_destroy(hb_face_t *face);
unsigned int hb_face_get_upem(const hb_face_t *face);
unsigned int hb_face_get_glyph_count(const hb_face_t *face);

hb_font_t  *hb_font_create(hb_face_t *face);
void        hb_font_destroy(hb_font_t *font);
void        hb_font_set_scale(hb_font_t *font, int x_scale, int y_scale);
void        hb_font_set_ppem(hb_font_t *font, unsigned int x_ppem, unsigned int y_ppem);
void        hb_ot_font_set_funcs(hb_font_t *font);

hb_buffer_t *hb_buffer_create(void);
void         hb_buffer_destroy(hb_buffer_t *buffer);
void         hb_buffer_reset(hb_buffer_t *buffer);
void         hb_buffer_clear_contents(hb_buffer_t *buffer);
void         hb_buffer_add_utf8(hb_buffer_t *buffer, const char *text,
                                int text_length, unsigned int item_offset, int item_length);
void         hb_buffer_set_direction(hb_buffer_t *buffer, hb_direction_t direction);
void         hb_buffer_set_script(hb_buffer_t *buffer, hb_tag_t script);
void         hb_buffer_set_language(hb_buffer_t *buffer, hb_language_t lang);
hb_bool_t    hb_buffer_guess_segment_properties(hb_buffer_t *buffer);
unsigned int hb_buffer_get_length(hb_buffer_t *buffer);
hb_glyph_info_t     *hb_buffer_get_glyph_infos(hb_buffer_t *buffer, unsigned int *length);
hb_glyph_position_t *hb_buffer_get_glyph_positions(hb_buffer_t *buffer, unsigned int *length);

void hb_shape(hb_font_t *font, hb_buffer_t *buffer,
              const hb_feature_t *features, unsigned int num_features);

hb_tag_t      hb_tag_from_string(const char *str, int len);
hb_language_t hb_language_from_string(const char *str, int len);
const char   *hb_language_to_string(hb_language_t lang);

hb_bool_t hb_feature_from_string(const char *str, int len, hb_feature_t *feature);
]]

-- ===== Direction enums ===================================================

M.DIRECTION_LTR = 4
M.DIRECTION_RTL = 5
M.DIRECTION_TTB = 6
M.DIRECTION_BTT = 7

-- ===== Lazy DLL loader ===================================================

local _lib, _load_err

local function load_lib()
    if _lib then return _lib end
    if _load_err then return nil end
    local names = {}
    local env_dll = os.getenv("CLUA_HARFBUZZ_DLL")
    if env_dll and #env_dll > 0 then names[#names + 1] = env_dll end
    names[#names + 1] = "harfbuzz"
    names[#names + 1] = "harfbuzz.dll"
    names[#names + 1] = "libharfbuzz"
    names[#names + 1] = "libharfbuzz-0.dll"
    for _, n in ipairs(names) do
        local ok, lib = pcall(ffi.load, n)
        if ok then _lib = lib; return lib end
    end
    _load_err = "harfbuzz: harfbuzz.dll not found. "
        .. "Set CLUA_HARFBUZZ_DLL or drop harfbuzz.dll next to CLua."
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
    local s = L.hb_version_string()
    return s ~= nil and ffi.string(s) or "?"
end

-- ===== Tag / language helpers ============================================

function M.script(tag)
    local L = require_lib()
    if type(tag) ~= "string" or #tag ~= 4 then
        error("harfbuzz.script: expected 4-char tag (e.g. 'latn')", 2)
    end
    return tonumber(L.hb_tag_from_string(tag, 4))
end

local _lang_cache = {}
function M.language(code)
    local L = require_lib()
    if _lang_cache[code] then return _lang_cache[code] end
    local h = L.hb_language_from_string(code, #code)
    _lang_cache[code] = h
    return h
end

local function direction_to_enum(s)
    if s == "ltr" or s == nil then return M.DIRECTION_LTR end
    if s == "rtl" then return M.DIRECTION_RTL end
    if s == "ttb" then return M.DIRECTION_TTB end
    if s == "btt" then return M.DIRECTION_BTT end
    error("harfbuzz: unknown direction '" .. tostring(s) .. "'", 3)
end

-- ===== Font object =======================================================

local Font = {}
Font.__index = Font

local function read_file_bytes(path)
    local f, err = io.open(path, "rb")
    if not f then error("harfbuzz.face: cannot open '" .. tostring(path) .. "': " .. tostring(err), 3) end
    local s = f:read("*a")
    f:close()
    return s
end

-- Heuristic: bytes that look like a font (TrueType / OpenType / WOFF
-- start with one of a few magic numbers) get passed through verbatim;
-- everything else is treated as a filesystem path.
local function looks_like_font_bytes(s)
    if type(s) ~= "string" or #s < 4 then return false end
    local b1, b2, b3, b4 = s:byte(1, 4)
    -- TTF: 00 01 00 00, OTF: "OTTO", TTC: "ttcf", WOFF: "wOFF"
    if b1 == 0 and b2 == 1 and b3 == 0 and b4 == 0 then return true end
    if s:sub(1, 4) == "OTTO" or s:sub(1, 4) == "ttcf"
       or s:sub(1, 4) == "wOFF" or s:sub(1, 4) == "wOF2" then return true end
    return false
end

local function build_features(L, list)
    if list == nil then return nil, 0 end
    local n = #list
    if n == 0 then return nil, 0 end
    local arr = ffi.new("hb_feature_t[?]", n)
    for i, str in ipairs(list) do
        if L.hb_feature_from_string(str, #str, arr + (i - 1)) == 0 then
            error("harfbuzz: bad feature string '" .. tostring(str) .. "'", 3)
        end
    end
    return arr, n
end

function Font:shape(text, opts)
    opts = opts or {}
    local L = self._lib
    local buf = L.hb_buffer_create()
    if buf == nil then error("harfbuzz: hb_buffer_create returned nil", 2) end
    buf = ffi.gc(buf, L.hb_buffer_destroy)
    L.hb_buffer_add_utf8(buf, text, #text, 0, -1)
    L.hb_buffer_set_direction(buf, direction_to_enum(opts.direction))
    if opts.script then
        L.hb_buffer_set_script(buf, L.hb_tag_from_string(opts.script, #opts.script))
    end
    if opts.language then
        local lang = L.hb_language_from_string(opts.language, #opts.language)
        L.hb_buffer_set_language(buf, lang)
    end
    -- Fill in any unset properties from the text (script auto-detect, etc.)
    L.hb_buffer_guess_segment_properties(buf)
    local feats_arr, feats_n = build_features(L, opts.features)
    L.hb_shape(self._font, buf, feats_arr, feats_n)
    local n_p   = ffi.new("unsigned int[1]")
    local infos = L.hb_buffer_get_glyph_infos(buf, n_p)
    local poss  = L.hb_buffer_get_glyph_positions(buf, n_p)
    local n     = tonumber(n_p[0])
    local out   = {}
    for i = 0, n - 1 do
        out[i + 1] = {
            glyph_id  = tonumber(infos[i].codepoint),
            codepoint = tonumber(infos[i].codepoint),  -- alias
            cluster   = tonumber(infos[i].cluster),
            x_advance = tonumber(poss[i].x_advance),
            y_advance = tonumber(poss[i].y_advance),
            x_offset  = tonumber(poss[i].x_offset),
            y_offset  = tonumber(poss[i].y_offset),
        }
    end
    return out
end

function Font:set_size(size)
    local sz = math.floor(size + 0.5)
    self._lib.hb_font_set_scale(self._font, sz, sz)
    return self
end

function Font:destroy()
    if self._font ~= nil then
        self._lib.hb_font_destroy(ffi.gc(self._font, nil))
        self._font = nil
    end
end

Font.__gc = Font.destroy

-- ===== Face object =======================================================

local Face = {}
Face.__index = Face

function Face:font(size)
    local L = self._lib
    local f = L.hb_font_create(self._face)
    if f == nil then error("harfbuzz: hb_font_create returned nil", 2) end
    f = ffi.gc(f, L.hb_font_destroy)
    -- Wire up the OpenType shaper -- without this most glyph_position
    -- values come back zeroed because HB falls through to the no-op
    -- default funcs.
    pcall(function() L.hb_ot_font_set_funcs(f) end)
    local sz = math.floor((size or 1024) + 0.5)
    L.hb_font_set_scale(f, sz, sz)
    return setmetatable({ _lib = L, _font = f, _face = self }, Font)
end

function Face:upem()
    return tonumber(self._lib.hb_face_get_upem(self._face))
end

function Face:glyph_count()
    return tonumber(self._lib.hb_face_get_glyph_count(self._face))
end

function Face:destroy()
    if self._face ~= nil then
        self._lib.hb_face_destroy(ffi.gc(self._face, nil))
        self._face = nil
    end
    if self._blob ~= nil then
        self._lib.hb_blob_destroy(ffi.gc(self._blob, nil))
        self._blob = nil
    end
end

Face.__gc = Face.destroy

-- ===== Module entry: face(path_or_bytes) =================================

function M.face(path_or_bytes, index)
    local L = require_lib()
    local blob
    local owned_bytes  -- keep the Lua string alive for the blob's lifetime
    if looks_like_font_bytes(path_or_bytes) then
        owned_bytes = path_or_bytes
        blob = L.hb_blob_create(owned_bytes, #owned_bytes, 1, nil, nil)  -- READONLY mode
    else
        -- Filesystem path; try the upstream loader, fall back to reading
        -- via Lua io for paths HarfBuzz's loader can't see (e.g. UNC).
        blob = L.hb_blob_create_from_file(path_or_bytes)
        if blob == nil or L.hb_blob_create == nil then
            owned_bytes = read_file_bytes(path_or_bytes)
            blob = L.hb_blob_create(owned_bytes, #owned_bytes, 1, nil, nil)
        end
    end
    if blob == nil then
        error("harfbuzz.face: failed to create blob", 2)
    end
    blob = ffi.gc(blob, L.hb_blob_destroy)
    local face = L.hb_face_create(blob, index or 0)
    if face == nil then
        error("harfbuzz.face: hb_face_create returned nil", 2)
    end
    face = ffi.gc(face, L.hb_face_destroy)
    return setmetatable({
        _lib   = L,
        _face  = face,
        _blob  = ffi.gc(blob, nil),  -- transfer GC ownership into self
        _bytes = owned_bytes,
    }, Face)
end

return M
