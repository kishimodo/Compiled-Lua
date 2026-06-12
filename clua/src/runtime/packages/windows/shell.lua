-- windows.shell -- shell32: ShellExecute, special folder paths.
local W = require "windows"

ffi.cdef[[
LONGLONG ShellExecuteW(HWND, LPCWSTR, LPCWSTR, LPCWSTR, LPCWSTR, int);
LONGLONG ShellExecuteA(HWND, LPCSTR, LPCSTR, LPCSTR, LPCSTR, int);
BOOL     SHGetSpecialFolderPathW(HWND, LPWSTR, int, BOOL);
BOOL     SHGetSpecialFolderPathA(HWND, LPSTR, int, BOOL);
]]
pcall(ffi.load, "shell32")

return {
    -- CSIDL_* (folder identifiers for SHGetSpecialFolderPath)
    CSIDL_DESKTOP          = 0x0000,
    CSIDL_PROGRAMS         = 0x0002,
    CSIDL_PERSONAL         = 0x0005,
    CSIDL_FAVORITES        = 0x0006,
    CSIDL_STARTUP          = 0x0007,
    CSIDL_RECENT           = 0x0008,
    CSIDL_DESKTOPDIRECTORY = 0x0010,
    CSIDL_FONTS            = 0x0014,
    CSIDL_APPDATA          = 0x001A,
    CSIDL_LOCAL_APPDATA    = 0x001C,
    CSIDL_WINDOWS          = 0x0024,
    CSIDL_SYSTEM           = 0x0025,
    CSIDL_PROGRAM_FILES    = 0x0026,
    CSIDL_COMMON_APPDATA   = 0x0023,
    CSIDL_PROFILE          = 0x0028,
    -- ShellExecute show commands (mirror SW_* in user32)
    SW_HIDE            = 0,
    SW_SHOWNORMAL      = 1,
    SW_SHOWMINIMIZED   = 2,
    SW_SHOWMAXIMIZED   = 3,
}
