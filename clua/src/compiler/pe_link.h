/*!
 * @brief
 *  Wrap a CLUA blob as a PE-COFF object via objcopy, then link or archive
 *  it with the runtime + Lua into one of several output formats.
 */

#ifndef CLUA_COMPILER_PE_LINK_H
#define CLUA_COMPILER_PE_LINK_H

#include <stddef.h>

typedef enum {
    PE_OUT_EXE  = 0,   /* default: PE executable */
    PE_OUT_DLL,        /* PE dynamic-link library; exports clua_run() */
    PE_OUT_OBJ,        /* just the blob wrapped as a .o (no runtime) */
    PE_OUT_LIB,        /* static archive: blob.o + runtime.a + liblua54.a */
    PE_OUT_BLOB,       /* raw blob bytes (no objcopy, no linker) */
} PE_OUTPUT_TYPE_T;

typedef struct _PE_LINK_OPTS {
    const char       *ObjCopyExe;     /* "objcopy" by default */
    const char       *CcExe;          /* "x86_64-w64-mingw32-gcc" by default */
    const char       *CxxExe;         /* "x86_64-w64-mingw32-g++" by default; used when ImguiArchive set */
    const char       *ArExe;          /* "ar" by default */
    const char       *RuntimeArchive; /* path to runtime.a (exe/dll/lib) */
    const char       *LuaArchive;     /* path to liblua54.a (exe/dll/lib) */
    const char       *ImguiArchive;   /* path to imgui.a; if set, link via g++ + D3D11/Win32 libs */
    const char       *Subsystem;      /* exe-only: "console" or "windows" */
    PE_OUTPUT_TYPE_T  OutputType;     /* defaults to PE_OUT_EXE */
    /* --randomize: per-build PRNG-driven random ImageBase via
       -Wl,--image-base and random 7-char section names patched into
       the PE section table post-link. */
    int               Randomize;
    /* --rich-header-strip: zero the MSVC Rich header (toolchain
       fingerprint between DOS stub and PE header). mingw doesn't
       emit Rich headers so this is typically a no-op, kept for
       toolchain-swap safety. */
    int               RichHeaderStrip;
    /* --strip: pass -Wl,--strip-all to the linker so the output PE
       carries no .debug_* sections. Previously folded under --mangle;
       now stands alone so callers can strip without also scrubbing the
       DOS stub. */
    int               Strip;
    /* --gc-sections: tells the linker to drop unreferenced functions
       and data. Effective in concert with -ffunction-sections /
       -fdata-sections on the input objects (which the per-build blob.o
       and pkgrefs.o are now compiled with when this flag is set). */
    int               GcSections;
    /* --high-entropy-va: -Wl,--high-entropy-va. Promotes the PE's
       DllCharacteristics IMAGE_DLLCHARACTERISTICS_HIGH_ENTROPY_VA bit
       so the loader uses the full 64-bit ASLR space (8 TB range) for
       this image, not just the 32-bit-compatible 2 GB window. */
    int               HighEntropyVa;
    /* --verify-pe-flags: after linking, re-open the PE and assert the
       expected DllCharacteristics bits are set (DYNAMIC_BASE, NX_COMPAT,
       and HIGH_ENTROPY_VA when --high-entropy-va was requested).
       Emits a clear error if the toolchain silently dropped one. */
    int               VerifyPeFlags;
    /* --stack-protector / --fortify-source / --stack-clash / --cf-protection:
       compile-time hardening for the per-build blob.o + pkgrefs.o.
       Runtime.a stays at the baseline produced by the Makefile; future
       batches add a separately-built `runtime-hardened.a` so these
       flags can cover the whole image. */
    int               StackProtector;
    int               FortifySource;
    int               StackClash;
    int               CfProtection;
    /* --optimize-size / --lto / --no-unwind / --merge-constants: size
       and cross-TU optimization knobs. Compile-time flags apply to
       the per-build blob.o + pkgrefs.o; link-time pieces flow into
       ComposeLinkLineFlags. */
    int               OptimizeSize;
    int               Lto;
    int               NoUnwind;
    int               MergeConstants;
    /* --no-lua-iolib / --no-lua-oslib / --no-lua-dblib: generate a
       custom luaL_openlibs override per build and link it before
       liblua54.a so the linker drops the unreferenced sub-library
       .o members via standard archive resolution. */
    int               NoLuaIolib;
    int               NoLuaOslib;
    int               NoLuaDblib;
    /* --bytecode-only: generates a luaY_parser stub that aborts on
       source loads; the linker then tree-shakes lparser.o + lcode.o
       (since nothing else references them) out of liblua54-embedded.a. */
    int               BytecodeOnly;
    /* --jit-only: generates a luaV_execute stub that aborts on entry;
       the linker drops lvm.o (~80 KB compiled). Risky -- any Lua proto
       the JIT can't compile aborts at first invocation. Opt-in only. */
    int               JitOnly;
    /* Builtin packages required by the program (resolver output).
       Phase 2 tree-shaking: pe_link.c generates a per-build
       packages_refs.c that defines Runtime_GetPackages() listing
       only these names, and adds only the matching _pkg_gen.o files
       to the link line. Set to NULL/0 if no packages are required. */
    char            **BuiltinPackages;
    size_t            BuiltinPackageCount;
    /* Directory containing the per-package _pkg_gen.o files. Defaults
       to "build/bin/obj/runtime/packages". */
    const char       *PackagesObjDir;
    /* Native-embed control: see CLI flags --native-mode,
       --native-mode-for, --native-dir. */
    const char       *NativeMode;     /* "embed" | "sidecar" | "system" (default "embed") */
    const char       *NativeModeFor;  /* "sqlite=sidecar,pcre=system" */
    const char       *NativeDir;      /* default "vendor/native" */
} PE_LINK_OPTS_T, *PPE_LINK_OPTS_T;

/*!
 * @brief
 *  Take an in-memory blob and write OutputPath in the requested format.
 *  Uses a temp .bin + .o file under the OS temp dir for non-blob outputs.
 *
 * @return
 *  1 on success, 0 on failure (writes error to stderr)
 */
int PeLink_Bundle( const unsigned char *Blob,
                   size_t               BlobLen,
                   const char          *OutputPath,
                   PPE_LINK_OPTS_T      Opts );

#endif /* CLUA_COMPILER_PE_LINK_H */
