-- tests/packages/test_string_extra.lua : string_extra algorithms round-trip /
-- reference-value checks. Pure-Lua package (no DLL); the runner compiles it with
-- compiler.exe then runs it. Assertions use KNOWN-CORRECT reference values from
-- the literature (Levenshtein/Jaro/Soundex classics), not the code's own output.
local ok_req, string_extra = pcall(require, "string_extra")
if not ok_req then print("[~] SKIP test_string_extra") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_string_extra: " .. tostring(m)) end end

local function approx(a, b, eps) return math.abs(a - b) <= (eps or 1e-4) end

-- ===== Edit distances =====
ok(string_extra.levenshtein("kitten", "sitting") == 3, "levenshtein kitten/sitting = 3")
ok(string_extra.levenshtein("", "abc") == 3,           "levenshtein empty->abc = 3")
ok(string_extra.levenshtein("abc", "") == 3,           "levenshtein abc->empty = 3")
ok(string_extra.levenshtein("abc", "abc") == 0,        "levenshtein identical = 0")
ok(string_extra.levenshtein("flaw", "lawn") == 2,      "levenshtein flaw/lawn = 2")

-- Damerau (optimal string alignment): adjacent transposition costs 1
ok(string_extra.damerau_levenshtein("ca", "ac") == 1,  "damerau ca/ac = 1 (transpose)")
ok(string_extra.levenshtein("ca", "ac") == 2,          "plain levenshtein ca/ac = 2 (no transpose)")
ok(string_extra.damerau_levenshtein("abc", "abc") == 0, "damerau identical = 0")
ok(string_extra.damerau == string_extra.damerau_levenshtein, "damerau alias present")

-- Hamming: equal length required; errors otherwise
ok(string_extra.hamming("karolin", "kathrin") == 3,    "hamming karolin/kathrin = 3")
ok(string_extra.hamming("1011101", "1001001") == 2,    "hamming bitstrings = 2")
ok(not pcall(string_extra.hamming, "ab", "abc"),       "hamming errors on length mismatch")

-- ===== Jaro / Jaro-Winkler =====
ok(approx(string_extra.jaro("MARTHA", "MARHTA"), 0.944444), "jaro MARTHA/MARHTA ~ 0.9444")
ok(string_extra.jaro("abc", "abc") == 1.0,             "jaro identical = 1")
ok(string_extra.jaro("", "abc") == 0.0,                "jaro empty = 0")
ok(string_extra.jaro("abc", "xyz") == 0.0,             "jaro disjoint = 0")
-- jaro_winkler adds prefix bonus: MARTHA/MARHTA share prefix "MAR" (l=3)
-- jw = jaro + 3*0.1*(1-jaro) = 0.94444 + 0.3*0.055556 = 0.96111
ok(approx(string_extra.jaro_winkler("MARTHA", "MARHTA"), 0.961111), "jaro_winkler MARTHA/MARHTA ~ 0.9611")
ok(string_extra.jaro_winkler("abc", "abc") == 1.0,     "jaro_winkler identical = 1")

-- ===== Soundex (American Soundex, classic references) =====
ok(string_extra.soundex("Robert") == "R163",  "soundex Robert = R163")
ok(string_extra.soundex("Rupert") == "R163",  "soundex Rupert = R163")
ok(string_extra.soundex("Ashcraft") == "A261", "soundex Ashcraft = A261 (H/W rule)")
ok(string_extra.soundex("Tymczak") == "T522", "soundex Tymczak = T522")
ok(string_extra.soundex("Pfister") == "P236", "soundex Pfister = P236")
ok(string_extra.soundex("") == "0000",        "soundex empty = 0000")
ok(string_extra.soundex("Lee") == "L000",     "soundex Lee = L000")

-- ===== Cosine similarity over char n-grams =====
ok(approx(string_extra.cosine_similarity("abc", "abc"), 1.0), "cosine identical = 1")
ok(string_extra.cosine_similarity("abc", "xyz") == 0.0, "cosine disjoint = 0")
do
  -- bigrams of "night": ni,ig,gh,ht ; "nacht": na,ac,ch,ht ; share only "ht"
  -- dot=1, mag_a=4, mag_b=4 -> 1/(2*2) = 0.25
  local c = string_extra.cosine_similarity("night", "nacht", 2)
  ok(approx(c, 0.25), "cosine night/nacht bigram = 0.25")
end

-- ===== fuzzy_match (2-arg string form) =====
do
  local matched, score = string_extra.fuzzy_match("abc", "xxabcxx")
  ok(matched == true, "fuzzy_match subsequence found")
  ok(type(score) == "number" and score > 0, "fuzzy_match returns positive score")
  local m2 = string_extra.fuzzy_match("xyz", "abc")
  ok(m2 == false, "fuzzy_match non-subsequence = false")
  local m3 = string_extra.fuzzy_match("", "anything")
  ok(m3 == true, "fuzzy_match empty query = true")
end

-- fuzzy_match (list form) -> sorted results, highest score first
do
  local res = string_extra.fuzzy_match("fb", { "foobar", "xyzzy", "fizzbuzz" })
  ok(type(res) == "table", "fuzzy_match list returns table")
  ok(#res == 2, "fuzzy_match list keeps only matches (foobar, fizzbuzz)")
  ok(res[1].score >= res[2].score, "fuzzy_match list sorted descending")
  local limited = string_extra.fuzzy_match("fb", { "foobar", "fizzbuzz" }, { limit = 1 })
  ok(#limited == 1, "fuzzy_match list honors limit")
end

-- ===== tokenize =====
do
  local toks = string_extra.tokenize("Hello, World! Foo")
  ok(#toks == 3, "tokenize splits on punctuation/space -> 3 tokens")
  ok(toks[1] == "hello" and toks[2] == "world" and toks[3] == "foo", "tokenize lowercases by default")
  local toks2 = string_extra.tokenize("Hello World", { lowercase = false })
  ok(toks2[1] == "Hello" and toks2[2] == "World", "tokenize lowercase=false preserves case")
  local toks3 = string_extra.tokenize("the cat and a dog", { stopwords = true })
  -- stopwords: the, and, a removed -> cat, dog
  ok(#toks3 == 2 and toks3[1] == "cat" and toks3[2] == "dog", "tokenize removes default stopwords")
end

-- ===== ngrams =====
do
  local g = string_extra.ngrams("abcd", 2)
  ok(#g == 3, "ngrams abcd n=2 -> 3 grams")
  ok(g[1] == "ab" and g[2] == "bc" and g[3] == "cd", "ngrams values correct")
  ok(#string_extra.ngrams("ab", 3) == 0, "ngrams shorter than n -> empty")
end

-- ===== LCS / LCSubstring =====
do
  local s, len, ai, bi = string_extra.longest_common_substring("abcdef", "zabcz")
  ok(s == "abc" and len == 3, "longest_common_substring abc")
  ok(ai == 1, "lcsubstring start index in a")
  ok(string_extra.longest_common_substring("", "x") == "", "lcsubstring empty input")
end
do
  -- classic LCS example: ABCBDAB vs BDCAB -> "BCAB" (length 4)
  local lcs = string_extra.longest_common_subsequence("ABCBDAB", "BDCAB")
  ok(#lcs == 4, "longest_common_subsequence length = 4")
  -- it must be a subsequence of both
  ok(lcs == "BCAB" or lcs == "BDAB", "lcs is a valid optimal subsequence")
  ok(string_extra.longest_common_subsequence("abc", "abc") == "abc", "lcs identical")
end

-- ===== Whitespace / layout =====
ok(string_extra.trim("  hi  ") == "hi",     "trim both sides")
ok(string_extra.ltrim("  hi  ") == "hi  ",  "ltrim left only")
ok(string_extra.rtrim("  hi  ") == "  hi",  "rtrim right only")
ok(string_extra.trim("nospace") == "nospace", "trim no-op when no whitespace")

ok(string_extra.pad_left("7", 3, "0") == "007",   "pad_left zero-fill")
ok(string_extra.pad_right("7", 3, "0") == "700",  "pad_right zero-fill")
ok(string_extra.pad_left("toolong", 3) == "toolong", "pad_left no-op when long enough")
ok(string_extra.center("ab", 6) == "  ab  ",  "center even pad")
ok(string_extra.center("ab", 5) == " ab  ",   "center odd pad (extra on right)")

ok(string_extra.capitalize("hELLO") == "Hello", "capitalize first up rest down")
ok(string_extra.capitalize("") == "",           "capitalize empty")

ok(string_extra.count_substring("ababab", "ab") == 3,  "count_substring non-overlapping")
ok(string_extra.count_substring("aaaa", "aa") == 2,    "count_substring stride by match len")
ok(string_extra.count_substring("abc", "z") == 0,      "count_substring absent = 0")

ok(string_extra.replace_all("a.b.c", ".", "-") == "a-b-c", "replace_all plain (no pattern magic)")
ok(string_extra.replace_all("hello", "l", "L") == "heLLo", "replace_all multiple")
ok(string_extra.replace_all("abc", "x", "y") == "abc",     "replace_all no match unchanged")

-- ===== splitlines =====
do
  local lines = string_extra.splitlines("a\nb\r\nc\rd")
  ok(#lines == 4, "splitlines handles \\n, \\r\\n, \\r -> 4 lines")
  ok(lines[1] == "a" and lines[2] == "b" and lines[3] == "c" and lines[4] == "d", "splitlines values")
end

-- ===== dedent / indent =====
do
  local d = string_extra.dedent("    a\n      b")
  ok(d == "a\n  b", "dedent removes common leading whitespace")
  local id = string_extra.indent("a\nb", ">> ")
  ok(id == ">> a\n>> b", "indent prefixes every line")
end

-- ===== wordwrap =====
do
  local w = string_extra.wordwrap("aaa bbb ccc", 7)
  -- "aaa bbb" = 7 fits; ccc on next line
  ok(w == "aaa bbb\nccc", "wordwrap breaks at width")
end

-- ===== words iterator =====
do
  local got = {}
  for word in string_extra.words("foo bar baz") do got[#got + 1] = word end
  ok(#got == 3 and got[1] == "foo" and got[3] == "baz", "words iterator yields each word")
end

-- ===== metaphone / double_metaphone (sanity, deterministic) =====
do
  -- Textbook-clean metaphone codes (unambiguous reference values):
  ok(string_extra.metaphone("Phone") == "FN",  "metaphone Phone = FN (PH->F)")
  ok(string_extra.metaphone("Fish") == "FX",   "metaphone Fish = FX (SH->X)")
  ok(string_extra.metaphone("Knight") == "NT", "metaphone Knight = NT (silent K, silent GH)")
  ok(string_extra.metaphone("Smith") == "SM0", "metaphone Smith = SM0 (TH->0)")
  ok(string_extra.metaphone("") == "", "metaphone empty = empty")
  local p, a = string_extra.double_metaphone("Smith")
  ok(type(p) == "string" and type(a) == "string", "double_metaphone returns two strings")
  ok(p == string_extra.metaphone("Smith"), "double_metaphone primary == metaphone")
end

if fails == 0 then print("[+] PASS test_string_extra") os.exit(0) else os.exit(1) end
