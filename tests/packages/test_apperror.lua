-- tests/packages/test_apperror.lua : structured error type -- pure-Lua, no DLL.
-- Asserts constructor/field/wrap-unwrap/match/try behavior against known-correct
-- reference values (not the package's own stringified output).
local ok_req, apperror = pcall(require, "apperror")
if not ok_req then print("[~] SKIP test_apperror") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_apperror: " .. tostring(m)) end end

-- ===== new() from string =====
local e1 = apperror.new("boom")
ok(e1:message() == "boom",            "new(string) sets message")
ok(e1:kind() == nil,                  "new(string) has nil kind")
ok(e1:cause() == nil,                 "new(string) has no cause")
ok(type(e1:fields()) == "table",      "fields() is a table")
ok(next(e1:fields()) == nil,          "new(string) fields empty")
ok(apperror.is_apperror(e1) == true,  "is_apperror true for an err")
ok(apperror.is_apperror({}) == false, "is_apperror false for plain table")
ok(apperror.is_apperror("x") == false,"is_apperror false for string")

-- ===== new() from table =====
local e2 = apperror.new{ message = "no file", kind = "io.notfound", fields = { path = "/tmp/x" } }
ok(e2:message() == "no file",          "new(table) message")
ok(e2:kind() == "io.notfound",         "new(table) kind")
ok(e2:fields().path == "/tmp/x",       "new(table) fields preserved")
-- table form defaults message to "error" when absent
ok(apperror.new{}:message() == "error","new{} defaults message to 'error'")

-- ===== is(): exact + hierarchical prefix =====
ok(apperror.is(e2, "io.notfound") == true,  "is() exact kind")
ok(apperror.is(e2, "io") == true,           "is() dotted prefix matches")
ok(apperror.is(e2, "i") == false,           "is() non-segment prefix rejected")
ok(apperror.is(e2, "io.notfou") == false,   "is() partial segment rejected")
ok(apperror.is(e2, "net") == false,         "is() unrelated kind false")
ok(apperror.is(e1, "anything") == false,    "is() on nil-kind err false")
ok(apperror.is("not an err", "x") == false, "is() on non-apperror false")

-- ===== wrap(): cause chain + field/kind handling =====
local inner = apperror.new{ message = "disk gone", kind = "io.disk", fields = { dev = "sda" } }
local outer = apperror.wrap(inner, "could not save", { kind = "app.save", retry = 3 })
ok(outer:message() == "could not save", "wrap() outer message")
ok(outer:kind() == "app.save",          "wrap() kind taken from fields.kind")
ok(outer:fields().retry == 3,           "wrap() copies non-kind fields")
ok(outer:fields().kind == nil,          "wrap() does NOT store 'kind' as a field")
ok(outer:cause() == inner,              "wrap() sets cause to wrapped err")
ok(outer:cause():message() == "disk gone", "cause chain reaches inner message")

-- is() walks the chain: outer carries inner's kinds too
ok(apperror.is(outer, "app.save") == true, "is() finds outer kind in chain")
ok(apperror.is(outer, "io.disk") == true,  "is() finds wrapped inner kind in chain")
ok(apperror.is(outer, "io") == true,       "is() prefix-matches inner kind in chain")

-- wrap() lifts a non-apperror into the chain
local lifted = apperror.wrap("raw string error", "context here")
ok(lifted:message() == "context here",         "wrap(non-err) outer message")
ok(apperror.is_apperror(lifted:cause()),       "wrap(non-err) lifts cause to apperror")
ok(lifted:cause():message() == "raw string error", "lifted cause carries raw text")

-- ===== root_cause() / kinds() =====
ok(outer:root_cause() == inner,        "root_cause() returns deepest err")
ok(e1:root_cause() == e1,              "root_cause() of single err is itself")
local ks = outer:kinds()
ok(ks[1] == "app.save" and ks[2] == "io.disk" and #ks == 2, "kinds() collects chain kinds in order")

-- ===== get(): field lookup walks chain =====
ok(outer:get("retry") == 3,     "get() finds field on outer")
ok(outer:get("dev") == "sda",   "get() finds field on wrapped inner")
ok(outer:get("missing") == nil, "get() returns nil for absent field")

-- ===== with(): non-mutating field merge =====
local merged = outer:with{ user = "alice", retry = 9 }
ok(merged:get("user") == "alice",  "with() adds new field")
ok(merged:get("retry") == 9,       "with() overrides existing field")
ok(outer:get("retry") == 3,        "with() does not mutate the source err")
ok(merged ~= outer,                "with() returns a new err object")
ok(merged:cause() == inner,        "with() preserves the cause chain")

-- ===== match(): exact, longest-prefix, default =====
local hit = apperror.match(e2, {
  ["io.notfound"] = function() return "exact" end,
  ["io"]          = function() return "prefix" end,
  _               = function() return "default" end,
})
ok(hit == "exact", "match() prefers exact kind over prefix")

local hit2 = apperror.match(apperror.new{ message = "x", kind = "io.deep.err" }, {
  ["io"]      = function() return "short" end,
  ["io.deep"] = function() return "long" end,
})
ok(hit2 == "long", "match() picks longest prefix")

local hit3 = apperror.match(apperror.new("plain"), {
  ["io"] = function() return "io" end,
  _      = function() return "default" end,
})
ok(hit3 == "default", "match() falls through to default for kindless err")

local hit4 = apperror.match(apperror.new{ message = "x", kind = "weird" }, {
  ["io"] = function() return "io" end,
})
ok(hit4 == nil, "match() returns nil when nothing matches and no default")

-- match handler receives the OUTER err even when inner kind matched
local outer2 = apperror.wrap(apperror.new{ message = "i", kind = "io.x" }, "o", { kind = "app.y" })
local got_msg = apperror.match(outer2, { ["io.x"] = function(e) return e:message() end })
ok(got_msg == "o", "match() passes the outer err to the handler")

-- ===== try(): pcall wrapper =====
local okv, res = apperror.try(function() return 42 end)
ok(okv == true and res == 42, "try() returns true + value on success")
local okv2, val_a, val_b = apperror.try(function() return 1, 2 end)
ok(okv2 == true and val_a == 1 and val_b == 2, "try() returns multiple values")
local okv3, err3 = apperror.try(function() error("kaboom") end)
ok(okv3 == false,                       "try() returns false on throw")
ok(apperror.is_apperror(err3),          "try() lifts a thrown string into apperror")
ok(err3:kind() == "runtime",            "try() tags lifted error kind 'runtime'")
ok(err3:message():find("kaboom") ~= nil,"try() preserves thrown message text")
-- a thrown apperror passes through unchanged
local thrown = apperror.new{ message = "explicit", kind = "my.kind" }
local okv4, err4 = apperror.try(function() error(thrown) end)
ok(okv4 == false and err4 == thrown, "try() passes a thrown apperror through unchanged")

-- ===== from() =====
ok(apperror.from(e1) == e1,                       "from() returns apperror unchanged")
local lifted2 = apperror.from("oops", "parse")
ok(apperror.is_apperror(lifted2),                 "from() lifts raw to apperror")
ok(lifted2:kind() == "parse",                     "from() applies provided kind")
ok(lifted2:message() == "oops",                   "from() carries raw message")

-- ===== to_table(): nested serialization =====
local t = outer:to_table()
ok(t.message == "could not save", "to_table() top message")
ok(t.kind == "app.save",          "to_table() top kind")
ok(t.fields.retry == 3,           "to_table() top fields")
ok(type(t.cause) == "table",      "to_table() nests cause")
ok(t.cause.message == "disk gone","to_table() nested cause message")
ok(t.cause.kind == "io.disk",     "to_table() nested cause kind")

-- ===== tostring()/__tostring(): cause chain rendering =====
local s = tostring(outer)
ok(type(s) == "string",            "tostring(err) is a string")
ok(s:find("could not save", 1, true) ~= nil, "render includes outer message")
ok(s:find("caused by:", 1, true) ~= nil,     "render shows 'caused by:' for cause")
ok(s:find("disk gone", 1, true) ~= nil,      "render includes inner message")
ok(s:find("[app.save]", 1, true) ~= nil,     "render shows bracketed kind")

-- ===== kinds() builder =====
local Errs = apperror.kinds("myapp", { NotFound = "not_found", BadInput = "bad_input" })
local nf = Errs.NotFound("user 42 missing", { id = 42 })
ok(apperror.is_apperror(nf),                "kinds() ctor produces an apperror")
ok(nf:kind() == "myapp.not_found",          "kinds() ctor builds fully-qualified kind")
ok(nf:message() == "user 42 missing",       "kinds() ctor sets message")
ok(nf:fields().id == 42,                     "kinds() ctor sets fields")
ok(apperror.is(nf, "myapp.not_found") == true, "kinds()-built err matches its kind")
ok(apperror.is(nf, "myapp") == true,            "kinds()-built err matches prefix")

if fails == 0 then print("[+] PASS test_apperror") os.exit(0) else os.exit(1) end
