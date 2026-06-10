local ok_req, inspect = pcall(require, "inspect")
if not ok_req then print("[~] SKIP test_inspect") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_inspect: " .. tostring(m)) end end

-- Callable module + .value/.inspect aliases all agree on the same output.
ok(inspect({1, 2, 3}) == "{ 1, 2, 3 }", "call form sequence")
ok(inspect.value({1, 2, 3}) == "{ 1, 2, 3 }", ".value sequence")
ok(inspect.inspect({1, 2, 3}) == "{ 1, 2, 3 }", ".inspect alias")
ok(inspect.value({}) == "{}", "empty table")

-- Scalars render to their plain literal forms.
ok(inspect.value(42) == "42", "integer scalar")
ok(inspect.value(true) == "true", "boolean scalar")
ok(inspect.value("hi") == '"hi"', "string scalar is quoted")

-- Hash keys are emitted in a deterministic (sorted) order regardless of the
-- order pairs() happens to yield, so output is snapshot-stable.
ok(inspect.value({b = 2, a = 1}) == "{ a = 1, b = 2 }", "keys sorted")
local big = {z = 1, a = 2, m = {x = 10, y = 20}, list = {3, 2, 1}}
local snap = "{ a = 2, list = { 3, 2, 1 }, m = { x = 10, y = 20 }, z = 1 }"
ok(inspect.value(big) == snap, "nested deterministic snapshot")
-- Determinism: two calls on the same value must match byte-for-byte.
ok(inspect.value(big) == inspect.value(big), "stable across calls")

-- Strings with special bytes are escaped/quoted.
ok(inspect.value('he said "hi"\n') == '"he said \\"hi\\"\\n"', "string escaping")

-- Cycles are handled (no infinite loop) and back-references use @N markers.
local t = {}; t.self = t
ok(inspect.value(t) == "{ self = @1 }", "self-cycle marker")
local a = {}
local b = {parent = a}
a.child = b
ok(inspect.value(a) == "{ child = { parent = @1 } }", "indirect cycle marker")

-- is_marker parses "@N" back into N, and rejects non-markers.
ok(inspect.is_marker("@7") == 7, "is_marker parses @7")
ok(inspect.is_marker("@0") == 0, "is_marker parses @0")
ok(inspect.is_marker("nope") == nil, "is_marker rejects plain string")
ok(inspect.is_marker("@") == nil, "is_marker rejects bare @")
ok(inspect.is_marker(42) == nil, "is_marker rejects non-string")

-- compact() yields a single line with no embedded newlines even for deep tables.
local deep = {1, {2, {3, {4}}}}
local c = inspect.compact(deep)
ok(type(c) == "string" and not c:find("\n", 1, true), "compact has no newlines")
ok(c == "{ 1, { 2, { 3, { 4 } } } }", "compact deep table")

-- to_lua emits a Lua expression that round-trips through load().
local orig = {1, 2, 3, name = "hi", nested = {a = true, b = false}}
local src = inspect.to_lua(orig)
local fn = load("return " .. src)
ok(fn ~= nil, "to_lua output is loadable")
if fn then
  local rt = fn()
  ok(type(rt) == "table", "round-trip is a table")
  ok(rt[1] == 1 and rt[2] == 2 and rt[3] == 3, "round-trip sequence values")
  ok(rt.name == "hi", "round-trip string field")
  ok(rt.nested and rt.nested.a == true and rt.nested.b == false, "round-trip nested booleans")
end
-- to_lua must not loop on cycles.
local cyc = {}; cyc.me = cyc
local okc = pcall(inspect.to_lua, cyc)
ok(okc, "to_lua survives a cycle")

-- diff(): identical values -> empty; different values -> a -/+ hunk.
ok(inspect.diff({1, 2, 3}, {1, 2, 3}) == "", "diff of equal values is empty")
local d = inspect.diff({a = 1}, {a = 2})
ok(d:find("- { a = 1 }", 1, true) ~= nil, "diff shows removed line")
ok(d:find("+ { a = 2 }", 1, true) ~= nil, "diff shows added line")

-- Numeric / non-string keys render in bracket form.
ok(inspect.value({[1.5] = "x"}) == '{ [1.5] = "x" }', "non-integer numeric key bracketed")
ok(inspect.value({["with space"] = 1}) == '{ ["with space"] = 1 }', "non-ident string key bracketed")

if fails == 0 then print("[+] PASS test_inspect") os.exit(0) else os.exit(1) end
