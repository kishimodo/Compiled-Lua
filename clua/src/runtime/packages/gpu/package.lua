return {
    name        = "gpu",
    version     = "1.0",
    description = "GPU adapter and output enumeration via DXGI (CreateDXGIFactory1 -> EnumAdapters1 -> GetDesc1 / EnumOutputs). Falls back to WMI Win32_VideoController if dxgi.dll cannot be loaded. Best-effort vendor SDK probes (NVML for NVIDIA, ADL for AMD) return nil unless the vendor library is installed.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["gpu"] = "init.lua",
    },
    requires        = { "windows", "windows.com" },
    requires_native = {},
}
