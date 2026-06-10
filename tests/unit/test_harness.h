/* test_harness.h -- minimal C unit-test harness for LuaVM tests/unit/test_*.c.
 *
 * Each test file is a standalone program with its own main():
 *
 *     #include "test_harness.h"
 *     #include "ffi/ctype.h"
 *     int main(void) {
 *         TEST_BEGIN("ctype_primitives");
 *         Ctype_Init();
 *         CHECK_NOT_NULL(Ctype_Lookup("int"));
 *         CHECK_EQ_INT(Ctype_Lookup("int")->Size, 4);
 *         TEST_END();   // prints [+] PASS/[-] FAIL <name>, returns 0/1
 *     }
 *
 * No registration, no framework, no deps beyond libc plus whatever objects the
 * test links against (the runner links every test against build/bin/libluavmtest.a
 * + liblua54.a). TEST_END() returns from main with 0 if every CHECK passed, 1
 * otherwise, so the runner just inspects the exit code (and the PASS/FAIL line).
 */
#ifndef LUAVM_TEST_HARNESS_H
#define LUAVM_TEST_HARNESS_H

#include <stdio.h>
#include <string.h>

static int         th_fails  = 0;
static int         th_checks = 0;
static const char *th_name   = "?";

#define TEST_BEGIN(n) \
    do { th_name = (n); th_fails = 0; th_checks = 0; } while (0)

#define TH_FAIL_(fmt, ...) \
    do { th_fails++; \
         fprintf(stderr, "[-] FAIL %s: " fmt " (%s:%d)\n", \
                 th_name, ##__VA_ARGS__, __FILE__, __LINE__); } while (0)

#define CHECK(cond) \
    do { th_checks++; if (!(cond)) TH_FAIL_("CHECK(%s)", #cond); } while (0)

#define CHECK_MSG(cond, msg) \
    do { th_checks++; if (!(cond)) TH_FAIL_("%s", (msg)); } while (0)

#define CHECK_EQ_INT(a, b) \
    do { th_checks++; long long a_ = (long long)(a), b_ = (long long)(b); \
         if (a_ != b_) TH_FAIL_("CHECK_EQ_INT(%s, %s): %lld != %lld", #a, #b, a_, b_); } while (0)

#define CHECK_NEQ_INT(a, b) \
    do { th_checks++; long long a_ = (long long)(a), b_ = (long long)(b); \
         if (a_ == b_) TH_FAIL_("CHECK_NEQ_INT(%s, %s): both %lld", #a, #b, a_); } while (0)

#define CHECK_EQ_STR(a, b) \
    do { th_checks++; const char *a_ = (a), *b_ = (b); \
         if (a_ == NULL || b_ == NULL || strcmp(a_, b_) != 0) \
             TH_FAIL_("CHECK_EQ_STR(%s, %s): \"%s\" != \"%s\"", \
                      #a, #b, a_ ? a_ : "(null)", b_ ? b_ : "(null)"); } while (0)

#define CHECK_NOT_NULL(p) \
    do { th_checks++; if ((p) == NULL) TH_FAIL_("CHECK_NOT_NULL(%s)", #p); } while (0)

#define CHECK_NULL(p) \
    do { th_checks++; if ((p) != NULL) TH_FAIL_("CHECK_NULL(%s)", #p); } while (0)

#define TEST_END() \
    do { if (th_fails == 0) { \
             printf("[+] PASS %s (%d checks)\n", th_name, th_checks); \
             return 0; \
         } else { \
             printf("[-] FAIL %s (%d/%d checks failed)\n", th_name, th_fails, th_checks); \
             return 1; \
         } } while (0)

#endif /* LUAVM_TEST_HARNESS_H */
