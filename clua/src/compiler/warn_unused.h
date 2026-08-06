/* warn_unused.h -- diagnostic category framework + -Wunused scanner.
 *
 * The framework here is intentionally tiny: one enum of category ids, one
 * bit per category promoted to -Werror, and one call per scan. Adding a
 * new category means adding an enum id, a bool in LcWarnFlags, a name<->id
 * lookup entry in LcWarn_ParseCategory / LcWarn_CategoryName, and a new
 * LcWarn_Scan<Name> pass called by the driver.
 *
 * -Wunused specifically: walks each Proto's LocVar table + bytecode and
 * warns on locals that are written but never read. Reads via upvalue
 * capture (OP_CLOSURE naming the slot in an inner proto's Upvaldesc)
 * count as reads, so `local x = 1; return function() return x end` is
 * quiet. Locals whose name starts with `_` are exempt (the Lua convention
 * for intentionally-unused locals: `for _, v in ipairs(t)`).
 */
#ifndef CLUA_COMPILER_WARN_UNUSED_H
#define CLUA_COMPILER_WARN_UNUSED_H

#include <stdbool.h>

/* Forward decl: pulling in lobject.h transitively would drag lua.h into every
 * TU that just wants the driver's warn.h. Only warn_unused.c dereferences it. */
struct Proto;

/* Category ids. Every -W<name> flag maps to exactly one id. Keep them dense
 * (0..N-1) so a single `unsigned` bitset in LcWarnFlags.werror_bits is enough
 * for per-category -Werror promotion. */
typedef enum {
    LCWARN_CAT_UNUSED = 0,
    LCWARN_CAT_COUNT  /* keep last */
} LcWarnCategory;

/* Per-invocation warning-flag block on LcDriverOptions. Set by the -W parser
 * in main.c / clua_main.c BEFORE the fall-through to "unknown argument". */
typedef struct LcWarnFlags {
    bool     unused;        /* -Wunused / -Wall */
    bool     werror_all;    /* -Werror (global promotion of every enabled cat) */
    unsigned werror_bits;   /* -Werror=<name> per-category promotion, bit i    */
} LcWarnFlags;

/* Bit helpers. Kept as macros so the driver can OR-in without introducing a
 * function-call barrier around a one-instruction operation. */
#define LCWARN_BIT( cat_id ) ( 1u << ( cat_id ) )

/* Parse a single -W flag token (WITHOUT the leading "-W"). Returns:
 *   +1  recognized and applied (flags mutated)
 *    0  syntactically well-formed but the category is unknown (msg on stderr)
 *   -1  the token does not look like a -W flag at all (never enters here today
 *       since the driver strips "-W" first, but reserved for future prefixes)
 *
 * Recognized forms:
 *   "all"          => every category on
 *   "error"        => werror_all = 1
 *   "error=<name>" => werror_bits |= 1 << id(name)
 *   "no-<name>"    => category <name> off
 *   "<name>"       => category <name> on
 */
int  LcWarn_ParseFlag( LcWarnFlags *W, const char *tok );

/* name<->id lookup. Returns "" for out-of-range ids so a caller can splice
 * the name into a diagnostic without a NULL check. */
const char *LcWarn_CategoryName( int cat_id );
int         LcWarn_CategoryFromName( const char *name );  /* -1 if unknown */

/* Walk `P` (and every nested proto) and emit one warning per local that is
 * written but never read. `source_path` is the file path shown in the
 * "--> path:line:col" arrow row (usually Modules[i].Path). When `werror` is
 * true every warning also increments *fatal_out; the driver turns a non-zero
 * fatal count into a non-zero exit. Passing NULL for fatal_out is fine (the
 * warnings still print, they just don't influence the exit code).            */
void LcWarn_ScanUnused( const struct Proto *P, const char *source_path,
                        bool werror, int *fatal_out );

#endif /* CLUA_COMPILER_WARN_UNUSED_H */
