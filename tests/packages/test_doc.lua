-- tests/packages/test_doc.lua : doc-comment extractor (extract / render_*).
-- Deterministic: extracts from fixed source strings; we assert exact node fields
-- and render outputs that don't depend on iteration order (single module).
local ok_req, doc = pcall(require, "doc")
if not ok_req then print("[~] SKIP test_doc (" .. tostring(doc) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_doc: " .. tostring(m)) end end

-- ===== extract: a --- run preceding a function =====
local src1 = table.concat({
  "--- Adds two numbers.",
  "--- @param a (number) first addend",
  "--- @param b (number) second addend",
  "--- @return (number) the sum",
  "function add(a, b) return a + b end",
}, "\n")
-- extract() has a path/source heuristic: a string with a newline is treated as
-- source, which this is.
local nodes1 = doc.extract(src1)
ok(type(nodes1) == "table",                  "extract returns a table")
ok(#nodes1 == 1,                             "one doc node from one block")
local n1 = nodes1[1]
ok(n1.kind == "function",                    "node kind is function")
ok(n1.name == "add",                         "node name is add")
ok(n1.signature == "add(a, b)",              "signature captured")
ok(n1.description == "Adds two numbers.",    "description captured")
ok(#n1.params == 2,                          "two @param entries")
ok(n1.params[1].name == "a",                 "first param name")
ok(n1.params[1].type == "number",            "first param type from (number)")
ok(n1.params[1].description == "first addend", "first param description")
ok(#n1.returns == 1,                         "one @return entry")
ok(n1.returns[1].type == "number",           "return type captured")

-- ===== extract: tags @since @deprecated @see @throws =====
local src2 = table.concat({
  "--- Risky op.",
  "--- @since 1.2",
  "--- @deprecated use safe_op instead",
  "--- @see safe_op",
  "--- @throws (error) when input is nil",
  "function risky() end",
}, "\n")
local n2 = doc.extract(src2)[1]
ok(n2.since == "1.2",                         "@since recorded")
ok(n2.deprecated == "use safe_op instead",    "@deprecated text recorded")
ok(#n2.see == 1 and n2.see[1] == "safe_op",   "@see target recorded")
ok(#n2.throws == 1,                           "one @throws entry")
ok(n2.throws[1].type == "error",              "@throws type from (error)")

-- ===== extract: @module sets grouping =====
local src3 = table.concat({
  "--- @module mymod",
  "--- The module.",
  "local M = {}",
  "",
  "--- A function in the module.",
  "function M.f() end",
}, "\n")
local nodes3 = doc.extract(src3)
ok(#nodes3 >= 2,                              "module + function nodes extracted")
-- every node after the @module declaration carries module = mymod
local fnode
for _, n in ipairs(nodes3) do
  if n.name == "M.f" then fnode = n end
end
ok(fnode ~= nil,                              "found M.f node")
ok(fnode.module == "mymod",                   "function inherits @module name")

-- ===== extract: --[[doc ... ]] long block =====
local src4 = table.concat({
  "--[[doc",
  "Long form description.",
  "@param x (string) the input",
  "]]",
  "function longform(x) end",
}, "\n")
local n4 = doc.extract(src4)[1]
ok(n4.description == "Long form description.", "long-block description")
ok(n4.name == "longform",                     "long-block signature parsed")
ok(#n4.params == 1 and n4.params[1].name == "x", "long-block param parsed")

-- ===== extract: @example block =====
local src5 = table.concat({
  "--- Has an example.",
  "--- @example",
  "--- local r = ex(1)",
  "--- print(r)",
  "function ex(n) return n end",
}, "\n")
local n5 = doc.extract(src5)[1]
ok(#n5.examples == 1,                         "one example captured")
ok(n5.examples[1] == "local r = ex(1)\nprint(r)", "example body lines joined")

-- ===== render_markdown =====
local md = doc.render_markdown(nodes1)
ok(type(md) == "string",                      "render_markdown returns string")
ok(md:find("### `add(a, b)`", 1, true) ~= nil, "markdown heading uses signature")
ok(md:find("Adds two numbers.", 1, true) ~= nil, "markdown includes description")
ok(md:find("**Parameters**", 1, true) ~= nil, "markdown has Parameters section")
ok(md:find("**Returns**", 1, true) ~= nil,    "markdown has Returns section")

-- ===== render_html =====
local html = doc.render_html(nodes1, { title = "API" })
ok(html:find("<!doctype html>", 1, true) ~= nil, "html has doctype")
ok(html:find("<h1>API</h1>", 1, true) ~= nil, "html title rendered")
ok(html:find("<code>add(a, b)</code>", 1, true) ~= nil, "html shows signature in code")

-- ===== render via M.render dispatch =====
local md2 = doc.render(nodes1, "markdown")
ok(md2 == md,                                 "render('markdown') equals render_markdown")
local ok_bad = pcall(doc.render, nodes1, "bogusfmt")
ok(ok_bad == false,                           "render rejects unknown format")

-- ===== xref resolution in descriptions =====
local src6 = table.concat({
  "--- See [[other.thing]] for details.",
  "function withref() end",
}, "\n")
local md6 = doc.render_markdown(doc.extract(src6))
ok(md6:find("[`other.thing`]", 1, true) ~= nil, "[[ref]] becomes markdown link")

if fails == 0 then print("[+] PASS test_doc") os.exit(0) else os.exit(1) end
