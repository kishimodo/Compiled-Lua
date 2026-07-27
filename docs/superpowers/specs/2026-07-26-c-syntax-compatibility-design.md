# C-style syntax compatibility for CLua

Design approved 2026-07-26. Adds C-familiar surface syntax to CLua as **pure
sugar**: `&&`, `||`, `!`, `!=`, `/* */`, `continue`, a ternary, and compound
assignment. Inspired by Garry's Mod GLua, but CLua is Lua 5.4 rather than 5.1, and
two of GLua's extensions are impossible here as a result.

## Goal and non-goal

**Goal.** A C or C-family programmer can write CLua without first learning Lua's
spelling of the operators, and the constructs that Lua genuinely lacks
(`continue`, a non-broken conditional expression, compound assignment) become
available.

**Non-goal.** Changing semantics. Every construct here desugars to something Lua
5.4 already expresses, and must emit **byte-identical bytecode** to that spelling.
No new opcodes, no runtime support, no change to the emitted binary's behaviour.

That constraint is what keeps the differential suite meaningful. Both the compiler
and the reference interpreter share `lua-5.4/src/llex.c` and `lparser.c`, so they
gain the syntax together — which is only safe *because* the semantics are
unchanged. If any item here required a semantic change it would be out of scope.

## Compatibility proof

Every new token sequence is **currently a syntax error**, verified against a
reference Lua 5.4 built from `lua-5.4/src`:

| Input | Lua 5.4 today |
|---|---|
| `1 & & 2` | `unexpected symbol near '&'` |
| `1 \| \| 2` | `unexpected symbol near '\|'` |
| `6 / *2` | `unexpected symbol near '*'` |
| `!true` | `unexpected symbol near '!'` |
| `1 != 2` | `')' expected near '!'` |
| `a += 1` | `syntax error near '+'` |
| `true ? 1 : 2` | `')' expected near '?'` |

So **no currently-valid Lua program can change meaning.** The existing operators
these are adjacent to keep working: `6 // 2` → `3`, `1 & 2` → `0`, `1 | 2` → `3`.

## What is impossible, and why

Recorded so it is not re-proposed.

- **`//` line comments.** `//` is floor division in Lua 5.4
  (`llex.c:505` → `TK_IDIV`). GLua is based on 5.1, which has no `//` operator, so
  it was free there. Block comments `/* */` are provided instead.
- **`--` decrement.** `--` starts a Lua comment. Verified: `a--` on its own line
  swallows the rest of the line and the *following* statement produces the syntax
  error. This is the worst possible failure mode — the statement silently vanishes
  — so `--` must never be repurposed.
- **`++` increment.** Possible in isolation, but shipping it without `--` is an
  asymmetry users trip over once and remember as a wart. `+= 1` and `-= 1` cover
  the need symmetrically. Excluded by decision, not by constraint.

## Lexer additions (`lua-5.4/src/llex.c`)

| Input | Token | Existing meaning preserved |
|---|---|---|
| `&&` | `TK_AND` | `&` alone stays bitwise-and |
| `\|\|` | `TK_OR` | `\|` alone stays bitwise-or |
| `!` | `TK_NOT` | — (`!` is unused in Lua) |
| `!=` | `TK_NE` | `~=` continues to work |
| `/* … */` | skipped | `/` stays division, `//` stays floor division |
| `+= -= *= /= //= %= ^= ..= &= \|= <<= >>=` | new tokens | each base operator unchanged |

`/* */` does **not** nest, matching C. An unterminated block comment reports the
line the comment *opened* on, the way Lua already does for unterminated long
strings.

## Parser additions (`lua-5.4/src/lparser.c`)

### `continue` — contextual keyword

Lua 5.4 already implements `break` as a goto to a synthetic label: `breakstat`
(`lparser.c:1438-1441`) calls `newgotoentry(ls, "break", line, luaK_jump(ls->fs))`,
and loops call `createlabel(ls, "break", 0, 0)` at `:680`. `continue` uses the same
machinery with the label at the **end of the loop body** rather than after the loop.

**Contextual, not reserved.** `continue` is a keyword only as the first token of a
statement inside a loop body. This is required, not merely nice:
`clua/src/runtime/packages/repl_debug/init.lua:497` defines `function M.continue()`
today, and a reserved word would break it — along with any of the 685 in-tree
`.lua` files or 195 packages using the name. All of these must keep parsing:

```lua
function M.continue() end     local continue = 1        t.continue = 2
t["continue"]                 continue = 5              continue(1)
local x = continue            return continue
```

**`repeat … until c`** places the label *before* the condition, so `continue`
re-tests it — matching C's `do`/`while`. The interaction with `until`'s ability to
see body locals needs care and is the one place the design may have to fall back
to an explicit error.

**Binding.** Innermost enclosing loop. `continue` inside a function nested in a
loop must not bind to the outer loop's label — `break` already handles this via
function-state boundaries and the same mechanism applies. `continue` outside any
loop is an error naming the problem.

**Existing `::continue::`.** The idiom already in use
(`tests/lua/test_goto.lua:91`) uses that exact label name, so collision behaviour
must be defined rather than discovered.

### Ternary `a ? b : c`

Lowest precedence, below `or`. Right-associative, so `a ? b : c ? d : e` groups as
`a ? b : (c ? d : e)`.

**`:` always terminates the true-branch.** A method call in the middle must be
parenthesised:

```lua
a ? x : c          -- x is the value
a ? (x:y()) : c    -- method call, parenthesised
a ? x:y() : c      -- error, with a message naming the parenthesis fix
```

**The falsy case is the whole point.** `a and b or c` yields `c` when `b` is
`false` or `nil` — verified: `c and b or "FALSY-TRAP"` printed `FALSY-TRAP` with
`b = false`. The ternary must **not** inherit that: `a ? false : "x"` yields
`false`. So the lowering must be if/else-shaped, not `and`/`or`-shaped, and that is
the specific thing to test.

### Compound assignment

`+= -= *= /= //= %= ^= ..= &= |= <<= >>=`, single target only. Multiple targets
(`a, b += 1, 2`) are an error — C has no multiple assignment and the semantics
would be invented.

**The target is evaluated exactly once.** `t[f()] += 1` calls `f()` once. Naive
desugaring to `t[f()] = t[f()] + 1` would call it twice and is wrong. The LHS
`expdesc` already holds the table and key, so the value is read from it and stored
back without re-evaluating either — noting that `luaK_dischargevars`,
`luaK_exp2anyreg` and `luaK_storevar` *mutate* the `expdesc`, which is the hazard
to design around.

`a ..= b .. c` means `a = a .. (b .. c)`, following concat's right-associativity.
Metamethods (`__add`, `__concat`, `__index`, `__newindex`) fire exactly as in the
expanded form — for an indexed target that means the read and the write remain
separate metamethod calls. `a += 1` on a `<const>` or `<close>` local errors
exactly as `a = a + 1` does.

## Testing

The invariant makes this mechanically checkable. For each pair, both spellings must
produce **identical bytecode**:

| Sugar | Lua spelling |
|---|---|
| `a && b` | `a and b` |
| `a \|\| b` | `a or b` |
| `!x` | `not x` |
| `a != b` | `a ~= b` |
| `i += 1` | `i = i + 1` |
| `t[f()] += 1` | read-modify-write with **one** `f()` call |
| `continue` | `goto continue` + `::continue::` at body end |
| `a ? b : c` | `local r; if a then r = b else r = c end` shape |

Compare with `luac -l` output, or by diffing emitted `.text`. This is stronger than
"the suite passes": it proves the sugar is sugar.

Plus: every construct as a **differential** test (compiled vs oracle at O0–O3); a
compatibility test asserting the `continue`-as-identifier forms above still parse;
`a ? false : "x"` yielding `false`; and an unterminated `/*` reporting the opening
line.

## Also in scope

The lint package's private lexer
(`clua/src/runtime/packages/lint/init.lua`, keyword table at `:63`, `lex()` at
`:70`) needs the same tokens or the linter will flag valid code. It is a runtime
package and not wired into the compiler, so it cannot cause a miscompile — but a
linter that lies about the language it lints is worse than no linter.

## Out of scope

- A `--c-syntax` opt-in flag or per-file pragma. The syntax is always available.
  Two dialects would mean every tool tracks which mode a file is in, which is the
  complexity `clua/src/fe/` exists to remove.
- Changing `resolve.c`. It scans **bytecode** (`GETTABUP` constants), not source,
  so it is unaffected by any surface-syntax change.

## Ecosystem note

Code using `&&` will not run on stock Lua. That is a real cost and it is accepted
deliberately: the constructs are additive, standard Lua remains valid CLua, and the
sugar is confined to the front end so the emitted binary is indistinguishable.
