/* diag_hints.c -- database of contextual "help:" hints for the most common
 * Lua 5.4 compile-error patterns.
 *
 * Design notes
 * ------------
 * The table is a plain array of (substring, category, hint) triples.
 * LcDiag_LookupHint() walks it in order and returns the FIRST match, so
 * more-specific patterns MUST be listed before their less-specific supersets
 * (e.g. "attempt to index a nil value" comes before the family fall-through
 * "attempt to index"). This ordering is exactly why the table is not sorted
 * alphabetically or by category.
 *
 * The patterns are substrings of the raw Lua error message (as returned by
 * lua_tostring after a failed luaL_load*), so no escaping/regex work is needed
 * and adding a hint is a one-line change. The category label is passed back to
 * the caller so a future JSON diagnostic emitter can tag hints without having
 * to re-classify by pattern.
 *
 * Correctness constraints
 * -----------------------
 *   - a hint is ONLY appended when the compile is already failing, so it can
 *     never turn a passing build into a failing one;
 *   - the returned string is a static literal -- callers must not free it and
 *     the pointer is valid for the process lifetime;
 *   - each hint ends in '\n', so the diag printer can append it directly after
 *     its own trailing newline without introducing a blank line ambiguity.
 */
#include "compiler/diag_hints.h"

#include <stddef.h>
#include <string.h>

static const LC_DIAG_HINT_T kHints[] = {

    /* ------------------------------------------------------------------ */
    /* Syntax: token-level surprises the lexer/parser reports verbatim.   */
    /* ------------------------------------------------------------------ */

    { "unexpected symbol near '='",
      "syntax",
      "did you mean `==` for equality?\n"
      "  `=`  is assignment       (used in `local x = 1`)\n"
      "  `==` is comparison       (used in `if x == 1 then`)\n"
      "if you meant to assign, the target must be a name or table field, e.g.\n"
      "`x = 1` or `t.k = 1` -- assignment to an expression is not allowed.\n" },

    { "unexpected symbol near '<eof>'",
      "syntax",
      "the file ended in the middle of an expression or block. usually a\n"
      "trailing operator (e.g. `x +`) or a missing `end`/`)`/`}` before EOF.\n" },

    { "unexpected symbol",
      "syntax",
      "the token quoted after `near` is not valid here. common causes:\n"
      "  - a stray `,` or `;` between statements\n"
      "  - an operator without a right-hand operand (e.g. `x +* y`)\n"
      "  - using a reserved word (`end`, `then`, `local`, ...) as a name\n" },

    { "unfinished string",
      "syntax",
      "a string literal was opened but never closed. check for:\n"
      "  - a missing closing `\"` or `'` on the same line\n"
      "  - a real newline inside `\"...\"` (use `\\n` or a `[[...]]` block)\n"
      "  - an unbalanced `[[` long bracket -- match the level: `[==[...]==]`\n" },

    { "unfinished long string",
      "syntax",
      "a `[[ ... ]]` (or `[==[ ... ]==]`) long string was never closed.\n"
      "the closing bracket must use the SAME number of `=` signs as the opener.\n" },

    { "unfinished long comment",
      "syntax",
      "a `--[[ ... ]]` long comment was never closed.\n"
      "match the level of `=` signs: `--[==[ ... ]==]`.\n" },

    /* ------------------------------------------------------------------ */
    /* Block delimiters. Lua's message pattern is                          */
    /*   "'X' expected (to close 'Y' at line N) near '...'"                */
    /* so the substring match "'end' expected" also fires for the         */
    /* variant that carries the `to close` hint.                          */
    /* ------------------------------------------------------------------ */

    { "'end' expected",
      "syntax",
      "a block opened earlier was never closed. trace back from the reported\n"
      "line to the `function`, `if`, `do`, `while`, or `for` on the line named\n"
      "in `(to close ... at line N)`. common causes:\n"
      "  - a missing `end` after a nested `function`\n"
      "  - a `then`/`do` opened but never terminated\n"
      "  - a stray extra `end` earlier that closed the wrong block\n" },

    { "'then' expected",
      "syntax",
      "an `if` or `elseif` needs `then` before its body:\n"
      "  if cond then ... end\n"
      "  if cond then ... elseif other then ... end\n"
      "check for a stray operator or an unterminated expression in `cond`.\n" },

    { "'do' expected",
      "syntax",
      "a `while` or numeric/generic `for` needs `do` before its body:\n"
      "  while cond do ... end\n"
      "  for i = 1, 10 do ... end\n"
      "  for k, v in pairs(t) do ... end\n" },

    { "'=' or 'in' expected",
      "syntax",
      "a `for` loop must be one of:\n"
      "  for i = start, stop        do ... end   -- numeric\n"
      "  for i = start, stop, step  do ... end   -- numeric with step\n"
      "  for k, v in pairs(t)       do ... end   -- generic\n"
      "you wrote something the parser cannot classify as either shape.\n" },

    { "'=' expected",
      "syntax",
      "the parser expected an assignment (`=`) here. common causes:\n"
      "  - a `local NAME` without the initializer you meant to write\n"
      "  - a stray token between the name and `=`\n"
      "  - a function call written as a statement then followed by junk\n" },

    { "<name> expected",
      "syntax",
      "an identifier was expected here (e.g. after `local`, `function`, or\n"
      "before `=` in an assignment). you may be using a reserved word as a\n"
      "name -- `end`, `then`, `local`, `nil`, `true`, `false`, and `goto`\n"
      "are all reserved.\n" },

    { "function arguments expected",
      "syntax",
      "a call must have arguments in one of these forms:\n"
      "  f(a, b)      -- parenthesised list\n"
      "  f\"literal\"   -- single string literal\n"
      "  f{ ... }     -- single table constructor\n"
      "a `:` method call still needs one of the three, e.g. `o:m()`.\n" },

    /* ------------------------------------------------------------------ */
    /* Runtime type errors -- caught by the compiler's constant folder or */
    /* by the interpreter when a chunk is compiled+executed via `load`.   */
    /* ------------------------------------------------------------------ */

    { "attempt to call a nil value",
      "type",
      "the variable holds nil at the point of the call. common causes:\n"
      "  - the name is not defined in this scope; declare it with `local`\n"
      "    or `require` the module that provides it\n"
      "  - a typo in the name; Lua does NOT auto-correct globals\n"
      "  - the require path is wrong (check `--print-search-dirs`)\n"
      "  - the method was called with `.` instead of `:` on a table method\n" },

    { "attempt to index a nil value",
      "type",
      "you wrote `X.field` or `X[key]` where `X` is nil. common causes:\n"
      "  - `X` is a global that was never assigned (typo, missing `require`)\n"
      "  - a chained lookup: `a.b.c` where `a.b` is nil -- guard with\n"
      "    `local b = a.b; if b then ... end` or use `a.b and a.b.c`\n"
      "  - a module returned nothing (missing `return M` at end of file)\n" },

    { "attempt to index a number value",
      "type",
      "you tried `X.field` or `X[key]` on a number. Lua numbers do NOT have\n"
      "methods; you probably want a table or string. `math.floor(n)` and\n"
      "`tostring(n)` are the usual conversions.\n" },

    { "attempt to index a string value",
      "type",
      "strings ARE indexable via `s:method(...)` (the string library is\n"
      "attached as a metatable), but `s[1]` returns nil in stock Lua.\n"
      "use `s:sub(1, 1)` for the first character, or `string.byte(s, i)`\n"
      "for the byte value.\n" },

    { "attempt to index a boolean value",
      "type",
      "you tried `X.field` on true or false. this usually means an earlier\n"
      "assignment produced a boolean where you expected a table -- e.g.\n"
      "`local t = a == b` gives a bool, not a lookup result.\n" },

    { "attempt to index",
      "type",
      "indexing (`X.field` or `X[key]`) requires `X` to be a table, string,\n"
      "or a value with an `__index` metamethod. the message names the type\n"
      "the compiler saw at that site.\n" },

    { "attempt to perform arithmetic on",
      "type",
      "one of the operands to `+ - * / // % ^` is not a number and has no\n"
      "arithmetic metamethod. common causes:\n"
      "  - a value came from `io.read()` (returns a string; use tonumber)\n"
      "  - a table field was never set (nil is not a number)\n"
      "  - a boolean was mixed in accidentally (`x and y + 1`)\n" },

    { "attempt to concatenate",
      "type",
      "`..` needs two strings or numbers (or values with a `__concat`\n"
      "metamethod). nil and booleans cannot be concatenated -- wrap them\n"
      "with `tostring(x)` when building a message.\n" },

    { "attempt to compare",
      "type",
      "`<`, `<=`, `>`, `>=` require two numbers OR two strings of the same\n"
      "kind. mixing types raises this error. use `tonumber` / `tostring`\n"
      "to normalise, or `==` / `~=` if you only need equality.\n" },

    { "attempt to get length of",
      "type",
      "the `#` operator needs a string, a table, or a value with a\n"
      "`__len` metamethod. `#nil` is an error; guard with `x and #x`.\n"
      "on tables with holes, `#t` returns an arbitrary border -- prefer\n"
      "an explicit counter for sparse arrays.\n" },

    /* ------------------------------------------------------------------ */
    /* Scope, mutation, and goto/label rules.                             */
    /* ------------------------------------------------------------------ */

    { "attempt to assign to const variable",
      "scope",
      "a variable declared `local x <const> = ...` cannot be reassigned.\n"
      "either drop the `<const>` attribute, or store the new value in a\n"
      "different local.\n" },

    { "jumps into the scope of local",
      "scope",
      "a `goto` (or `continue`) crosses a `local` declaration between the\n"
      "jump and the label. Lua forbids this because the local would be\n"
      "uninitialised after the jump. move the label BEFORE the local, or\n"
      "move the local out of the jumped-over region.\n" },

    { "no visible label",
      "scope",
      "the label named in `goto NAME` was never defined in a scope that\n"
      "reaches this `goto`. labels are written `::name::` and are visible\n"
      "only inside the block that defines them (and its nested blocks).\n" },

    { "break outside loop",
      "scope",
      "`break` only works inside `while`, `repeat`, or `for`. if you meant\n"
      "to exit a function early, use `return` (with or without a value).\n" },

    { "continue outside loop",
      "scope",
      "`continue` only works inside `while`, `repeat`, or `for`. CLua adds\n"
      "`continue` as sugar for a per-iteration `goto`; the same scope rules\n"
      "apply as to `break`.\n" },

    { "multiple to-be-closed variables in local list",
      "scope",
      "only one variable in a `local a, b, c = ...` list may carry the\n"
      "`<close>` attribute. split the declaration:\n"
      "  local a <close> = openA()\n"
      "  local b <close> = openB()\n" },

    { "already defined on line",  /* "label 'X' already defined on line N" */
      "scope",
      "a `::label::` with this name is already defined in the same block.\n"
      "labels must be unique within their block (nested blocks may reuse\n"
      "the name, but this one collides).\n" },

    /* ------------------------------------------------------------------ */
    /* Hard limits -- these usually mean the source needs restructuring,  */
    /* not a syntax fix.                                                   */
    /* ------------------------------------------------------------------ */

    { "too many local variables",
      "limit",
      "one function has more than 200 active locals. Lua's per-function\n"
      "register file is fixed at 200 slots. split the function, or move\n"
      "state into a table and index it (`s.x`, `s.y`, ...).\n" },

    { "too many upvalues",
      "limit",
      "one function captures more than 255 distinct upvalues from its\n"
      "enclosing scopes. group them into a single table and capture that\n"
      "one table instead.\n" },

    { "too many constants",
      "limit",
      "one function's constant pool exceeded ~2^26 entries -- almost\n"
      "always a machine-generated file. split it, or hoist repeated\n"
      "literals into locals so they share a single constant slot.\n" },

    { "chunk has too many lines",
      "limit",
      "the source file exceeds Lua's per-chunk line limit. split the file\n"
      "into modules and `require` them.\n" },

    { "control structure too long",
      "limit",
      "a single `if`/`while`/`for` body compiles to more than the maximum\n"
      "branch distance. break the body into helper functions.\n" }
};

static const int kHintCount = ( int )( sizeof( kHints ) / sizeof( kHints[ 0 ] ) );

const char *LcDiag_LookupHint( const char *RawMsg, const char **CategoryOut ) {
    int I;
    if ( RawMsg == NULL ) { return NULL; }
    for ( I = 0; I < kHintCount; I++ ) {
        if ( strstr( RawMsg, kHints[ I ].Pattern ) != NULL ) {
            if ( CategoryOut != NULL ) { *CategoryOut = kHints[ I ].Category; }
            return kHints[ I ].Hint;
        }
    }
    return NULL;
}

int LcDiag_HintCount( void ) {
    return kHintCount;
}

const LC_DIAG_HINT_T *LcDiag_HintAt( int Index ) {
    if ( Index < 0 || Index >= kHintCount ) { return NULL; }
    return &kHints[ Index ];
}
