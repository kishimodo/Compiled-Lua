return {
    name        = "proc",
    version     = "1.0",
    description = "Process / thread / module / handle / token enumeration. Wraps Toolhelp32 snapshots, NtQuerySystemInformation(SystemHandleInformation), and OpenProcessToken + GetTokenInformation. Builds parent/child process trees, lists loaded modules with their base addresses, enumerates threads with their entry points, dumps open handles per-PID, and decodes token user/groups/privileges. Pure-Lua wrappers over windows / windows.toolhelp / windows.ntdll / windows.security.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["proc"] = "init.lua",
    },
    requires        = { "windows", "windows.toolhelp", "windows.ntdll", "windows.security", "windows.psapi" },
    requires_native = {},
}
