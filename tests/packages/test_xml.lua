-- tests/packages/test_xml.lua : xml parse/serialize round-trip. Compiled to a
-- standalone exe by the runner (which bundles the xml package) and run.
-- Regression: serialize(pretty=true) must NOT inject whitespace into mixed
-- content (a node with both text and element children) -- doing so corrupts
-- the text on round-trip.
local xml = require "xml"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_xml: " .. tostring(m)) end end

-- Mixed content: <p> has text children ("Hello ", " end") AND an element <b>.
local doc = xml.parse('<p>Hello <b>world</b> end</p>')
ok(xml.text(doc) == "Hello world end", "parsed mixed-content text is 'Hello world end'")

-- Pretty-serializing mixed content must keep it inline; round-trip text equal.
local pretty = xml.serialize(doc, { pretty = true })
local rt = xml.parse(pretty)
ok(xml.text(rt) == "Hello world end", "pretty round-trip text is 'Hello world end' (no injected whitespace)")
ok(xml.text(rt) == xml.text(doc),     "pretty round-trip preserves mixed-content text")

-- Pure-element tree still pretty-prints (indented, newlines) and round-trips.
local tree = xml.parse('<root><a>x</a><b>y</b></root>')
local ts = xml.serialize(tree, { pretty = true })
ok(ts:find("\n", 1, true) ~= nil,     "pure-element tree pretty-prints with newlines")
ok(ts:find("  <a>", 1, true) ~= nil,  "pure-element tree is indented")
local trt = xml.parse(ts)
ok(xml.text(xml.find(trt, "a")) == "x", "pure-element <a> round-trips to 'x'")
ok(xml.text(xml.find(trt, "b")) == "y", "pure-element <b> round-trips to 'y'")

if fails == 0 then print("[+] PASS test_xml") os.exit(0) else os.exit(1) end
