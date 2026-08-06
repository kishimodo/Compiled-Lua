/* diag_suggest.h -- "did you mean" suggestions for undefined names.
 *
 * When the compiler encounters an unknown global (e.g. `pritn("hi")` where the
 * user meant `print`), it runs Damerau-Levenshtein edit distance against a
 * candidate pool (stdlib names + locals declared + globals set + require'd
 * module names) and, if any candidate is close enough, emits a `help:`
 * diagnostic beneath the primary error suggesting the correction.
 *
 * Threshold policy (baked into LcDiag_SuggestName so every call site agrees):
 *   - only suggest for bad names >= 4 characters (short names have too many
 *     equally-close neighbours; `xz` is not a typo of `os`)
 *   - only accept candidates within edit distance <= 2
 *   - break ties by preferring the smallest distance, then the earliest
 *     candidate in the input array (deterministic output, byte-reproducible)
 *
 * The utility is category-agnostic -- caller decides how to render the
 * result (typically as a "help:" note beneath the primary error).
 */
#ifndef CLUA_COMPILER_DIAG_SUGGEST_H
#define CLUA_COMPILER_DIAG_SUGGEST_H

#include <stddef.h>

/* Damerau-Levenshtein edit distance between the two NUL-terminated strings.
 * Handles insertions, deletions, substitutions and adjacent transpositions
 * (the classic Damerau extension over plain Levenshtein). Returns -1 if
 * either input is NULL, or if either input is longer than an internal cap
 * (128 chars -- identifier typos of interest are shorter than that; longer
 * inputs are silently declined so the O(n*m) table stays bounded). */
int lc_damerau_levenshtein( const char *a, const char *b );

/* Pick the best candidate for `bad` from `candidates[0..ncandidates)` and
 * write its name into `out` (NUL-terminated). Returns 1 when a suggestion
 * was found and written, 0 when no candidate met the thresholds (short
 * name, no close-enough match, empty pool). `out` is written only on 1;
 * callers may treat a 0 return as "no suggestion". */
int LcDiag_SuggestName( const char *bad,
                        const char *const *candidates, int ncandidates,
                        char *out, size_t outsz );

#endif /* CLUA_COMPILER_DIAG_SUGGEST_H */
