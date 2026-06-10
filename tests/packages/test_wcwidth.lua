-- tests/packages/test_wcwidth.lua : display-width of Unicode codepoints/UTF-8
-- strings. Asserts against KNOWN-CORRECT reference values per Markus Kuhn's
-- wcwidth spec (ASCII=1, CJK/emoji/fullwidth=2, combining/NUL=0, controls=-1)
-- and against round-trip sums (wcswidth). Pure-Lua, no DLL needed.
local ok_req, wcwidth = pcall(require, "wcwidth")
if not ok_req then print("[~] SKIP test_wcwidth") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_wcwidth: " .. tostring(m)) end end

-- width() by codepoint number ------------------------------------------------
ok(wcwidth.width(0x41) == 1,    "ASCII 'A' is width 1")
ok(wcwidth.width(0x20) == 1,    "space is width 1")
ok(wcwidth.width(0x4E2D) == 2,  "CJK U+4E2D is wide (2)")
ok(wcwidth.width(0xFF21) == 2,  "Fullwidth 'A' U+FF21 is wide (2)")
ok(wcwidth.width(0x0301) == 0,  "combining acute U+0301 is zero-width")
ok(wcwidth.width(0x0000) == 0,  "NUL is zero-width (special-cased)")
ok(wcwidth.width(0x0001) == -1, "control U+0001 is -1")
ok(wcwidth.width(0x0009) == -1, "tab U+0009 is -1 (control)")
ok(wcwidth.width(0x007F) == -1, "DEL U+007F is -1")
ok(wcwidth.width(0x009F) == -1, "C1 control U+009F is -1")
ok(wcwidth.width(0x1F600) == 2, "emoji U+1F600 is wide (2)")

-- width() by 1 UTF-8 char string ---------------------------------------------
ok(wcwidth.width("A") == 1,                "width('A') == 1")
ok(wcwidth.width(utf8.char(0x4E2D)) == 2,  "width(utf8 CJK) == 2")
ok(wcwidth.width(utf8.char(0x0301)) == 0,  "width(utf8 combining) == 0")

-- wcwidth() alias matches width() semantics ----------------------------------
ok(wcwidth.wcwidth(0x41) == 1,   "wcwidth(0x41) == 1")
ok(wcwidth.wcwidth(0x4E2D) == 2, "wcwidth(0x4E2D) == 2")

-- is_wide --------------------------------------------------------------------
ok(wcwidth.is_wide(0x4E2D) == true,            "is_wide CJK")
ok(wcwidth.is_wide(0x41) == false,             "is_wide ASCII false")
ok(wcwidth.is_wide(utf8.char(0x4E2D)) == true, "is_wide(utf8 CJK)")

-- is_emoji -------------------------------------------------------------------
ok(wcwidth.is_emoji(0x1F600) == true, "is_emoji grinning face")
ok(wcwidth.is_emoji(0x41) == false,   "is_emoji ASCII false")

-- wcswidth(): sum of display width across a UTF-8 string ----------------------
ok(wcwidth.wcswidth("hello") == 5, "wcswidth ascii 'hello' == 5")
local mixed = "a" .. utf8.char(0x4E2D) .. "b"   -- 1 + 2 + 1
ok(wcwidth.wcswidth(mixed) == 4,   "wcswidth 'a<CJK>b' == 4")
local accented = "e" .. utf8.char(0x0301)       -- 1 + 0 (combining)
ok(wcwidth.wcswidth(accented) == 1, "wcswidth 'e' + combining mark == 1")
ok(wcwidth.wcswidth("a\tb") == 2,   "wcswidth treats control (tab) as 0 -> 2")
ok(wcwidth.wcswidth("\27[31mX\27[0m") == 1, "wcswidth strips ANSI CSI color -> 1")
ok(wcwidth.wcswidth("\27]0;title\7Y") == 1, "wcswidth strips ANSI OSC (BEL) -> 1")
ok(wcwidth.wcswidth("") == 0,       "wcswidth empty string == 0")

-- swidth is the back-compat alias of wcswidth --------------------------------
ok(wcwidth.swidth == wcwidth.wcswidth, "swidth is alias of wcswidth")
ok(wcwidth.swidth(mixed) == 4,         "swidth matches wcswidth")

if fails == 0 then print("[+] PASS test_wcwidth") os.exit(0) else os.exit(1) end
