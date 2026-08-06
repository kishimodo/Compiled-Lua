# baseline: the libc dependency surface, and where `hello.exe`'s bytes are

Measured 2026-07-26 at `7fec28f` plus the delivered slice, warm tree,
toolchain `nm`/`objdump` from `gcc-15.2.0 ... binutils-2.45 ...
mingw-w64-v13.0.0-ucrt`.

## 1. `hello.exe` is not CRT bytes

`build/tmp/byteid/hello.lua` (`print("hello")`) at `-O1`, 137,216 bytes:

| Section | Bytes | Share |
|---|---:|---:|
| `.text` | 114,736 | 83.6% |
| `.rdata` | 11,420 | 8.3% |
| `.idata` | 4,330 | 3.2% |
| `.bss` | 3,104 | 2.3% |
| `.pdata` | 1,536 | 1.1% |
| `.xdata` | 1,512 | 1.1% |
| `.data` | 512 | 0.4% |
| `.reloc` | 400 | 0.3% |
| `.tls` | 16 | - |

Imported DLLs (13):

```
KERNEL32.dll
api-ms-win-crt-{runtime,stdio,string,heap,private,math,locale,
                time,environment,utility,filesystem,convert}-l1-1-0.dll
```

The `api-ms-win-crt-*` entries are UCRT apiset forwarders into
`ucrtbase.dll`, which ships with the OS. The CRT is therefore already outside
the binary; its entire cost to us is the import-table share of `.idata`, at
most 4,330 bytes and in practice ~3 KB once `KERNEL32` is excluded.

`.text` is our runtime plus the Lua core. Corroborated by the whole-session
A/B in [`session-2026-07-25-ab.md`](session-2026-07-25-ab.md): `hello` moved
0 bytes across a change that cut Rover by 9.22%, because `hello`'s size is
essentially independent of user code.

Linker section GC on this link: 656 sections kept, 338 dropped, 21,104 bytes
of dead code removed. That the GC already finds 21 KB of dead code at object
granularity is the argument for `-ffunction-sections` on the runtime, see
`no-crt.md` section 8.

## 2. the dependency surface

`nm -u` over `build/bin/runtime-aot.a`, `build/bin/liblua54.a`,
`build/bin/aot_entry.o`; `__imp_` stripped; deduplicated:

| Bucket | Count |
|---|---:|
| External symbols referenced | 552 |
| Satisfied by Win32 import libs (`kernel32`/`user32`/`advapi32`/`shell32`) | 45 |
| Defined within our own archive set (cross-object, not a dependency) | 446 |
| Generated per build | 6 |
| Genuine libc dependency | 100 |

The 6 generated: `g_LuaBlob`, `g_LuaBlob_size`, `luac_protoblob`,
`luac_fn_table`, `Runtime_GetPackages`, `Native_GetEmbeddedDlls`.

### the 100, by defining archive

| Archive | Count | Becomes |
|---|---:|---|
| `libucrt.a` | 93 | DLL imports today; removed under `--crt=none` |
| `libmingwex.a` | 5 | `__mingw_fprintf` `__mingw_sprintf` `__mingw_strtod` `__stack_chk_fail` `__stack_chk_guard`, static code already in our `.text` |
| `libmingw32.a` | 1 | `__main`, static |
| `libgcc.a` | 1 | `___chkstk_ms`, static |

Full list:

```
___chkstk_ms __acrt_iob_func __intrinsic_setjmpex __main __mingw_fprintf
__mingw_sprintf __mingw_strtod __stack_chk_fail __stack_chk_guard
_beginthreadex _difftime64 _errno _gmtime64 _localtime64 _mktime64 _pclose
_popen _time64 abort acos asin atan2 calloc clearerr clock cos cosh exit exp
fclose feof ferror fflush fgets fmod fopen fprintf fputc fputs fread free
freopen frexp fseek ftell fwrite getc getenv isalnum isalpha iscntrl isgraph
islower ispunct isspace isupper isxdigit ldexp localeconv log log10 longjmp
malloc memchr memcmp memcpy memmove memset pow realloc remove rename setlocale
setvbuf sin sinh snprintf sqrt strchr strcmp strcoll strerror strftime strlen
strncat strncpy strpbrk strrchr strspn strstr strtoll system tan tanh tmpfile
tmpnam tolower toupper ungetc vsnprintf
```

## 3. two findings that changed the plan

3.1 `libmingwex.a` provides none of the transcendentals. Checked with
`nm --defined-only` for `sin cos tan pow exp log log10 asin acos atan2 sinh
cosh tanh fmod sqrt`, all 15 absent; all come from UCRT. There is no free
static libm to fall back on, so `--crt=none` must supply libm itself, which
is what creates the oracle problem in `no-crt.md` section 4. 22 of our
objects reference math symbols.

3.2 The Lua core already does not depend on CRT `setjmp`.
`lua-5.4/src/ldo.c:73-74` carries a CLua-specific patch using
`__builtin_setjmp`/`__builtin_longjmp`, with a comment stating the intent is
to avoid Windows SEH stack unwinding. `liblua54.a` references neither
`longjmp` nor `__intrinsic_setjmpex`. Only two of our own objects do:

```
runtime-aot.a[dispatch.o]  U __intrinsic_setjmpex
runtime-aot.a[veh.o]       U __imp_longjmp
```

Both are ours to convert, which makes `no-crt.md` item N6 much smaller than
a from-scratch `setjmp` port would be.

## 4. reproducing

`no-crt.md` item N0 turns this into `tools/audit-libc-surface.sh`. Until
then, the pipeline was:

```bash
NM=<toolchain>/nm.exe
for a in build/bin/runtime-aot.a build/bin/liblua54.a build/bin/aot_entry.o; do
  "$NM" -u "$a" | awk '{print $NF}'; done | sed 's/^__imp_//' | sort -u > undef.txt
for a in build/bin/runtime-aot.a build/bin/liblua54.a build/bin/aot_entry.o; do
  "$NM" --defined-only "$a" | awk '{print $NF}'; done | sed 's/^__imp_//' | sort -u > ours.txt
for a in kernel32 user32 advapi32 shell32; do
  "$NM" --defined-only build/bin/sysroot/lib$a.a | awk '{print $NF}'; done |
  sed 's/^__imp_//' | sort -u > win32.txt
comm -23 undef.txt ours.txt | comm -23 - win32.txt      # -> the 100 (+6 generated)
objdump -p build/bin/hello.exe | grep "DLL Name"        # -> the 13 imports
objdump -h build/bin/hello.exe                          # -> section sizes
CLUA_GC_DEBUG=1 clua.exe build hello.lua -O1 -o x.exe   # -> the [gc]/[ar] lines
```

Note for whoever repeats this: `nm -u` on an archive set reports cross-object
references as undefined, so the raw 552 overstates the dependency by 446. The
subtraction against our own defined set is the step that matters; omitting
it produced an early, wrong figure of "507 CRT symbols" during this session.
