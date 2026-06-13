return {
    name        = "asm",
    version     = "1.0",
    description = "Keystone-backed assembler: x86 / x86-64 / arm / arm64. Loads keystone.dll (or keystone-0.dll) and exposes ks_open, ks_asm, ks_free, ks_close through ffi. Returns a Lua string of assembled bytes plus the instruction count. Designed so the compiler can ship the DLL embedded / sidecar / system once the runtime native-mode plumbing is wired up.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["asm"] = "init.lua",
    },
    requires        = {},
    requires_native = {
        { dll = "keystone.dll", mode_default = "embed",
          env_var = "CLUA_KEYSTONE_DLL",
          alternatives = { "keystone-0.dll", "keystone" } },
    },
}
