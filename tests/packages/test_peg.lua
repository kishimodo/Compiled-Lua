local ok_req, peg = pcall(require, "peg")
if not ok_req then print("[~] SKIP test_peg") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_peg: " .. tostring(m)) end end

-- peg.match returns (captures, endpos). These helpers isolate one value each.
local function mend(g, s) local _, e = peg.match(g, s); return e end
local function mcaps(g, s) local c = peg.match(g, s); return c end

-- ===== lit ============================================================
do
    local caps, endpos = peg.match(peg.lit("hello"), "hello world")
    ok(endpos == 6, "lit: endpos after 'hello' should be 6, got " .. tostring(endpos))
    ok(caps ~= nil and #caps == 0, "lit: no captures emitted")

    local c2, e2 = peg.match(peg.lit("hello"), "goodbye")
    ok(c2 == nil and e2 == nil, "lit: mismatch returns nil,nil")
end

-- ===== range (incl bounds) ===========================================
do
    local digit = peg.range("0", "9")
    ok(mend(digit, "5") == 2, "range: '5' is a digit")
    ok(mend(digit, "0") == 2, "range: lower bound '0' inclusive")
    ok(mend(digit, "9") == 2, "range: upper bound '9' inclusive")
    ok(mend(digit, "a") == nil, "range: 'a' is not a digit")
    ok(mend(digit, "/") == nil, "range: '/' (0x2F) just below '0' fails")
    ok(mend(digit, ":") == nil, "range: ':' (0x3A) just above '9' fails")
    local byte_range = peg.range(48, 57)
    ok(mend(byte_range, "7") == 2, "range: numeric byte args 48..57 match '7'")
end

-- ===== set ============================================================
do
    local vowel = peg.set("aeiou")
    ok(mend(vowel, "e") == 2, "set: 'e' is in aeiou")
    ok(mend(vowel, "z") == nil, "set: 'z' not in aeiou")
    ok(mend(vowel, "") == nil, "set: EOF fails")
end

-- ===== any ============================================================
do
    ok(mend(peg.any(), "x") == 2, "any: matches a byte")
    ok(mend(peg.any(), "") == nil, "any: fails at EOF")
end

-- ===== seq (ordered concat + rollback) ===============================
do
    local ab = peg.seq(peg.lit("a"), peg.lit("b"))
    ok(mend(ab, "ab") == 3, "seq: 'ab' matches both, endpos 3")
    ok(mend(ab, "ax") == nil, "seq: 'ax' fails on second part")
    -- partial match must not advance pos / must roll back captures
    local caps = mcaps(peg.seq(peg.cap(peg.lit("a")), peg.lit("b")), "ax")
    ok(caps == nil, "seq: failed seq returns nil even though first capture matched")
end

-- ===== alt (first success wins) ======================================
do
    local a_or_b = peg.alt(peg.lit("a"), peg.lit("b"))
    ok(mend(a_or_b, "a") == 2, "alt: matches first branch 'a'")
    ok(mend(a_or_b, "b") == 2, "alt: matches second branch 'b'")
    ok(mend(a_or_b, "c") == nil, "alt: no branch matches 'c'")
    -- ordered: longer-prefix branch placed first wins
    local kw = peg.alt(peg.lit("class"), peg.lit("c"))
    ok(mend(kw, "class") == 6, "alt: ordered, 'class' branch consumes 5")
end

-- ===== star / plus / opt =============================================
do
    local zeros = peg.star(peg.lit("0"))
    ok(mend(zeros, "000x") == 4, "star: greedy consumes '000', endpos 4")
    ok(mend(zeros, "x") == 1, "star: zero matches succeeds, endpos 1")

    local ones = peg.plus(peg.lit("1"))
    ok(mend(ones, "111") == 4, "plus: consumes '111'")
    ok(mend(ones, "x") == nil, "plus: requires at least one")

    local maybe = peg.opt(peg.lit("-"))
    ok(mend(maybe, "-5") == 2, "opt: matches the '-'")
    ok(mend(maybe, "5") == 1, "opt: absent is fine, endpos 1")
end

-- ===== star zero-progress guard ======================================
do
    -- star of an opt (which always succeeds w/o consuming) must terminate.
    local g = peg.star(peg.opt(peg.lit("z")))
    local endpos = mend(g, "abc")
    ok(endpos == 1, "star: zero-progress inner parser terminates at pos 1, got " .. tostring(endpos))
    -- star of and_ (lookahead, never consumes) must also terminate, not hang.
    local g2 = peg.star(peg.and_(peg.any()))
    ok(mend(g2, "abc") == 1, "star: lookahead inner terminates")
end

-- ===== not_ / and_ (lookahead, never consume) ========================
do
    -- not_ followed by any: matches a byte that's NOT 'x'
    local not_x_then_any = peg.seq(peg.not_(peg.lit("x")), peg.any())
    ok(mend(not_x_then_any, "a") == 2, "not_: 'a' is not 'x', any consumes it")
    ok(mend(not_x_then_any, "x") == nil, "not_: lookahead on 'x' blocks")
    -- and_ followed by lit: positive lookahead doesn't consume
    local and_a_then_a = peg.seq(peg.and_(peg.lit("a")), peg.lit("a"))
    ok(mend(and_a_then_a, "a") == 2, "and_: positive lookahead, then lit consumes once")
    ok(mend(and_a_then_a, "b") == nil, "and_: lookahead fails on 'b'")
end

-- ===== cap / cap_pos =================================================
do
    local caps, endpos = peg.match(peg.cap(peg.lit("foo")), "foobar")
    ok(endpos == 4, "cap: endpos after 'foo' is 4")
    ok(caps and #caps == 1, "cap: one capture emitted")
    ok(caps and caps[1].value == "foo", "cap: captured raw text 'foo'")
    ok(caps and caps[1].kind == "str", "cap: kind is 'str'")
    ok(caps and caps[1].start == 1 and caps[1].finish == 3, "cap: start/finish span")

    local pcaps = mcaps(peg.seq(peg.lit("ab"), peg.cap_pos()), "abc")
    ok(pcaps and pcaps[1].kind == "pos" and pcaps[1].value == 3, "cap_pos: records pos 3 after 'ab'")
end

-- ===== char_class (ranges + negation) ================================
do
    -- NOTE: per source, char_class takes the *contents* (no surrounding []).
    local ident_head = peg.char_class("A-Za-z_")
    ok(mend(ident_head, "Q") == 2, "char_class: range A-Z matches 'Q'")
    ok(mend(ident_head, "q") == 2, "char_class: range a-z matches 'q'")
    ok(mend(ident_head, "_") == 2, "char_class: literal '_' matches")
    ok(mend(ident_head, "3") == nil, "char_class: '3' not in A-Za-z_")

    local not_digit = peg.char_class("^0-9")
    ok(mend(not_digit, "a") == 2, "char_class: negated ^0-9 matches 'a'")
    ok(mend(not_digit, "5") == nil, "char_class: negated ^0-9 rejects '5'")
    ok(mend(not_digit, "") == nil, "char_class: EOF fails even when negated")
end

-- ===== rep (bounded repetition) ======================================
do
    local two_to_three = peg.rep(peg.lit("a"), 2, 3)
    ok(mend(two_to_three, "a") == nil, "rep: below min(2) fails")
    ok(mend(two_to_three, "aa") == 3, "rep: exactly min consumes 2")
    ok(mend(two_to_three, "aaaa") == 4, "rep: capped at max(3), endpos 4")
    local at_least_one = peg.rep(peg.lit("b"), 1)
    ok(mend(at_least_one, "bbb") == 4, "rep: open max consumes all 'bbb'")
end

-- ===== identifier helper =============================================
do
    local id = peg.identifier()
    local caps, endpos = peg.match(id, "foo_bar9 rest")
    ok(endpos == 9, "identifier: 'foo_bar9' spans to pos 9, got " .. tostring(endpos))
    ok(caps and caps[1] and caps[1].value == "foo_bar9", "identifier: captured 'foo_bar9'")
    ok(mend(id, "9bad") == nil, "identifier: cannot start with a digit")
    ok(mend(id, "_x") ~= nil, "identifier: may start with underscore")
end

-- ===== number helper =================================================
do
    local num = peg.number()
    local function nval(s)
        local caps = peg.match(num, s)
        return caps and caps[1] and caps[1].value
    end
    ok(nval("123") == "123", "number: plain integer")
    ok(nval("-42") == "-42", "number: signed integer")
    ok(nval("3.14") == "3.14", "number: float")
    ok(nval("-0.5") == "-0.5", "number: signed float")
    ok(nval(".5") == ".5", "number: leading-dot float")
    ok(nval("1e10") == "1e10", "number: exponent")
    ok(nval("6.02e-23") == "6.02e-23", "number: float with signed exponent")
    -- must NOT match a bare sign or non-number
    ok(mend(num, "abc") == nil, "number: 'abc' is not a number")
    ok(mend(num, "-") == nil, "number: bare '-' is not a number")
end

-- ===== quoted_string helper ==========================================
do
    local qs = peg.quoted_string()
    local function qval(s)
        local caps = peg.match(qs, s)
        return caps and caps[1] and caps[1].value
    end
    ok(qval('"hi"') == '"hi"', "quoted_string: captures incl quotes")
    ok(qval('"a\\"b"') == '"a\\"b"', "quoted_string: backslash-escaped quote handled")
    ok(qval('"x" tail') == '"x"', "quoted_string: stops at closing quote")
    ok(mend(qs, '"unterminated') == nil, "quoted_string: unterminated fails")
    ok(mend(qs, "nope") == nil, "quoted_string: must start with a quote")
end

-- ===== grammar + ref (recursive) =====================================
do
    -- Balanced parens grammar:  S <- '(' S ')' S / epsilon
    local g = peg.grammar({
        start = peg.alt(
            peg.seq(peg.lit("("), peg.ref("start"), peg.lit(")"), peg.ref("start")),
            peg.lit("")),
    })
    ok(mend(g, "()") == 3, "grammar: '()' fully matches, endpos 3")
    ok(mend(g, "(())()") == 7, "grammar: nested balanced parens matches to end")
    -- partial: '(()' matches the empty alternative at pos 1
    ok(mend(g, "(()") == 1, "grammar: unbalanced '(()' falls back to empty match at pos 1")
end

-- ===== parse (AST + trailing-input detection) ========================
do
    -- A grammar that captures a single identifier.
    local g = peg.grammar({ start = peg.identifier() })
    local ast, err = peg.parse(g, "hello")
    ok(ast ~= nil and err == nil, "parse: clean parse returns ast, no err")
    ok(ast and ast.type == "root", "parse: root node type")
    ok(ast and ast.children and ast.children[1] and ast.children[1].value == "hello",
       "parse: ast child holds captured identifier")
    -- trailing input must be reported as an error
    local ast2, err2 = peg.parse(g, "hello world")
    ok(ast2 == nil and type(err2) == "string", "parse: trailing input is an error")
    ok(err2 and err2:find("trailing"), "parse: error mentions trailing input")
end

-- ===== group / named captures ========================================
do
    -- group p under a name; captures inside carry .group and land in ast.named
    local g = peg.grammar({
        start = peg.seq(
            peg.group(peg.cap(peg.lit("key")), "k"),
            peg.lit("="),
            peg.group(peg.cap(peg.lit("val")), "v")),
    })
    local ast, err = peg.parse(g, "key=val")
    ok(ast ~= nil and err == nil, "group: parse succeeds")
    ok(ast and ast.named and ast.named["k"] and ast.named["k"][1].value == "key",
       "group: 'k' bucket holds 'key'")
    ok(ast and ast.named and ast.named["v"] and ast.named["v"][1].value == "val",
       "group: 'v' bucket holds 'val'")
end

if fails == 0 then print("[+] PASS test_peg") os.exit(0) else os.exit(1) end
