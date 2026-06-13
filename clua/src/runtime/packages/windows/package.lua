-- CLua package manifest. Consumed by tools/gen-package-rules.ps1
-- (the auto-scan generator) and the future package manager. The
-- manifest is authoritative for require-name choice; sub-module files
-- not listed here pick up the default convention "<dir>.<file>".
return {
    name        = "windows",
    version     = "0.3",
    description = "Windows API cdefs and helpers. The main module ships the kernel32 / user32 / advapi32 / ntdll / msvcrt baseline plus shared primitive typedefs (BOOL, HANDLE, DWORD, ...). Larger or domain-specific surfaces (CNG crypto, COM, networking, dbghelp, etc.) live in sub-packages so callers pay only for what they require.",
    license     = "MIT",
    main        = "init.lua",
    -- modules: require()-name -> path-inside-package. Sub-modules use
    -- Lua dot notation (windows.bcrypt, windows.com, ...) so a
    -- `require "windows.bcrypt"` returns just the CNG cdefs without
    -- pulling in the rest of the windows surface.
    modules     = {
        ["windows"]            = "init.lua",
        -- Hand-curated sub-packages
        ["windows.bcrypt"]     = "bcrypt.lua",
        ["windows.com"]        = "com.lua",
        ["windows.dbghelp"]    = "dbghelp.lua",
        ["windows.network"]    = "network.lua",
        ["windows.ntdll"]      = "ntdll.lua",
        ["windows.psapi"]      = "psapi.lua",
        ["windows.security"]   = "security.lua",
        ["windows.shell"]      = "shell.lua",
        ["windows.toolhelp"]   = "toolhelp.lua",
        -- winmd-gen-derived sub-packages (Win32 namespaces). Each
        -- mirrors a Windows.Win32.<area> namespace's full
        -- function / struct / enum / constant set, comparable in
        -- coverage to Rust's winapi crate or Go's x/sys/windows.
        ["windows.threading"]   = "threading.lua",     -- System.Threading                (337 fns)
        ["windows.filesystem"]  = "filesystem.lua",    -- Storage.FileSystem              (412 fns)
        ["windows.memory"]      = "memory.lua",        -- System.Memory                   (104 fns)
        ["windows.registry"]    = "registry.lua",      -- System.Registry                 ( 83 fns)
        ["windows.sysinfo"]     = "sysinfo.lua",       -- System.SystemInformation        ( 63 fns)
        ["windows.console"]     = "console.lua",       -- System.Console                  ( 95 fns)
        ["windows.services"]    = "services.lua",      -- System.Services                 ( 58 fns)
        ["windows.pipes"]       = "pipes.lua",         -- System.Pipes                    ( 22 fns)
        ["windows.winsock"]     = "winsock.lua",       -- Networking.WinSock              (203 fns)
        ["windows.winhttp"]     = "winhttp.lua",       -- Networking.WinHttp              ( 56 fns)
        ["windows.debug"]       = "debug.lua",         -- System.Diagnostics.Debug        (325 fns)
        ["windows.ui_msg"]      = "ui_msg.lua",        -- UI.WindowsAndMessaging          (416 fns)
        ["windows.input"]       = "input.lua",         -- UI.Input.KeyboardAndMouse       ( 52 fns)
        ["windows.loader"]      = "loader.lua",        -- System.LibraryLoader            ( 49 fns)
        ["windows.programming"] = "programming.lua",   -- System.WindowsProgramming       (213 fns)
        ["windows.auth"]        = "auth.lua",          -- Security.Authentication.Identity(216 fns)
        ["windows.gdi"]         = "gdi.lua",           -- Graphics.Gdi                    (396 fns)
        ["windows.power"]       = "power.lua",         -- System.Power                    ( 97 fns)
    },
    -- depends on other CLua packages (none -- this is foundational)
    requires        = {},
    -- DLL link-line additions when this package is required.
    -- Compiler resolver currently only acts on requires_native = "imgui";
    -- this field is informational for future use.
    requires_native = {},
}
