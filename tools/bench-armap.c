/* tools/bench-armap.c -- how long does the internal linker's archive symbol
** lookup take for a realistic query load? Links against the tree's own
** ar_read.o, so it measures the shipped LcAr_MemberDefining rather than a
** reimplementation. Not part of the test suite; a measurement harness.
**
**   gcc -std=c99 -O2 -I clua/src -o bench-armap.exe \
**       tools/bench-armap.c build/bin/obj/link/ar_read.o
**   ./bench-armap.exe build/bin/sysroot 1500
**
** Query load model: resolve_fixpoint walks every unresolved symbol and, for
** each, calls LcAr_MemberDefining on every archive in order until one hits.
** We replay that with the archives' own symbol names as the query set, which
** is the right shape (real programs reference CRT symbols that live in these
** armaps) and lets us scale to a chosen number of lookups.
**
** Results are recorded in docs/benchmarks/archive-symbol-lookup.md.
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "link/ar_read.h"

static const char *kArch[] = {
    "libmingw32.a", "libgcc.a", "libmoldname.a", "libmingwex.a", "libmsvcrt.a",
    "libadvapi32.a", "libshell32.a", "libuser32.a", "libkernel32.a", "libucrt.a"
};
#define NARCH ((int)(sizeof(kArch)/sizeof(kArch[0])))

static double now_ms(void) {
    return (double)clock() * 1000.0 / (double)CLOCKS_PER_SEC;
}

int main(int argc, char **argv) {
    const char *root = argc > 1 ? argv[1] : "build/bin/sysroot";
    int nquery = argc > 2 ? atoi(argv[2]) : 1500;
    LcArchive ar[NARCH];
    char err[512], path[1024];
    int i, q, hits = 0, misses = 0;
    long long total_syms = 0;
    double t0, t1;

    for (i = 0; i < NARCH; i++) {
        snprintf(path, sizeof path, "%s/%s", root, kArch[i]);
        if (!LcAr_Open(path, &ar[i], err, sizeof err)) {
            fprintf(stderr, "open %s: %s\n", path, err);
            return 1;
        }
        total_syms += ar[i].nindex;
    }
    printf("archives=%d  armap symbols=%lld  queries=%d\n",
           NARCH, total_syms, nquery);

    /* Build a query set spread across the archives, biased the way a real link
    ** is: most symbols resolve in libmsvcrt/libucrt/libkernel32, i.e. late in
    ** the search order, so the earlier armaps are scanned in full first. */
    {
        const char **qs = (const char **)malloc((size_t)nquery * sizeof(char *));
        int filled = 0;
        int a = NARCH - 1;
        while (filled < nquery) {
            if (ar[a].nindex > 0) {
                uint32_t pick = (uint32_t)((filled * 7919u) % ar[a].nindex);
                qs[filled++] = ar[a].index[pick].symname;
            }
            a--;
            if (a < 4) a = NARCH - 1;   /* msvcrt and later: the common case */
        }

        t0 = now_ms();
        for (q = 0; q < nquery; q++) {
            for (i = 0; i < NARCH; i++) {
                const LcArMember *m = LcAr_MemberDefining(&ar[i], qs[q]);
                if (m) { hits++; break; }
            }
            if (i == NARCH) misses++;
        }
        t1 = now_ms();
        printf("resolved=%d unresolved=%d\n", hits, misses);
        printf("LcAr_MemberDefining total: %.1f ms  (%.1f us per symbol)\n",
               t1 - t0, (t1 - t0) * 1000.0 / (double)nquery);
        free((void *)qs);
    }

    /* Cost of the open/parse phase alone, for comparison. */
    for (i = 0; i < NARCH; i++) LcAr_Close(&ar[i]);
    t0 = now_ms();
    for (i = 0; i < NARCH; i++) {
        snprintf(path, sizeof path, "%s/%s", root, kArch[i]);
        LcAr_Open(path, &ar[i], err, sizeof err);
    }
    t1 = now_ms();
    printf("LcAr_Open all %d archives (warm): %.1f ms\n", NARCH, t1 - t0);
    for (i = 0; i < NARCH; i++) LcAr_Close(&ar[i]);
    return 0;
}
