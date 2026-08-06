/* diag_hints.h -- contextual "help:" hints for common Lua compile-error
 * patterns. The hint table is a small ordered list of (pattern, category, hint)
 * triples; LcDiag_LookupHint() finds the first entry whose `pattern` substring
 * appears in the raw Lua error message and returns its multi-line hint. Hints
 * are strictly additive -- a NULL result means "no hint, print the error as
 * before", so a hint never changes exit codes or byte-identity of a correct
 * program.
 *
 * The pattern is a substring, not a regex, and matches are case-sensitive so we
 * pick up the exact wording used by Lua's `luaX_syntaxerror` /
 * `luaG_typeerror` / `luaK_semerror`. Ordering matters: more-specific patterns
 * should appear before their less-specific supersets.
 */
#ifndef CLUA_COMPILER_DIAG_HINTS_H
#define CLUA_COMPILER_DIAG_HINTS_H

typedef struct _LC_DIAG_HINT {
    const char *Pattern;   /* substring to match in the raw Lua error text     */
    const char *Category;  /* short kind label: "syntax" / "type" / "scope" /  */
                           /* "limit" -- surfaced back to the caller via       */
                           /* the category_out parameter (may be NULL)         */
    const char *Hint;      /* multi-line help text; each line ends in '\n'     */
} LC_DIAG_HINT_T;

/* Look up a hint for `RawMsg`. Returns the hint text (never modified by the
 * caller) or NULL when no pattern matches. When non-NULL AND CategoryOut is
 * non-NULL, *CategoryOut is set to the matching entry's category label; on a
 * NULL return CategoryOut is left untouched. */
const char *LcDiag_LookupHint( const char *RawMsg, const char **CategoryOut );

/* Number of entries in the hint table -- exposed so a self-test can iterate
 * the table without duplicating its contents. */
int LcDiag_HintCount( void );

/* Fetch entry `Index` from the hint table (0-based). Returns NULL when
 * `Index` is out of range. Read-only view; the caller must not free it. */
const LC_DIAG_HINT_T *LcDiag_HintAt( int Index );

#endif /* CLUA_COMPILER_DIAG_HINTS_H */
