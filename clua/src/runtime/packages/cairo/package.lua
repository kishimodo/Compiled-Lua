return {
    name        = "cairo",
    version     = "1.0",
    description = "Cairo 2D vector graphics bindings via cairo.dll. Surface: image_surface(format, w, h), pdf_surface(path, w, h), svg_surface(path, w, h). Each surface yields a context with a chainable drawing API (move_to / line_to / curve_to / arc / rectangle / close_path, set_source_rgba / set_line_width / set_line_cap / set_line_join / set_dash, stroke / fill / clip / paint, translate / rotate / scale / transform, save / restore, text / set_font_face / set_font_size, status). PNG export via :write_png; PDF and SVG surfaces flush on context :finish or surface destruction. Loads lazily from $LUAVM_CAIRO_DLL or common names.",
    license     = "MIT (bindings), LGPL 2.1 (cairo upstream)",
    main        = "init.lua",
    modules     = {
        ["cairo"] = "init.lua",
    },
    requires        = {},
    requires_native = {
        { dll = "cairo.dll", mode_default = "embed", env_var = "LUAVM_CAIRO_DLL" },
    },
}
