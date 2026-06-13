return {
    name        = "imgui",
    version     = "0.1",
    description = "Dear ImGui (via cimgui) + Win32/D3D11 host backend",
    license     = "MIT (CLua glue), MIT (Dear ImGui), MIT (cimgui)",
    main        = "init.lua",
    modules     = {
        -- public surface
        ["imgui"]          = "init.lua",     -- main: lifecycle + ergonomic shortcuts
        ["imgui_bindings"] = "bindings.lua", -- auto-generated cimgui surface
        ["imgui_helpers"]  = "helpers.lua",  -- matched-pair scopes, IM_COL32, etc.
    },
    requires        = { "windows" },
    -- imgui needs the cimgui + D3D11 + Win32 native archive linked in;
    -- compiler/resolve.c keys on this name today.
    requires_native = { "imgui" },
}
