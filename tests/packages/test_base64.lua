-- tests/packages/test_base64.lua : base64 encode/decode round-trip + known vectors.
local base64 = require "base64"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_base64: " .. tostring(m)) end end

-- RFC 4648 known vectors
ok(base64.encode("Man")    == "TWFu",     "encode('Man') == 'TWFu'")
ok(base64.encode("Ma")     == "TWE=",     "encode('Ma') == 'TWE='")
ok(base64.encode("M")      == "TQ==",     "encode('M') == 'TQ=='")
ok(base64.encode("")       == "",         "encode('') == ''")
ok(base64.encode("foobar") == "Zm9vYmFy", "encode('foobar') == 'Zm9vYmFy'")

-- Decode known vectors
ok(base64.decode("TWFu")     == "Man",    "decode('TWFu') == 'Man'")
ok(base64.decode("TWE=")     == "Ma",     "decode('TWE=') == 'Ma'")
ok(base64.decode("TQ==")     == "M",      "decode('TQ==') == 'M'")
ok(base64.decode("")         == "",       "decode('') == ''")
ok(base64.decode("Zm9vYmFy") == "foobar", "decode('Zm9vYmFy') == 'foobar'")

-- Round-trip arbitrary binary-ish string
local bin = ""
for i = 0, 255 do bin = bin .. string.char(i) end
ok(base64.decode(base64.encode(bin)) == bin, "round-trip all 256 byte values")

-- URL-safe variant
local url_enc = base64.encode("\xFB\xFF", { url = true })
ok(url_enc:find("[+/]") == nil, "url-safe: no + or / chars")
ok(base64.decode(url_enc, { url = true }) == "\xFB\xFF", "url-safe round-trip")

-- no_padding option
local no_pad = base64.encode("Ma", { no_padding = true })
ok(no_pad == "TWE", "no_padding omits =")
ok(base64.decode(no_pad) == "Ma", "decode tolerates missing padding")

if fails == 0 then print("[+] PASS test_base64") os.exit(0) else os.exit(1) end
