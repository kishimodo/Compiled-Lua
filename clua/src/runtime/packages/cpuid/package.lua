return {
    name        = "cpuid",
    version     = "1.0",
    description = "x86 / x86-64 CPUID feature detection. Allocates an RWX trampoline via VirtualAlloc, copies a tiny CPUID stub (mov eax/ecx; cpuid; spill four registers; ret), and calls it through a typed function pointer. Decodes vendor / brand / family / model / stepping plus all feature bits we care about (SSE family, AVX/AVX2/AVX512, BMI1/2, AES, RDRAND, RDSEED, SHA, FMA, POPCNT, ...) and L1/L2/L3 cache sizes from leaf 0x80000006 / 0x4.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["cpuid"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
