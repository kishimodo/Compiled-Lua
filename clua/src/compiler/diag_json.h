/* diag_json.h -- rustc-shaped JSON diagnostics for editor / LSP shim
 * consumption. One JSON object per diagnostic, one per line, on stderr.
 *
 * The schema mirrors rustc's `--error-format=json` output as closely as our
 * data model supports (severity/code/message/spans[]/children[]/help), so
 * existing rustc-oriented editor shims can be pointed at compiler.exe with
 * minimal glue. See LcDiag_WriteJson() below for the exact field set.
 *
 * The formatter never escapes non-ASCII bytes beyond U+007F: JSON strings are
 * UTF-8 and the C strings we're handed come in as UTF-8 (Lua source is UTF-8,
 * paths on Windows are typed as UTF-8 by the driver), so passing those bytes
 * through unchanged keeps `\u` escapes off the hot path. Only C0 control
 * characters, the ASCII quote, and the backslash are escaped -- which also
 * makes Windows paths (e.g. `C:\src\app.lua`) come out as `C:\\src\\app.lua`
 * in the emitted `file` field, as required for a strict JSON parser.
 */
#ifndef CLUA_COMPILER_DIAG_JSON_H
#define CLUA_COMPILER_DIAG_JSON_H

#include <stdio.h>

/* Severity is shared with the text pretty printer (LcSeverity). Reusing it
 * means a diagnostic constructed for one formatter can drop straight into
 * the other with no translation. See diag_pretty.h for the enum values;
 * LCSEV_HINT (not in the JSON writer table today) is treated as HELP. */
#include "compiler/diag_pretty.h"
typedef LcSeverity LC_SEVERITY_T;
#define LC_SEV_ERROR   LCSEV_ERROR
#define LC_SEV_WARNING LCSEV_WARNING
#define LC_SEV_NOTE    LCSEV_NOTE
#define LC_SEV_HELP    LCSEV_HELP

/* A single source span. `Label` is the small annotation text painted next to
 * the caret in rustc output; may be NULL for spans without one. Columns are
 * 1-based; a zero column comes out as JSON `null` so the consumer can tell
 * "unknown" from "the first column". */
typedef struct _LC_DIAG_JSON_SPAN {
    const char *File;
    int         Line;
    int         ColStart;
    int         ColEnd;      /* 1-based exclusive; if <= ColStart, encoded as ColStart+1 */
    const char *Label;       /* may be NULL */
    int         IsPrimary;   /* nonzero => the primary span for this diagnostic */
} LC_DIAG_SPAN_T;

/* A subdiagnostic ("child" in rustc terms): a note/help attached to a parent
 * error/warning. Kept flat -- one level of nesting matches everything we
 * currently emit and matches the shallow structure rustc actually uses. */
typedef struct _LC_DIAG_JSON_CHILD {
    LC_SEVERITY_T         Severity;
    const char           *Message;
    const LC_DIAG_SPAN_T *Spans;
    int                   NSpans;
} LC_DIAG_CHILD_T;

/* Emit one JSON diagnostic to Out, exactly one line, NO trailing newline
 * inside the object. Any of `code`, `spans`, `children`, `help` may be
 * NULL/empty; those fields are emitted as `null` / `[]` respectively so the
 * shape stays stable for shims that iterate over keys. */
void LcDiag_WriteJson( FILE                  *Out,
                       LC_SEVERITY_T          Severity,
                       const char            *Code,
                       const char            *Message,
                       const LC_DIAG_SPAN_T  *Spans,
                       int                    NSpans,
                       const LC_DIAG_CHILD_T *Children,
                       int                    NChildren,
                       const char            *Help );

/* Low-level string escaper, exported so callers who want to hand-roll a JSON
 * object (e.g. a future --diagnostics-format=json extension for build-summary
 * lines) don't re-implement the escape table. Writes the OPENING quote, the
 * escaped body, and the CLOSING quote. `S` may be NULL -> emits `""`. */
void lc_json_string( FILE *Out, const char *S );

#endif /* CLUA_COMPILER_DIAG_JSON_H */
