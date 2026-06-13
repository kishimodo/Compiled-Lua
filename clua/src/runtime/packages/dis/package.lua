return {
    name        = "dis",
    version     = "1.0",
    description = "x86 / x86-64 disassembler with BOTH Capstone AND Zydis backends. Each backend is probed independently via ffi.load; the caller picks via dis.new{backend='capstone'|'zydis'|'auto'}. Returns an iterator (or array) of {address, mnemonic, op_str, bytes, size} per decoded instruction. Falls back to whichever backend is present if the requested one isn't loaded; raises with a clear DLL-missing message when neither is available. Env overrides: CLUA_CAPSTONE_DLL / CLUA_ZYDIS_DLL.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["dis"] = "init.lua",
    },
    requires        = {},
    requires_native = {
        { dll = "capstone.dll", mode_default = "embed",
          env_var = "CLUA_CAPSTONE_DLL",
          alternatives = { "capstone-5.dll", "capstone" } },
        { dll = "Zydis.dll", mode_default = "embed",
          env_var = "CLUA_ZYDIS_DLL",
          alternatives = { "zydis.dll", "zydis" } },
    },
}
