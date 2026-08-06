/*!
 * @brief
 *  Project-wide version -- the SINGLE SOURCE OF TRUTH for the CLua toolchain
 *  version. `clua version` / `aotc version` read CLUA_VERSION_STRING from here;
 *  nothing else should hardcode a version. Bump with `tools/bump-version.ps1`
 *  (it rewrites these four macros, moves the CHANGELOG "Unreleased" section
 *  under the new version, and the Makefile's release zip picks the new string
 *  up automatically).
 *
 *  Versioning is semver. The numeric MAJOR/MINOR/PATCH triple is for
 *  programmatic comparison; CLUA_VERSION_STRING is the authoritative display
 *  string and carries the optional `-<prerelease>` suffix (empty on a final
 *  release).
 */

#ifndef CLUA_VERSION_H
#define CLUA_VERSION_H

#define CLUA_VERSION_MAJOR      0
#define CLUA_VERSION_MINOR      3
#define CLUA_VERSION_PATCH      0
#define CLUA_VERSION_PRERELEASE "beta.2"          /* "" for a final release */
#define CLUA_VERSION_STRING     "0.3.0-beta.2"    /* MAJOR.MINOR.PATCH[-PRERELEASE] */

#endif /* CLUA_VERSION_H */
