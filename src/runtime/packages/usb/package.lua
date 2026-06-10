return {
    name        = "usb",
    version     = "1.0",
    description = "USB device enumeration via SetupAPI. Walks the USB device interface class, reads VID/PID/manufacturer/product/serial from device registry properties, classifies hubs vs. devices, and offers find()/by_class() lookups. Includes a small built-in USB vendor-name lookup table for common VIDs.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["usb"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
