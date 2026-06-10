-- tests/packages/test_color.lua : the `color` package is an ANSI styling helper
-- (NOT a colorspace-conversion lib). We assert the exact SGR escape sequences it
-- emits, the strip() inverse, hex->rgb parsing (incl. #abc shorthand), and
-- visible_width -- all against the ANSI spec, not the code's own output.
local ok_req, color = pcall(require, "color")
if not ok_req then print("[~] SKIP test_color") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_color: " .. tostring(m)) end end

local ESC = string.char(27)
local CSI = ESC .. "["

-- color.reset is the canonical ANSI reset sequence.
ok(color.reset == CSI .. "0m", "reset is ESC[0m")

-- supports_color() gates whether wrap helpers emit codes or pass through. We
-- branch on it so the test is deterministic under NO_COLOR / pipes / etc.
local lit = color.supports_color()

-- ---- rgb / hex / color256 closures: exact SGR per ECMA-48 truecolor (38;2;r;g;b)
local function styled(fn_result) return (fn_result) end  -- identity, names intent

if lit then
  ok(color.rgb(255, 0, 0)("X") == CSI .. "38;2;255;0;0m" .. "X" .. color.reset,
     "rgb(255,0,0) emits 38;2;255;0;0")
  ok(color.rgb_bg(0, 128, 64)("X") == CSI .. "48;2;0;128;64m" .. "X" .. color.reset,
     "rgb_bg emits 48;2;r;g;b")
  ok(color.color256(196)("X") == CSI .. "38;5;196m" .. "X" .. color.reset,
     "color256 emits 38;5;n")
  ok(color.color256_bg(21)("X") == CSI .. "48;5;21m" .. "X" .. color.reset,
     "color256_bg emits 48;5;n")
  -- 16-color foreground/background + an attribute, known SGR codes.
  ok(color.red("X")    == CSI .. "31m" .. "X" .. color.reset, "red fg = 31")
  ok(color.green("X")  == CSI .. "32m" .. "X" .. color.reset, "green fg = 32")
  ok(color.bg.blue("X")== CSI .. "44m" .. "X" .. color.reset, "blue bg = 44")
  ok(color.bold("X")   == CSI .. "1m"  .. "X" .. color.reset, "bold = 1")
  ok(color.underline("X") == CSI .. "4m" .. "X" .. color.reset, "underline = 4")
  -- bright variants live in the 90s (fg) / 100s (bg).
  ok(color.bright_red("X") == CSI .. "91m" .. "X" .. color.reset, "bright_red fg = 91")
else
  -- No color support => helpers must return the payload unchanged.
  ok(color.rgb(255,0,0)("X") == "X", "rgb passthrough when no color")
  ok(color.red("X") == "X",          "red passthrough when no color")
  ok(color.bold("X") == "X",         "bold passthrough when no color")
end

-- ---- hex() must delegate to rgb() with the parsed channels. Compare the two
-- closures' output so this holds regardless of supports_color() state.
ok(color.hex("#FF0000")("X") == color.rgb(255, 0, 0)("X"),
   "#FF0000 -> rgb(255,0,0)")
ok(color.hex("00FF00")("X") == color.rgb(0, 255, 0)("X"),
   "bare 00FF00 -> rgb(0,255,0)")
ok(color.hex("#0000ff")("X") == color.rgb(0, 0, 255)("X"),
   "lowercase #0000ff -> rgb(0,0,255)")
-- 3-digit shorthand: #abc expands to #aabbcc = rgb(170,187,204).
ok(color.hex("#abc")("X") == color.rgb(170, 187, 204)("X"),
   "#abc shorthand expands to aabbcc")
ok(color.hex("#fff")("X") == color.rgb(255, 255, 255)("X"),
   "#fff shorthand -> white")

-- ---- strip(): inverse of the wrappers; removes CSI and OSC sequences.
ok(color.strip(CSI .. "31m" .. "hello" .. color.reset) == "hello",
   "strip removes CSI fg sequence")
ok(color.strip(CSI .. "38;2;1;2;3m" .. "x" .. CSI .. "0m") == "x",
   "strip removes truecolor sequence")
-- OSC title set: ESC ] 0 ; title BEL  then visible body.
ok(color.strip(ESC .. "]0;title" .. string.char(7) .. "body") == "body",
   "strip removes OSC ... BEL")
ok(color.strip("plain") == "plain", "strip leaves plain text intact")
-- Round-trip: strip(style(s)) == s for any payload, color or not.
ok(color.strip(color.rgb(10, 20, 30)("payload")) == "payload",
   "strip(rgb(...)) round-trips to payload")
ok(color.strip(color.bold("payload")) == "payload",
   "strip(bold(...)) round-trips to payload")
ok(color.strip(color.color256(99)("payload")) == "payload",
   "strip(color256(...)) round-trips to payload")

-- ---- visible_width(): visible cell count == byte length of stripped ASCII.
ok(color.visible_width(color.rgb(1, 2, 3)("hello")) == 5,
   "visible_width ignores escapes (hello = 5)")
ok(color.visible_width(color.red(color.bold("abcd"))) == 4,
   "visible_width of nested styles (abcd = 4)")
ok(color.visible_width("") == 0, "visible_width of empty = 0")

if fails == 0 then print("[+] PASS test_color") os.exit(0) else os.exit(1) end
