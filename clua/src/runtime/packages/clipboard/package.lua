-- CLua clipboard package manifest.
return {
    name        = "clipboard",
    version     = "0.1",
    description = "Windows clipboard read/write -- text (CF_UNICODETEXT), HTML (CF_HTML w/ header), files (CF_HDROP), and image (CF_DIB / CF_BITMAP as BGRA). Uses user32 OpenClipboard / GetClipboardData / SetClipboardData + kernel32 GlobalAlloc / GlobalLock.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["clipboard"] = "init.lua",
    },
    -- Foundational windows cdefs (HANDLE / DWORD / LPCWSTR / etc.) are
    -- assumed available; we extend with the clipboard-specific surface.
    requires        = { "windows" },
    requires_native = {},
}
