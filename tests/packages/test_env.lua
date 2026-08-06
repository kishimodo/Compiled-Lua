-- tests/packages/test_env.lua : env (Win32 environment-variable wrapper)
-- round-trips against the live process environment block. Compiled to a
-- standalone exe by the runner (which bundles the env + windows packages).
local ok_req, env = pcall(require, "env")
if not ok_req then print("[~] SKIP test_env") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_env: " .. tostring(m)) end end

local NAME = "CLUA_ENV_TEST_VAR_42"

-- clean slate: a name we own and never collides with a real var
env.unset(NAME)
ok(env.get(NAME) == nil, "missing var -> nil")

-- set/get round-trip (string value)
local sok = env.set(NAME, "hello-world")
ok(sok == true, "set returns true")
ok(env.get(NAME) == "hello-world", "set/get round-trips a string")

-- overwrite replaces the value
env.set(NAME, "second")
ok(env.get(NAME) == "second", "overwrite updates value")

-- unset deletes
local uok = env.unset(NAME)
ok(uok == true, "unset returns true")
ok(env.get(NAME) == nil, "unset removes var")

-- set(name, nil) also deletes (Win32 SetEnvironmentVariableW semantics)
env.set(NAME, "x")
env.set(NAME, nil)
ok(env.get(NAME) == nil, "set(name, nil) deletes")

-- expand substitutes %VAR% from the live block
env.set(NAME, "PAYLOAD")
local ex = env.expand("[%" .. NAME .. "%]")
ok(ex == "[PAYLOAD]", "expand substitutes %VAR% -> got " .. tostring(ex))
ok(env.expand("no vars here") == "no vars here", "expand passes through literal text")
env.unset(NAME)

-- list() returns name=value pairs including a var we set
env.set(NAME, "in-list")
local lst = env.list()
ok(type(lst) == "table", "list returns a table")
ok(lst[NAME] == "in-list", "list includes a var we set -> got " .. tostring(lst and lst[NAME]))
env.unset(NAME)

-- Long values must round-trip. windows.ToWide/FromWide used fixed 2048-WCHAR /
-- 4096-byte scratch buffers, so any entry longer than that made the conversion
-- return 0, which surfaced as "WideCharToMultiByte failed". It was found only by
-- accident: `build\run-tests.bat` prepends two toolchain directories, pushing
-- this machine's PATH to 4,218 bytes so the `PATH=...` entry overflowed by 127,
-- while under a plain shell the same PATH was 4,084 bytes and every run passed.
--
-- These cases construct the length themselves, so the coverage no longer depends
-- on how long the ambient PATH happens to be. Sizes straddle both old buffers
-- (2048 WCHARs and 4096 bytes); Windows allows 32,767 chars per variable.
for _, len in ipairs({ 2100, 4200, 6000 }) do
    local big = string.rep("q", len)
    env.set(NAME, big)
    local got = env.get(NAME)
    ok(got == big, ("get round-trips a %d-char value -> got %s"):format(
        len, got and ("length " .. #got) or "nil"))
    local biglst = env.list()
    ok(type(biglst) == "table" and biglst[NAME] == big,
       ("list survives a %d-char value (the ToWide/FromWide buffer bug)"):format(len))
    env.unset(NAME)
end

-- with(): override active inside fn, original restored after, returns forwarded
env.set(NAME, "outer")
local seen
local r1, r2 = env.with({ [NAME] = "inner" }, function()
    seen = env.get(NAME)
    return "ret1", "ret2"
end)
ok(seen == "inner", "with: override active inside fn")
ok(env.get(NAME) == "outer", "with: restores original after fn")
ok(r1 == "ret1" and r2 == "ret2", "with: forwards fn return values")
env.unset(NAME)

-- with(): forwards varargs to fn
local gotarg
env.with({ [NAME] = "z" }, function(a, b) gotarg = a + b end, 3, 4)
ok(gotarg == 7, "with: forwards varargs to fn")
env.unset(NAME)

-- with(): restores even when fn throws, and re-raises
env.set(NAME, "safe")
local perr = pcall(function()
    env.with({ [NAME] = "temp" }, function() error("boom") end)
end)
ok(perr == false, "with: re-raises fn error")
ok(env.get(NAME) == "safe", "with: restores on error")
env.unset(NAME)

-- with(): empty overrides table is a no-op (and rejects a non-table first arg).
-- NOTE: the docstring promises "nil in the override table means 'unset for the
-- duration'" but that path is unreachable in Lua -- `{ [NAME] = nil }` builds an
-- EMPTY table, so pairs() never visits NAME. We assert only the reachable truth.
env.set(NAME, "present")
env.with({}, function() end)
ok(env.get(NAME) == "present", "with: empty overrides leaves env untouched")
env.unset(NAME)
ok(pcall(env.with, "notatable", function() end) == false, "with: rejects non-table overrides")

if fails == 0 then print("[+] PASS test_env") os.exit(0) else os.exit(1) end
