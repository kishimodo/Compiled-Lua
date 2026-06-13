return {
    name        = "mupdf",
    version     = "1.0",
    description = "MuPDF PDF / XPS / EPUB rasterizing bindings via mupdf.dll. Complements our pure-Lua pdf_read (which only parses text) by giving real page rendering to RGB/RGBA/grayscale pixel buffers or directly to PNG. Surface: mupdf.open(path) returns a doc with :page_count, :page(idx), :close; each page exposes :size(), :render(opts) -> {pixels, w, h, channels}, :render_to_png(path, opts), :text(), :close. opts: { scale, dpi, format = 'rgb'|'rgba'|'gray' }. Loads lazily from $CLUA_MUPDF_DLL or common names; calls fz_new_context/drop_context with a singleton context.",
    license     = "MIT (bindings), AGPLv3 (MuPDF upstream)",
    main        = "init.lua",
    modules     = {
        ["mupdf"] = "init.lua",
    },
    requires        = {},
    requires_native = {
        { dll = "mupdf.dll", mode_default = "embed", env_var = "CLUA_MUPDF_DLL" },
    },
}
