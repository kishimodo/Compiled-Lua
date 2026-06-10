/* coff_probe_main.c -- companion main for the COFF-writer link probe (Task 12).
 *
 * Supplies our OWN `main` so the linker does NOT pull the runtime archive's
 * `main` (runtime_entry.o), which drags in the per-program blob symbols
 * (g_LuaBlob / g_LuaBlob_size / Runtime_GetPackages) that the not-yet-built
 * embedding step would provide and which are undefined in the stock archives
 * (the Task 2 spike finding). Keeping the runtime's main out lets the probe
 * prove only what we want: that ld accepts the generated COFF object and
 * resolves its Rt_* relocs from runtime-embedded.a.
 *
 * `luac_fn_0` is declared extern and force-kept via -Wl,--undefined=luac_fn_0
 * on the link line, so its relocations MUST resolve for the link to succeed.
 * NOTE: this file is NOT a test_*.c, so the test runner does not run it as a
 * test; it is only compiled into the probe link.
 */
extern int luac_fn_0( void );
int main( void ) { return 0; }
