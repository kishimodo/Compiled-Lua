-- tests/packages/test_mock.lua : spies/stubs/fakes/matchers. Fully deterministic.
local ok_req, mock = pcall(require, "mock")
if not ok_req then print("[~] SKIP test_mock (" .. tostring(mock) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_mock: " .. tostring(m)) end end

-- spy: records calls + runs the underlying impl.
local s = mock.spy(function(a, b) return a + b end)
ok(s(2, 3) == 5,                 "spy invokes underlying impl and returns its result")
ok(s(10, 1) == 11,               "spy invokes impl a second time")
ok(s:call_count() == 2,          "spy records call_count == 2")
ok(s:called_with(2, 3),          "spy:called_with finds the first call")
ok(not s:called_with(9, 9),      "spy:called_with is false for an absent arg set")

-- calls() exposes args + returns with preserved arities.
local hist = s:calls()
ok(#hist == 2,                   "spy:calls returns one record per call")
ok(hist[1].args[1] == 2 and hist[1].args[2] == 3, "recorded args for call 1")
ok(hist[1].returns[1] == 5,      "recorded return for call 1")

-- stub with a default value (non-consuming): always returns it.
local st = mock.stub(99)
ok(st() == 99,                   "stub(value) returns the value")
ok(st() == 99,                   "stub(value) keeps returning it (non-consuming)")

-- :returns queues FIFO returns.
local q = mock.spy()
q:returns("first"):returns("second")
ok(q() == "first",               "queued return 1 (FIFO)")
ok(q() == "second",              "queued return 2 (FIFO)")

-- :throws makes the next call raise.
local th = mock.spy()
th:throws("boom")
local pok, perr = pcall(th)
ok(not pok,                      "spy:throws causes the next call to error")
ok(tostring(perr):find("boom", 1, true) ~= nil, "thrown error carries the message")

-- :when(matchers).returns -- matcher-keyed dispatch.
local w = mock.spy()
w:when(1, 2).returns("one-two")
w:when(mock.any, 0).returns("anything-zero")
ok(w(1, 2) == "one-two",         "when(1,2) matches literal args")
ok(w(42, 0) == "anything-zero",  "when(mock.any, 0) matches via wildcard")

-- fake() uses the supplied impl as the body.
local fk = mock.fake(function(x) return x * x end)
ok(fk(4) == 16,                  "fake invokes the impl body")

-- reset() clears the call log and queued returns.
local r = mock.spy(function() return 1 end)
r(); r()
ok(r:call_count() == 2,          "calls recorded before reset")
r:reset()
ok(r:call_count() == 0,          "reset clears the call log")

-- match.* predicate matchers.
ok(mock.match.is_number(5),      "match.is_number on a number")
ok(not mock.match.is_number("x"),"match.is_number false on a string")
ok(mock.match.gt(3)(4),          "match.gt(3) true for 4")
ok(not mock.match.gt(3)(2),      "match.gt(3) false for 2")
ok(mock.match.between(1, 10)(5), "match.between true inside range")
ok(mock.match.contains("ell")("hello"), "match.contains substring")

-- replace(): patch + restore a table field.
local target = { greet = function() return "hi" end }
local restore = mock.replace(target, "greet", function() return "bye" end)
ok(target.greet() == "bye",      "replace swaps the field")
restore()
ok(target.greet() == "hi",       "restorer puts the original back")
restore()  -- double-restore is a no-op
ok(target.greet() == "hi",       "double restore is a no-op")

-- replace on a non-table errors.
ok(not pcall(mock.replace, 5, "x", 1), "replace errors on non-table module")

-- verify_calls: exact call-by-call matching.
local v = mock.spy()
v(1, 2); v(3, 4)
local vok = mock.verify_calls(v, { { 1, 2 }, { 3, 4 } })
ok(vok == true,                  "verify_calls matches the recorded sequence")
local vbad = mock.verify_calls(v, { { 1, 2 } })
ok(vbad == false,                "verify_calls fails on a count mismatch")

-- verify(spy) assertion DSL.
local vd = mock.spy()
vd("a"); vd("b")
ok(pcall(function() mock.verify(vd):was_called(2) end),     "verify():was_called(2) passes")
ok(not pcall(function() mock.verify(vd):was_called(5) end), "verify():was_called(5) raises")
ok(pcall(function() mock.verify(vd):was_called_with("a") end), "verify():was_called_with finds a call")
local fresh = mock.spy()
ok(pcall(function() mock.verify(fresh):was_not_called() end), "verify():was_not_called on a fresh spy")

-- partial(): override a subset of keys, then restore.
local cfg = { a = 1, b = 2, c = 3 }
local pres = mock.partial(cfg, { a = 10, b = 20 })
ok(cfg.a == 10 and cfg.b == 20 and cfg.c == 3, "partial overrides only the given keys")
pres()
ok(cfg.a == 1 and cfg.b == 2,    "partial restorer reverts the overrides")

-- with(): scoped patch restored even after the body runs.
local mod = { f = function() return "orig" end }
mock.with({ { mod, "f", function() return "patched" end } }, function()
    ok(mod.f() == "patched",     "with() patch is active inside the body")
end)
ok(mod.f() == "orig",            "with() restores after the body")

if fails == 0 then print("[+] PASS test_mock") os.exit(0) else os.exit(1) end
