/*
** cluatoml.h -- per-project configuration file support (`clua.toml`).
**
** Track F3 of the beta.6 plan: a TOML config file the toolchain discovers by
** walking from CWD upward, stopping at the first `clua.toml` seen or at a
** `.git` marker / the filesystem root. Every CLI flag has a config-file
** equivalent; merge order (lowest to highest precedence): built-in defaults,
** clua.toml, environment variables (CLUA_*), command-line flags.
**
** Missing clua.toml is NOT an error -- the toolchain falls back to the same
** built-in defaults as before, byte-for-byte. Malformed clua.toml IS an error,
** printed as a normal diagnostic with `file:line:col` if possible, and the
** driver exits nonzero before any compile starts.
**
** The parser here handles the common subset of TOML v1.0 the config schema
** needs: tables (`[section]`), arrays of tables (`[[bundle]]`), key = value
** pairs, basic string / integer / boolean scalars, arrays of strings. Exotic
** things (inline tables, dotted keys past the section header, dates, floats,
** multi-line strings, string escapes past `\n \t \r \\ \" \0`) are rejected
** rather than silently dropped so a typo does not become a mystery.
*/
#ifndef CLUA_DRIVER_CLUATOML_H
#define CLUA_DRIVER_CLUATOML_H

#include <stdbool.h>
#include <stddef.h>

#include "aotc.h"   /* LcDriverOptions, output_kind / strip / emit enums */

#ifdef __cplusplus
extern "C" {
#endif

/* Parsed clua.toml contents, mirroring the schema in docs/plan-0.3.0-beta.6.md
** section F3. Every scalar carries a `has_` flag; unset means "the config file
** did not touch this key, keep the built-in default". Strings and array
** elements are all heap-copied so LcConfig_Free is enough to release
** everything. */
typedef struct LcConfig {
    /* [build] */
    bool         has_optimization; int   optimization;   /* 0..3           */
    bool         has_output;       int   output_kind;    /* LcOutputKind    */
    bool         has_strip;        int   strip_mode;     /* LcStripMode     */
    bool         has_jobs;         int   jobs;           /* 0 = all cores   */
    bool         has_debug;        bool  debug;          /* -g              */
    bool         has_cache;        bool  cache;          /* !--no-cache     */
    bool         has_shared_rt;    bool  shared_rt;
    bool         has_color;        int   color;          /* LC_DIAG_COLOR   */

    /* [diagnostics] */
    bool         has_diag_format;  int   diag_format;    /* LC_DIAG_FORMAT  */
    bool         has_werror;       bool  werror;         /* -Werror         */
    /* -Wname list applied to LcWarnFlags.unused (and future categories):    */
    char       **warn_names;
    size_t       warn_count;

    /* [resource] */
    char        *product_name;
    char        *product_version;
    char        *company_name;
    char        *copyright;
    char        *manifest;
    char        *icon;

    /* [explain] */
    char        *target_triple;    /* informational; not consumed by driver  */

    /* [[bundle]] entries. Each `package = "..."` becomes one string here.
    ** Wired into opt->force_pkgs (same shape as -L <pkg>). */
    char       **bundles;
    size_t       bundle_count;

    /* Source path (heap-copied) for `clua.toml:line:col` in error messages. */
    char        *source_path;
} LcConfig;

/* Zero-initialise a config. Same as memset(cfg, 0, sizeof *cfg). */
void LcConfig_Init( LcConfig *cfg );

/* Free every heap-owned string / array inside `cfg`. Idempotent on a zeroed
** config; safe to call after LcConfig_Load fails. */
void LcConfig_Free( LcConfig *cfg );

/* Walk from `start_dir` upward looking for `clua.toml`. The walk stops when:
**   * a `clua.toml` is found in the current dir  -> success, path written
**   * a `.git` file OR directory is found        -> stop, no config
**   * the filesystem root is reached             -> stop, no config
**
** `start_dir` NULL means "current working directory". `out_path` receives the
** full path to the found file; `out_size` is its byte size. Returns 1 when a
** file was located, 0 otherwise. Never fails except on an OS-level error.
**
** The `.git` marker matches git's own config walk: a repo root always has a
** `.git` entry (dir for a normal clone, file for a worktree). The walk
** deliberately keeps a config in the same dir as `.git` (test the dir FIRST
** for `clua.toml`, THEN for `.git`).
*/
int LcConfigDiscover( const char *start_dir,
                      char *out_path, size_t out_size );

/* Load and parse a clua.toml file. Returns 1 on success, 0 on parse / I/O
** error. On error a `file:line:col` diagnostic has been printed to stderr
** already; the caller only needs to exit nonzero. On success `cfg` owns any
** allocated strings; caller must LcConfig_Free it. */
int LcConfig_Load( const char *path, LcConfig *cfg );

/* Overlay `cfg` values on top of `opt`. Only keys the config file actually
** set (has_* is true, or an array is non-empty) are applied. Callers use this
** to seed the CLI parser's starting defaults BEFORE argv is scanned, so a
** subsequent explicit CLI flag wins. Fields on `opt` that a config value maps
** to must be at their built-in defaults when this is called -- the function
** does not check.
**
** The `force_pkgs` array is heap-allocated into `*out_force`; caller owns it
** (free with free()). It points into cfg->bundles' storage, so cfg must
** outlive opt. */
void LcConfig_ApplyToOptions( const LcConfig *cfg, LcDriverOptions *opt,
                              const char ***out_force, int *out_nforce );

/* Overlay CLUA_* environment variables on top of `opt`. Applied AFTER the
** config file so env beats config but loses to CLI. Reads:
**   CLUA_OPTIMIZATION   O0..O3 or 0..3
**   CLUA_JOBS           integer job count (0 = auto)
**   CLUA_STRIP          none|debug|all
**   CLUA_DEBUG          nonzero = -g
**   CLUA_NO_CACHE       nonzero = disable cache
**   CLUA_CACHE_DIR      path
**   CLUA_SHARED_RT      nonzero = --shared-rt
**   CLUA_COLOR          auto|always|never
**   CLUA_DIAGNOSTICS_FORMAT text|json
** Unknown / malformed values are silently ignored (env is best-effort).
*/
void LcConfig_ApplyEnv( LcDriverOptions *opt );

#ifdef __cplusplus
}
#endif

#endif /* CLUA_DRIVER_CLUATOML_H */
