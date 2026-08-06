/* diag_suggest.c -- see diag_suggest.h.
 *
 * Damerau-Levenshtein with an internal 128-char cap: identifier typos are
 * short, and a fixed-size DP grid keeps allocation off the hot path (a
 * single 129*129 int table lives on the stack, ~66 KB). Longer inputs are
 * declined by returning -1 rather than growing the grid, so the diagnostic
 * pass can't accidentally spend a lot of CPU on a pathological name.
 *
 * The suggest helper is deliberately narrow -- one call, one best match,
 * one deterministic tie-break rule (smallest distance, then earliest in
 * the input pool) -- so callers that iterate over a scan just plug in the
 * candidate list once and pull the winner. Bakes the "distance <= 2, name
 * length >= 4" threshold in so every call site agrees.
 */
#include "compiler/diag_suggest.h"

#include <string.h>
#include <stdlib.h>

/* Cap for both strings. 128 covers the longest realistic Lua identifier by a
 * comfortable margin (stdlib names top out at ~12 chars; user names of any
 * plausible length fit here). Longer inputs are declined below. */
#define LC_SUGGEST_MAX_LEN 128

/* Minimum length of the misspelled name before we suggest at all. Below this,
 * a 2-edit window catches too many neighbours (`os`, `io`, `bit` all lie
 * within 2 of most 2-3 char typos), which produces confident-looking wrong
 * guesses. Matches rustc's own suggestion floor for the same reason. */
#define LC_SUGGEST_MIN_BAD_LEN 4

/* Maximum edit distance accepted as "close enough" to suggest. 2 is the
 * canonical typo-correction bound: covers single insert/delete/substitute
 * plus one adjacent transposition (Damerau) -- exactly the class of typos
 * users make on identifiers. 3 lets clearly-different words match. */
#define LC_SUGGEST_MAX_DIST 2

static int min3( int a, int b, int c ) {
    int m = a < b ? a : b;
    return m < c ? m : c;
}

int lc_damerau_levenshtein( const char *a, const char *b ) {
    int  la, lb;
    int  i, j;
    /* Full DP table on the stack; the +1 borders hold the classic base row
     * / base column (edit distance from the empty string). */
    static int d[ LC_SUGGEST_MAX_LEN + 1 ][ LC_SUGGEST_MAX_LEN + 1 ];

    if ( a == NULL || b == NULL ) return -1;
    la = ( int )strlen( a );
    lb = ( int )strlen( b );
    if ( la > LC_SUGGEST_MAX_LEN || lb > LC_SUGGEST_MAX_LEN ) return -1;

    /* Base cases: distance from prefix of length i (or j) to the empty
     * string is i (or j) -- pure inserts/deletes. */
    for ( i = 0; i <= la; i++ ) d[ i ][ 0 ] = i;
    for ( j = 0; j <= lb; j++ ) d[ 0 ][ j ] = j;

    for ( i = 1; i <= la; i++ ) {
        for ( j = 1; j <= lb; j++ ) {
            int cost = ( a[ i - 1 ] == b[ j - 1 ] ) ? 0 : 1;
            int best = min3( d[ i - 1 ][ j ] + 1,          /* deletion  */
                             d[ i ][ j - 1 ] + 1,          /* insertion */
                             d[ i - 1 ][ j - 1 ] + cost ); /* substitute */
            /* Damerau extension: two adjacent transposed characters cost 1,
             * not 2 (which plain Levenshtein would charge for a swap =
             * one delete + one insert). "pritn" -> "print" is a single
             * transposition and shows up as distance 1 here, not 2. */
            if ( i >= 2 && j >= 2 &&
                 a[ i - 1 ] == b[ j - 2 ] &&
                 a[ i - 2 ] == b[ j - 1 ] ) {
                int trans = d[ i - 2 ][ j - 2 ] + 1;
                if ( trans < best ) best = trans;
            }
            d[ i ][ j ] = best;
        }
    }
    return d[ la ][ lb ];
}

int LcDiag_SuggestName( const char *bad,
                        const char *const *candidates, int ncandidates,
                        char *out, size_t outsz ) {
    int         i;
    int         best_dist = LC_SUGGEST_MAX_DIST + 1;
    const char *best      = NULL;
    size_t      badlen;

    if ( bad == NULL || candidates == NULL || ncandidates <= 0 ||
         out == NULL || outsz == 0 ) return 0;
    badlen = strlen( bad );
    /* Short-name floor: below LC_SUGGEST_MIN_BAD_LEN the edit-distance-2
     * window is dense with unrelated stdlib names; a confident-looking wrong
     * guess is worse than no guess. Callers rely on this to skip suggesting
     * for names like "xz" (length 2) even when close candidates exist. */
    if ( badlen < LC_SUGGEST_MIN_BAD_LEN ) return 0;

    for ( i = 0; i < ncandidates; i++ ) {
        int d;
        if ( candidates[ i ] == NULL )                       continue;
        /* An exact match means the name IS defined -- the caller shouldn't
         * even have asked, but if they did, don't suggest the same string
         * back at them (would render as "did you mean 'foo'?" for 'foo'). */
        if ( strcmp( candidates[ i ], bad ) == 0 )           continue;
        d = lc_damerau_levenshtein( bad, candidates[ i ] );
        if ( d < 0 || d > LC_SUGGEST_MAX_DIST )              continue;
        /* Tie-break: keep the FIRST candidate at the current best distance.
         * Combined with the caller building the candidate pool in a stable
         * order (stdlib first, then declared names in source order), this
         * makes the "did you mean" text deterministic across runs. */
        if ( d < best_dist ) {
            best_dist = d;
            best      = candidates[ i ];
        }
    }

    if ( best == NULL ) return 0;
    {
        size_t n = strlen( best );
        if ( n + 1 > outsz ) n = outsz - 1;
        memcpy( out, best, n );
        out[ n ] = '\0';
    }
    return 1;
}
