# LuaVM build script. Run from the project root: `make -f build/Makefile <target>`
# or via `build/build.bat`.

# Force cmd.exe as the recipe shell. Every recipe here is cmd syntax
# (`if not exist`, `mkdir`, `rmdir /S /Q`, `mklink /J`), and the package
# `powershell ...` calls invoke powershell.exe explicitly so they run fine
# under cmd too. Pinning this also sidesteps the documented hazard where a
# bash SHELL pre-expands `$_` in package discovery and spews
# `'x86' is not recognized` noise on every build.
SHELL       := cmd.exe

CC          := x86_64-w64-mingw32-gcc
AR          := ar
OBJCOPY     := objcopy
LD          := x86_64-w64-mingw32-ld

ROOT        := .
BUILD_DIR   := $(ROOT)/build/bin
SRC_DIR     := $(ROOT)/clua/src
LUA_DIR     := $(ROOT)/lua-5.4/src

CFLAGS      := -std=c99 -Wall -Wextra -Wno-unused-parameter -O2 -g
CFLAGS      += -I$(SRC_DIR) -I$(LUA_DIR) -I$(ROOT)/build/gen
CFLAGS      += -DCLUA_TARGET_WINDOWS_X64=1

.PHONY: all clean help
all: help

help:
	@echo "LuaVM build targets:"
	@echo "  make compiler   - build compiler.exe"
	@echo "  make runtime    - build runtime.a"
	@echo "  make runluac    - build runluac.exe (M2 scaffolding)"
	@echo "  make test       - build and run unit tests"
	@echo "  make clean      - remove build artefacts"

clean:
	-if exist "$(BUILD_DIR)" rmdir /S /Q "$(BUILD_DIR)"

# --- vendored Lua 5.4 ------------------------------------------------------

# Lua core objects (everything except `lua.c` and `luac.c`, which are the
# upstream CLI binaries we don't ship).
LUA_CORE_SRCS := \
    $(LUA_DIR)/lapi.c     $(LUA_DIR)/lcode.c    $(LUA_DIR)/lctype.c  \
    $(LUA_DIR)/ldebug.c   $(LUA_DIR)/ldo.c      $(LUA_DIR)/ldump.c   \
    $(LUA_DIR)/lfunc.c    $(LUA_DIR)/lgc.c      $(LUA_DIR)/llex.c    \
    $(LUA_DIR)/lmem.c     $(LUA_DIR)/lobject.c  $(LUA_DIR)/lopcodes.c\
    $(LUA_DIR)/lparser.c  $(LUA_DIR)/lstate.c   $(LUA_DIR)/lstring.c \
    $(LUA_DIR)/ltable.c   $(LUA_DIR)/ltm.c      $(LUA_DIR)/lundump.c \
    $(LUA_DIR)/lvm.c      $(LUA_DIR)/lzio.c
LUA_LIB_SRCS  := \
    $(LUA_DIR)/lauxlib.c  $(LUA_DIR)/lbaselib.c $(LUA_DIR)/lcorolib.c\
    $(LUA_DIR)/ldblib.c   $(LUA_DIR)/liolib.c   $(LUA_DIR)/lmathlib.c\
    $(LUA_DIR)/loadlib.c  $(LUA_DIR)/loslib.c   $(LUA_DIR)/lstrlib.c \
    $(LUA_DIR)/ltablib.c  $(LUA_DIR)/lutf8lib.c $(LUA_DIR)/linit.c
LUA_OBJS := $(patsubst $(LUA_DIR)/%.c,$(BUILD_DIR)/lua/%.o,$(LUA_CORE_SRCS) $(LUA_LIB_SRCS))
LUA_CFLAGS := -DLUA_USE_WINDOWS -DLUA_COMPAT_5_3

$(BUILD_DIR)/lua/%.o: $(LUA_DIR)/%.c | $(BUILD_DIR)/lua
	$(CC) $(CFLAGS) $(LUA_CFLAGS) -c $< -o $@

$(BUILD_DIR)/liblua54.a: $(LUA_OBJS)
	$(AR) rcs $@ $^

.PHONY: lua
lua: $(BUILD_DIR)/lua $(BUILD_DIR)/liblua54.a

$(BUILD_DIR)/lua:
	if not exist "$(BUILD_DIR)\lua" mkdir "$(BUILD_DIR)\lua"

# --- Lua 5.4 -- embedded variant (size-tuned) ----------------------------
# Same source set as above, compiled with -Os -g0 and hardening defaults
# so every compiler-emitted PE inherits them.
# NOTE (2026-06-12, measured): -D__USE_MINGW_ANSI_STDIO=0 would drop MinGW's
# static printf/float machinery (__mingw_pformat + gdtoa + strtodg, ~36 KB
# per emitted exe) by resolving printf to the ucrt — but the ucrt renders NaN
# as "-nan(ind)" where the oracle's MinGW stdio prints "nan", a real fidelity
# break caught by tests/differential/aot_strformat.lua. Do not flip this
# without that differential staying green.
EMBEDDED_LUA_CFLAGS := -std=c99 -Wall -Wextra -Wno-unused-parameter \
    -Os -g0 -ffunction-sections -fdata-sections \
    -fno-asynchronous-unwind-tables -fno-unwind-tables \
    -fmerge-all-constants -fmerge-constants \
    -fstack-protector-strong -fcf-protection=full \
    -I$(SRC_DIR) -I$(LUA_DIR) -I$(ROOT)/build/gen \
    -DCLUA_TARGET_WINDOWS_X64=1 \
    -DLUA_USE_WINDOWS -DLUA_COMPAT_5_3

LUA_EMB_OBJS := $(patsubst $(LUA_DIR)/%.c,$(BUILD_DIR)/lua-emb/%.o,$(LUA_CORE_SRCS) $(LUA_LIB_SRCS))

$(BUILD_DIR)/lua-emb:
	if not exist "$(BUILD_DIR)\lua-emb" mkdir "$(BUILD_DIR)\lua-emb"

$(BUILD_DIR)/lua-emb/%.o: $(LUA_DIR)/%.c | $(BUILD_DIR)/lua-emb
	$(CC) $(EMBEDDED_LUA_CFLAGS) -c $< -o $@

$(BUILD_DIR)/liblua54-embedded.a: $(LUA_EMB_OBJS)
	$(AR) rcs $@ $^

# Interpreter-free lvm for AOT exes whose closed-world scan proves no "debug"
# reference: CLUA_NO_INTERP compiles out the bytecode interpreter loop
# (clua_Interpret) while keeping every luaV_* helper. pe_link_v2.c places
# this object before liblua54-embedded.a so its lvm.o is never extracted.
$(BUILD_DIR)/lvm_nointerp.o: $(LUA_DIR)/lvm.c
	$(CC) $(EMBEDDED_LUA_CFLAGS) -DCLUA_NO_INTERP=1 -c $< -o $@

.PHONY: lua-embedded
lua-embedded: $(BUILD_DIR)/lua-emb $(BUILD_DIR)/liblua54-embedded.a $(BUILD_DIR)/lvm_nointerp.o

# --- compiler --------------------------------------------------------------

COMPILER_SRCS := \
    $(SRC_DIR)/compiler/main.c        \
    $(SRC_DIR)/compiler/paths.c       \
    $(SRC_DIR)/compiler/blob.c        \
    $(SRC_DIR)/compiler/lua_compile.c \
    $(SRC_DIR)/compiler/pe_link.c     \
    $(SRC_DIR)/compiler/diag.c        \
    $(SRC_DIR)/compiler/resolve.c
COMPILER_OBJS := $(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/obj/%.o,$(COMPILER_SRCS))

# --- LuaC AOT backend objects (src/{ir,opt,codegen,link,driver}) -----------
# Compiled into build/bin/obj/<subdir>/*.o by the generic pattern rule below
# and scanned into libcluatest.a by tools/run-tests.lua so C-unit tests can
# link against backend code. Built as a side effect of `make test`.
LUAC_SRCS := $(wildcard $(SRC_DIR)/ir/*.c) $(wildcard $(SRC_DIR)/opt/*.c) \
             $(wildcard $(SRC_DIR)/codegen/*.c) $(wildcard $(SRC_DIR)/link/*.c) \
             $(wildcard $(SRC_DIR)/driver/*.c)
LUAC_OBJS := $(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/obj/%.o,$(LUAC_SRCS))
.PHONY: luac-objs
luac-objs: $(LUAC_OBJS)

$(BUILD_DIR)/obj/%.o: $(SRC_DIR)/%.c | $(BUILD_DIR)/obj/compiler $(BUILD_DIR)/obj/runtime $(BUILD_DIR)/obj/tools $(BUILD_DIR)/obj/jit $(BUILD_DIR)/obj/ffi $(BUILD_DIR)/obj/ir $(BUILD_DIR)/obj/opt $(BUILD_DIR)/obj/codegen $(BUILD_DIR)/obj/link $(BUILD_DIR)/obj/driver
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/obj/compiler:
	if not exist "$(BUILD_DIR)\obj\compiler" mkdir "$(BUILD_DIR)\obj\compiler"

$(BUILD_DIR)/obj/runtime:
	if not exist "$(BUILD_DIR)\obj\runtime" mkdir "$(BUILD_DIR)\obj\runtime"

$(BUILD_DIR)/obj/tools:
	if not exist "$(BUILD_DIR)\obj\tools" mkdir "$(BUILD_DIR)\obj\tools"

$(BUILD_DIR)/obj/jit:
	if not exist "$(BUILD_DIR)\obj\jit" mkdir "$(BUILD_DIR)\obj\jit"

# --- LuaC AOT backend obj dirs (src/{ir,opt,codegen,link,driver}) ----------
$(BUILD_DIR)/obj/ir:
	if not exist "$(BUILD_DIR)\obj\ir" mkdir "$(BUILD_DIR)\obj\ir"

$(BUILD_DIR)/obj/opt:
	if not exist "$(BUILD_DIR)\obj\opt" mkdir "$(BUILD_DIR)\obj\opt"

$(BUILD_DIR)/obj/codegen:
	if not exist "$(BUILD_DIR)\obj\codegen" mkdir "$(BUILD_DIR)\obj\codegen"

$(BUILD_DIR)/obj/link:
	if not exist "$(BUILD_DIR)\obj\link" mkdir "$(BUILD_DIR)\obj\link"

$(BUILD_DIR)/obj/driver:
	if not exist "$(BUILD_DIR)\obj\driver" mkdir "$(BUILD_DIR)\obj\driver"

$(BUILD_DIR)/compiler.exe: $(COMPILER_OBJS) $(BUILD_DIR)/liblua54.a
	$(CC) $(CFLAGS) -o $@ $(COMPILER_OBJS) $(BUILD_DIR)/liblua54.a -lm

.PHONY: compiler
compiler: $(BUILD_DIR)/compiler.exe

# --- runtime ---------------------------------------------------------------

RUNTIME_SRCS := \
    $(SRC_DIR)/runtime/runtime_init.c     \
    $(SRC_DIR)/runtime/runtime_entry.c    \
    $(SRC_DIR)/runtime/embedded_loader.c  \
    $(SRC_DIR)/runtime/blob_reader.c      \
    $(SRC_DIR)/runtime/coro.c             \
    $(SRC_DIR)/runtime/native_loader.c    \
    $(SRC_DIR)/runtime/protoinit_rt.c     \
    $(SRC_DIR)/jit/exec_mem.c             \
    $(SRC_DIR)/jit/emit_x64.c             \
    $(SRC_DIR)/jit/runtime.c              \
    $(SRC_DIR)/jit/codegen.c              \
    $(SRC_DIR)/jit/dispatch.c             \
    $(SRC_DIR)/jit/regalloc.c             \
    $(SRC_DIR)/jit/codegen_ffi.c          \
    $(SRC_DIR)/ffi/ctype.c                \
    $(SRC_DIR)/ffi/cdecl_lexer.c          \
    $(SRC_DIR)/ffi/cdecl_parser.c         \
    $(SRC_DIR)/ffi/win_types.c            \
    $(SRC_DIR)/ffi/cdata.c                \
    $(SRC_DIR)/ffi/marshal.c              \
    $(SRC_DIR)/ffi/ffi_lib.c             \
    $(SRC_DIR)/ffi/veh.c                 \
    $(SRC_DIR)/ffi/ffi_load.c            \
    $(SRC_DIR)/ffi/ffi_atomics.c         \
    $(SRC_DIR)/ffi/ffi_call.c            \
    $(SRC_DIR)/ffi/ffi_callback.c        \
    $(SRC_DIR)/ffi/ffi_thunk.c
RUNTIME_OBJS := $(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/obj/%.o,$(RUNTIME_SRCS))

# --- runtime -- embedded variant (size + hardening tuned) ---------------
# Same source set, compiled with the embedded CFLAGS so compiler-emitted
# PEs link a debug-stripped + size-optimized + stack-protected runtime
# instead of the host (luavm.exe / test) variant.
# Note: NO -fdata-sections here. The runtime has several MB-scale
# zero-initialized arrays (g_Enums, g_Slots, g_AllTypes in ffi/ctype.c
# and similar) that GCC + mingw demote out of .bss into .data when
# -fdata-sections is on, materializing megabytes of zeros into the
# final PE. -ffunction-sections alone still lets --gc-sections drop
# unused functions; the BSS arrays stay where they belong.
EMBEDDED_RT_CFLAGS := -std=c99 -Wall -Wextra -Wno-unused-parameter \
    -Os -g0 -ffunction-sections \
    -fno-asynchronous-unwind-tables -fno-unwind-tables \
    -fmerge-all-constants -fmerge-constants \
    -fstack-protector-strong -fcf-protection=full \
    -I$(SRC_DIR) -I$(LUA_DIR) -I$(ROOT)/build/gen \
    -DCLUA_TARGET_WINDOWS_X64=1

RUNTIME_EMB_OBJS := $(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/obj-emb/%.o,$(RUNTIME_SRCS))

$(BUILD_DIR)/obj-emb/runtime:
	if not exist "$(BUILD_DIR)\obj-emb\runtime" mkdir "$(BUILD_DIR)\obj-emb\runtime"
$(BUILD_DIR)/obj-emb/jit:
	if not exist "$(BUILD_DIR)\obj-emb\jit" mkdir "$(BUILD_DIR)\obj-emb\jit"
$(BUILD_DIR)/obj-emb/ffi:
	if not exist "$(BUILD_DIR)\obj-emb\ffi" mkdir "$(BUILD_DIR)\obj-emb\ffi"

$(BUILD_DIR)/obj-emb/%.o: $(SRC_DIR)/%.c | $(BUILD_DIR)/obj-emb/runtime $(BUILD_DIR)/obj-emb/jit $(BUILD_DIR)/obj-emb/ffi
	$(CC) $(EMBEDDED_RT_CFLAGS) -c $< -o $@

$(BUILD_DIR)/runtime-embedded.a: $(RUNTIME_EMB_OBJS)
	$(AR) rcs $@ $^

# --- runtime -- AOT variant (closed-world, no JIT compiler) ----------------
# The archive aotc/clua-emitted PEs link. Same embedded flags plus
# -DLUAC_AOT_RUNTIME, and the JIT code-generator sources (codegen,
# codegen_ffi, emit_x64, regalloc) are excluded entirely: dispatch.c
# compiles cache-side only and jit/runtime.c's tail-call drive loop does a
# lookup instead of compile-if-needed, so nothing references them and a
# shipped exe carries no JIT compiler. luavm.exe and v1 compiler.exe PEs
# keep the full JIT via runtime.a / runtime-embedded.a (unchanged).
AOT_RT_SRCS := $(filter-out \
    $(SRC_DIR)/jit/codegen.c \
    $(SRC_DIR)/jit/codegen_ffi.c \
    $(SRC_DIR)/jit/emit_x64.c \
    $(SRC_DIR)/jit/regalloc.c,$(RUNTIME_SRCS))
AOT_RT_CFLAGS := $(EMBEDDED_RT_CFLAGS) -DLUAC_AOT_RUNTIME=1
RUNTIME_AOT_OBJS := $(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/obj-aot/%.o,$(AOT_RT_SRCS))

$(BUILD_DIR)/obj-aot/runtime:
	if not exist "$(BUILD_DIR)\obj-aot\runtime" mkdir "$(BUILD_DIR)\obj-aot\runtime"
$(BUILD_DIR)/obj-aot/jit:
	if not exist "$(BUILD_DIR)\obj-aot\jit" mkdir "$(BUILD_DIR)\obj-aot\jit"
$(BUILD_DIR)/obj-aot/ffi:
	if not exist "$(BUILD_DIR)\obj-aot\ffi" mkdir "$(BUILD_DIR)\obj-aot\ffi"

$(BUILD_DIR)/obj-aot/%.o: $(SRC_DIR)/%.c | $(BUILD_DIR)/obj-aot/runtime $(BUILD_DIR)/obj-aot/jit $(BUILD_DIR)/obj-aot/ffi
	$(CC) $(AOT_RT_CFLAGS) -c $< -o $@

$(BUILD_DIR)/runtime-aot.a: $(RUNTIME_AOT_OBJS)
	$(AR) rcs $@ $^

.PHONY: runtime-aot
runtime-aot: $(BUILD_DIR)/runtime-aot.a

# Package objects -- embedded variant. Defined later in the Makefile
# (after packages.mk is included and PACKAGE_OBJS is populated) via a
# static pattern rule, since GNU Make has a path-normalization quirk
# that breaks plain pattern rules with leading "./" prefixes.
$(BUILD_DIR)/obj-emb/runtime/packages:
	if not exist "$(BUILD_DIR)\obj-emb\runtime\packages" mkdir "$(BUILD_DIR)\obj-emb\runtime\packages"

.PHONY: runtime-embedded packages-embedded embedded
runtime-embedded: $(BUILD_DIR)/runtime-embedded.a
embedded: lua-embedded runtime-embedded runtime-aot packages-embedded

# --- embedded packages ----------------------------------------------------
# Lua sources under src/runtime/packages/ are compiled into the runtime
# the same way C/C++ includes ship with a toolchain: every output binary
# can `require "windows"` / `require "async"` / etc without a search path
# or extra files. Conceptually these are packages, not "preloads" --
# package.preload is just the registration hook we plug into.
#
# The PACKAGE_* variables, per-package rules, the PACKAGE_OBJS_AUTO
# aggregate, and the matching src/compiler/_builtin_packages.h header
# are all auto-generated from the on-disk layout by
# tools/gen-package-rules.ps1 -- the include directive below pulls in
# the generated fragment, and the rule beneath it regenerates the
# fragment whenever any .lua file in packages/ changes.
GEN_DIR             := $(ROOT)/build/gen
GEN_PACKAGES_MK     := $(GEN_DIR)/packages.mk
GEN_BUILTIN_H       := $(GEN_DIR)/_builtin_packages.h
GEN_NATIVE_DEPS_H   := $(GEN_DIR)/_builtin_native_deps.h
# The lint package's Lua source embedded into compiler.exe as a C byte array,
# so the diagnostics pass (warnings/info) works no matter where compiler.exe
# runs from -- not just from the repo root. Regenerated whenever lint changes.
GEN_LINT_H          := $(GEN_DIR)/_lint_src.h
GEN_LINT_SRC        := $(SRC_DIR)/runtime/packages/lint/init.lua
# Shell-agnostic package-source discovery: a GNU make $(wildcard) works
# identically from bash and cmd, unlike the previous inline PowerShell whose
# `$_` was pre-expanded by a bash SHELL (emitting `'x86' is not recognized`
# noise on every build). All package .lua files live exactly two levels deep
# (packages/<name>/<file>.lua); the */*/* glob is a harmless guard for any
# future deeper nesting. Used only to re-trigger packages.mk regeneration when
# a package source changes.
PACKAGE_LUAS        := $(wildcard $(SRC_DIR)/runtime/packages/*/*.lua) \
                       $(wildcard $(SRC_DIR)/runtime/packages/*/*/*.lua)

$(GEN_DIR):
	if not exist "$(GEN_DIR)" mkdir "$(GEN_DIR)"

$(GEN_DIR)/runtime/packages:
	if not exist "$(GEN_DIR)\runtime\packages" mkdir "$(GEN_DIR)\runtime\packages"

$(BUILD_DIR)/obj/runtime/packages:
	if not exist "$(BUILD_DIR)\obj\runtime\packages" mkdir "$(BUILD_DIR)\obj\runtime\packages"

$(GEN_PACKAGES_MK) $(GEN_BUILTIN_H) $(GEN_NATIVE_DEPS_H): $(ROOT)/tools/gen-package-rules.ps1 $(PACKAGE_LUAS) | $(GEN_DIR)
	powershell -NoProfile -ExecutionPolicy Bypass -File $(ROOT)/tools/gen-package-rules.ps1 -PackagesDir "$(SRC_DIR)/runtime/packages" -OutMk "$(GEN_PACKAGES_MK)" -OutHeader "$(GEN_BUILTIN_H)" -OutNativeDepsHeader "$(GEN_NATIVE_DEPS_H)"

$(GEN_LINT_H): $(GEN_LINT_SRC) $(ROOT)/tools/gen-lint-header.ps1 | $(GEN_DIR)
	powershell -NoProfile -ExecutionPolicy Bypass -File $(ROOT)/tools/gen-lint-header.ps1 -In "$(GEN_LINT_SRC)" -Out "$(GEN_LINT_H)"

# main.c #includes the embedded lint header; regenerate it (and rebuild main.o)
# whenever the lint package source changes.
$(BUILD_DIR)/obj/compiler/main.o: $(GEN_LINT_H)

-include $(GEN_PACKAGES_MK)

# Aggregate -- the compiler reaches in per-build to pick only the
# .o files it needs. Building this target guarantees all packages
# have been compiled and are available on disk. PACKAGE_OBJS_AUTO is
# populated by the generated packages.mk fragment.
PACKAGE_OBJS := $(PACKAGE_OBJS_AUTO)

# Embedded-variant package objects -- one .o per package compiled with
# the size + hardening flags from EMBEDDED_RT_CFLAGS. Static pattern
# rule keyed off the just-expanded PACKAGE_OBJS so make can resolve
# every name without falling back to path-normalized pattern matching.
PACKAGE_EMB_OBJS := $(patsubst %.o,$(BUILD_DIR)/obj-emb/runtime/packages/%.o,$(notdir $(PACKAGE_OBJS)))

$(PACKAGE_EMB_OBJS): $(BUILD_DIR)/obj-emb/runtime/packages/%.o: $(GEN_DIR)/runtime/packages/%.c | $(BUILD_DIR)/obj-emb/runtime/packages
	$(CC) $(EMBEDDED_RT_CFLAGS) -c $< -o $@

packages-embedded: $(PACKAGE_EMB_OBJS)

$(BUILD_DIR)/runtime.a: $(RUNTIME_OBJS)
	$(AR) rcs $@ $^

.PHONY: runtime packages
runtime: $(BUILD_DIR)/runtime.a packages
packages: $(PACKAGE_OBJS)

# --- standalone luavm.exe (REPL + script runner) --------------------------
LUAVM_SRC := $(SRC_DIR)/runtime/luavm_main.c
LUAVM_OBJ := $(BUILD_DIR)/obj/runtime/luavm_main.o

$(LUAVM_OBJ): $(LUAVM_SRC) | $(BUILD_DIR)/obj/runtime
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/luavm.exe: $(LUAVM_OBJ) $(BUILD_DIR)/runtime.a $(PACKAGE_OBJS) $(BUILD_DIR)/liblua54.a
	$(CC) $(CFLAGS) -o $@ $(LUAVM_OBJ) $(BUILD_DIR)/runtime.a $(PACKAGE_OBJS) $(BUILD_DIR)/liblua54.a -lm -lkernel32 -ladvapi32 -liphlpapi -lpsapi

.PHONY: luavm
luavm: $(BUILD_DIR)/luavm.exe

# --- ffi -------------------------------------------------------------------

FFI_SRCS := \
    $(SRC_DIR)/ffi/ctype.c        \
    $(SRC_DIR)/ffi/cdecl_lexer.c  \
    $(SRC_DIR)/ffi/cdecl_parser.c \
    $(SRC_DIR)/ffi/win_types.c    \
    $(SRC_DIR)/ffi/cdata.c        \
    $(SRC_DIR)/ffi/marshal.c      \
    $(SRC_DIR)/ffi/ffi_lib.c      \
    $(SRC_DIR)/ffi/veh.c          \
    $(SRC_DIR)/ffi/ffi_load.c     \
    $(SRC_DIR)/ffi/ffi_atomics.c  \
    $(SRC_DIR)/ffi/ffi_call.c     \
    $(SRC_DIR)/ffi/ffi_callback.c \
    $(SRC_DIR)/ffi/ffi_thunk.c

FFI_OBJS := $(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/obj/%.o,$(FFI_SRCS))

$(BUILD_DIR)/obj/ffi:
	if not exist "$(BUILD_DIR)\obj\ffi" mkdir "$(BUILD_DIR)\obj\ffi"

$(BUILD_DIR)/obj/ffi/%.o: $(SRC_DIR)/ffi/%.c | $(BUILD_DIR)/obj/ffi
	$(CC) $(CFLAGS) -c $< -o $@

# Smoke-test binary: directly compile runtime_init.c into stub.exe.
$(BUILD_DIR)/stub.exe: $(SRC_DIR)/runtime/runtime_init.c
	$(CC) $(CFLAGS) -o $@ $<

.PHONY: stub
stub: $(BUILD_DIR)/stub.exe

# --- build-time tools: embed_luac (Lua -> bytecode) + runluac -------------
# embed_luac takes a .lua, runs luaL_loadfile + lua_dump (strip=1) and writes a
# C file embedding the bytecode. Used by gen-package-rules.ps1 to precompile
# every package at build time. runluac is M2 scaffolding.
$(BUILD_DIR)/embed_luac.exe: $(SRC_DIR)/tools/embed_luac.c $(BUILD_DIR)/liblua54.a
	$(CC) $(CFLAGS) -o $@ $< $(BUILD_DIR)/liblua54.a -lm

.PHONY: embed-luac
embed-luac: $(BUILD_DIR)/embed_luac.exe

$(BUILD_DIR)/runluac.exe: $(SRC_DIR)/tools/runluac.c $(BUILD_DIR)/liblua54.a
	$(CC) $(CFLAGS) -o $@ $^ -lm

.PHONY: runluac
runluac: $(BUILD_DIR)/runluac.exe

# --- tests ------------------------------------------------------------------
# All tests (C unit + Lua behavioral + package + differential) are discovered
# and run by the auto-discovering Lua runner tools/run-tests.lua, so this
# Makefile never names an individual test file -- adding or deleting a test
# cannot break the build. Run the full suite with:
#   build\run-tests.bat                       (builds products, then runs them)
# or, with the products already built:
#   build\bin\luavm.exe tools\run-tests.lua
.PHONY: test
# `embedded` (= lua-embedded + runtime-embedded + packages-embedded), not just
# packages-embedded: compiler.exe links build/bin/liblua54-embedded.a and
# runtime-embedded.a into every emitted PE, so the package-test layer needs
# them built. Depending only on packages-embedded made `make test` rely on a
# cache restore (CI) or a previous build (local) for the two archives -- a cold
# tree failed with "cannot find build/bin/runtime-embedded.a".
test: compiler luavm embedded luac-objs
	$(BUILD_DIR)/luavm.exe $(ROOT)/tools/run-tests.lua
# --- ImGui (Dear ImGui + cimgui + Win32/DX11 backends) --------------------
# Compiled into imgui.a. The compiler.exe link step pulls this in only when
# the user's Lua program statically requires "imgui" (auto-detect via the
# Resolve walker, see src/compiler/resolve.c). Builds as a static C++
# archive — no separate DLL, no runtime dependency.

CXX           := x86_64-w64-mingw32-g++

IMGUI_DIR     := $(ROOT)/third_party/imgui
CIMGUI_DIR    := $(ROOT)/third_party/cimgui

# -fno-exceptions/-fno-rtti shrink the binary substantially; ImGui supports
# both. We *do* want cimgui's symbols dllexport'd -- the compiler links
# imgui.a into the final exe with --export-all-symbols, and Lua reaches
# every cimgui function via ffi.C through GetProcAddress on the main exe.
IMGUI_CXXFLAGS := -std=c++17 -O2 -fno-exceptions -fno-rtti                 \
                  -Wno-deprecated-declarations                              \
                  -DIMGUI_DISABLE_OBSOLETE_FUNCTIONS                        \
                  -I$(IMGUI_DIR) -I$(IMGUI_DIR)/backends -I$(CIMGUI_DIR)

IMGUI_SRCS := \
    $(IMGUI_DIR)/imgui.cpp                            \
    $(IMGUI_DIR)/imgui_demo.cpp                       \
    $(IMGUI_DIR)/imgui_draw.cpp                       \
    $(IMGUI_DIR)/imgui_tables.cpp                     \
    $(IMGUI_DIR)/imgui_widgets.cpp                    \
    $(IMGUI_DIR)/backends/imgui_impl_win32.cpp        \
    $(IMGUI_DIR)/backends/imgui_impl_dx11.cpp         \
    $(CIMGUI_DIR)/cimgui.cpp                          \
    $(SRC_DIR)/runtime/native/imgui_host.cpp

IMGUI_OBJS := $(patsubst %.cpp,$(BUILD_DIR)/obj/imgui/%.o,$(notdir $(IMGUI_SRCS)))

$(BUILD_DIR)/obj/imgui:
	if not exist "$(BUILD_DIR)\obj\imgui" mkdir "$(BUILD_DIR)\obj\imgui"

# vpath lets the single pattern rule pick up sources scattered across the
# vendor tree without writing a dedicated rule per directory.
vpath %.cpp $(IMGUI_DIR) $(IMGUI_DIR)/backends $(CIMGUI_DIR) $(SRC_DIR)/runtime/native

$(BUILD_DIR)/obj/imgui/%.o: %.cpp | $(BUILD_DIR)/obj/imgui $(CIMGUI_DIR)/imgui/imgui.h
	$(CXX) $(IMGUI_CXXFLAGS) -c $< -o $@

# Directory junction so cimgui's relative includes (./imgui/imgui.h) resolve
# into our single Dear ImGui tree. Junctions don't need admin/dev-mode and
# aren't tracked by git, so a fresh clone recreates this on first build.
$(CIMGUI_DIR)/imgui/imgui.h:
	@if exist "$(CIMGUI_DIR)\imgui" rmdir "$(CIMGUI_DIR)\imgui"
	mklink /J "$(CIMGUI_DIR)\imgui" "$(IMGUI_DIR)"

$(BUILD_DIR)/imgui.a: $(IMGUI_OBJS)
	$(AR) rcs $@ $^

.PHONY: imgui
imgui: $(BUILD_DIR)/imgui.a
