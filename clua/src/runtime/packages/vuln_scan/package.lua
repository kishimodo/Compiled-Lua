return {
    name        = "vuln_scan",
    version     = "1.0",
    description = "Pattern scanner for vulnerability signatures and unsafe code patterns in a live process or a raw byte buffer. Built-in pattern library covers x64 syscall stubs (mov r10,rcx; mov eax,SSN; syscall), shellcode-egg sentinels, VEH handler bodies, hook jump trampolines, indirect-call gadgets, ROP-friendly ret/jmp endings, common stack-pivot sequences, and a few CVE-implementation fingerprints. Pure-Lua scanner; uses the `mem` package for live-process scans.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["vuln_scan"] = "init.lua",
    },
    requires        = {},
    requires_native = {},
}
