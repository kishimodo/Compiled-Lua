-- CLua notify_toast package manifest.
return {
    name        = "notify_toast",
    version     = "0.1",
    description = "Modern Windows toast notifications via the WinRT Windows.UI.Notifications stack. Activates ToastNotificationManager.CreateToastNotifierWithId, builds a XML payload (title/body/image/audio/actions/scenario), and submits an IToastNotification. Tracks tag/group identifiers so callers can dismiss or replace individual toasts. Falls back to a Shell_NotifyIcon balloon if WinRT activation fails (locked-down hosts or pre-Win10).",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["notify_toast"] = "init.lua",
    },
    requires        = { "windows", "windows.com" },
    requires_native = {},
}
