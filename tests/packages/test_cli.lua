-- tests/packages/test_cli.lua : argparse-style CLI parser. Pure-Lua surface,
-- no DLL needed. Asserts parse() output for a known argv against reference
-- values, plus help/completion text invariants. Compiled to a standalone exe
-- by the runner (which bundles the cli package) and run.
local ok_req, cli = pcall(require, "cli")
if not ok_req then print("[~] SKIP test_cli") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_cli: " .. tostring(m)) end end

-- ===== Positionals + options + flags against a known argv ===========
local function build()
    local p = cli.new({ name = "tool", description = "demo", version = "1.2.3" })
    p:argument("src")                                   -- required-ish positional (string)
    p:argument("dst", { default = "out" })              -- positional with default
    p:option("level", { type = "int", short = "l", default = 0 })
    p:option("mode", { choices = { "fast", "slow" }, default = "fast" })
    p:flag("verbose", { short = "v" })
    p:flag("color", { default = true })
    return p
end

do
    local p = build()
    local pok, a = pcall(p.parse, p, { "in.txt", "out.txt", "--level", "5", "--mode", "slow", "-v" })
    ok(pok, "parse of full argv must not error: " .. tostring(a))
    if pok then
        ok(a.src == "in.txt",     "positional src")
        ok(a.dst == "out.txt",    "positional dst overrides default")
        ok(a.level == 5,          "int option coerced to number 5, got " .. tostring(a.level))
        ok(a.mode == "slow",      "choice option slow")
        ok(a.verbose == true,     "flag -v sets verbose true")
        ok(a.color == true,       "flag default true preserved")
    end
end

-- ===== Defaults applied when args are absent =========================
do
    local p = build()
    local pok, a = pcall(p.parse, p, { "only.txt" })
    ok(pok, "parse with only required positional: " .. tostring(a))
    if pok then
        ok(a.src == "only.txt",   "src set from sole positional")
        ok(a.dst == "out",        "dst falls back to default")
        ok(a.level == 0,          "level default 0")
        ok(a.mode == "fast",      "mode default fast")
        ok(a.verbose == false,    "flag absent => false")
        ok(a.color == true,       "color default true")
    end
end

-- ===== --key=value inline form & short -lvalue ======================
do
    local p = build()
    local pok, a = pcall(p.parse, p, { "x", "--level=9", "-l", "9" })  -- last -l wins
    ok(pok, "inline + short parse: " .. tostring(a))
    if pok then ok(a.level == 9, "inline --level=9 then -l 9 => 9, got " .. tostring(a.level)) end

    local p2 = build()
    local pok2, a2 = pcall(p2.parse, p2, { "x", "-l7" })  -- short attached value
    ok(pok2, "short attached -l7 parse: " .. tostring(a2))
    if pok2 then ok(a2.level == 7, "-l7 => 7, got " .. tostring(a2 and a2.level)) end
end

-- ===== Flag negation --no-color and short bundling -vV-style ========
do
    local p = build()
    local pok, a = pcall(p.parse, p, { "x", "--no-color" })
    ok(pok, "--no-color parse: " .. tostring(a))
    if pok then ok(a.color == false, "--no-color clears flag default true") end
end

do
    local p = cli.new({ name = "bundle" })
    p:flag("a", { short = "a" })
    p:flag("b", { short = "b" })
    p:flag("c", { short = "c" })
    local pok, a = pcall(p.parse, p, { "-abc" })
    ok(pok, "bundled -abc parse: " .. tostring(a))
    if pok then
        ok(a.a == true and a.b == true and a.c == true, "bundle -abc sets all three flags")
    end
end

-- ===== multi option accumulates into a table =========================
do
    local p = cli.new({ name = "multi" })
    p:option("inc", { multi = true })
    local pok, a = pcall(p.parse, p, { "--inc", "one", "--inc", "two", "--inc", "three" })
    ok(pok, "multi parse: " .. tostring(a))
    if pok then
        ok(type(a.inc) == "table", "multi value is a table")
        ok(a.inc and #a.inc == 3, "multi collected 3 values, got " .. tostring(a.inc and #a.inc))
        ok(a.inc and a.inc[1] == "one" and a.inc[3] == "three", "multi preserves order")
    end
end

-- ===== type coercion: int, float (options) + bool (positional) ======
-- NOTE: a type="bool" *option* is toggled like a flag and does not consume a
-- following token, so bool's value-coercion path is exercised via a positional.
do
    local p = cli.new({ name = "coerce" })
    p:option("n", { type = "int" })
    p:option("f", { type = "float" })
    p:argument("b", { type = "bool" })
    local pok, a = pcall(p.parse, p, { "--n", "42", "--f", "3.5", "yes" })
    ok(pok, "coerce parse: " .. tostring(a))
    if pok then
        ok(a.n == 42, "int 42")
        ok(math.abs(a.f - 3.5) < 1e-9, "float 3.5")
        ok(a.b == true, "bool positional 'yes' => true")
    end
    -- int must reject a fractional value
    local bad = pcall(p.parse, p, { "--n", "3.5" })
    ok(not bad, "int option rejects '3.5'")
    -- bool positional rejects a non-bool word
    local bad2 = pcall(p.parse, p, { "--n", "1", "maybe" })
    ok(not bad2, "bool positional rejects 'maybe'")
end

-- ===== choices: invalid value is rejected ===========================
do
    local p = build()
    local bad = pcall(p.parse, p, { "x", "--mode", "warp" })
    ok(not bad, "invalid choice 'warp' rejected")
end

-- ===== unknown option handling raises an error ======================
do
    local p = build()
    local bad = pcall(p.parse, p, { "x", "--nonexistent" })
    ok(not bad, "unknown --nonexistent option errors")
    local bad2 = pcall(p.parse, p, { "x", "-Z" })
    ok(not bad2, "unknown -Z short option errors")
end

-- ===== required option missing raises an error ======================
do
    local p = cli.new({ name = "req" })
    p:option("token", { required = true })
    local bad = pcall(p.parse, p, {})
    ok(not bad, "missing required --token errors")
    local good = pcall(p.parse, p, { "--token", "abc" })
    ok(good, "required --token satisfied does not error")
end

-- ===== "--" terminator forces remaining tokens to positionals =======
do
    local p = cli.new({ name = "term" })
    p:argument("first")
    p:argument("second")
    local pok, a = pcall(p.parse, p, { "--", "-v", "--level" })
    ok(pok, "-- terminator parse: " .. tostring(a))
    if pok then
        ok(a.first == "-v", "first positional after -- is literal -v")
        ok(a.second == "--level", "second positional after -- is literal --level")
    end
end

-- ===== subcommands: args.subcommand + nested args table =============
do
    local p = cli.new({ name = "git" })
    local add = p:subcommand("add", { description = "stage files" })
    add:argument("path")
    add:flag("force", { short = "f" })
    local pok, a = pcall(p.parse, p, { "add", "file.txt", "-f" })
    ok(pok, "subcommand parse: " .. tostring(a))
    if pok then
        ok(a.subcommand == "add", "subcommand name recorded")
        ok(type(a.add) == "table", "sub-args nested under args.add")
        ok(a.add and a.add.path == "file.txt", "sub positional parsed")
        ok(a.add and a.add.force == true, "sub flag parsed")
    end
    -- unknown subcommand errors
    local bad = pcall(p.parse, p, { "bogus" })
    ok(not bad, "unknown subcommand errors")
end

-- ===== action callback bypasses storage =============================
do
    local p = cli.new({ name = "act" })
    local seen
    p:option("hook", { action = function(args, value) seen = value end })
    local pok, a = pcall(p.parse, p, { "--hook", "payload" })
    ok(pok, "action parse: " .. tostring(a))
    if pok then
        ok(seen == "payload", "action callback received value")
        ok(a.hook == nil, "action option not stored in args")
    end
end

-- ===== help() text contains key fixed strings (no os.exit path) =====
do
    local p = build()
    local hok, h = pcall(p.help, p)
    ok(hok and type(h) == "string", "help() returns a string")
    if hok then
        ok(h:find("usage:", 1, true) ~= nil, "help mentions usage:")
        ok(h:find("tool", 1, true) ~= nil, "help mentions program name")
        ok(h:find("%-%-level") ~= nil, "help lists --level option")
        ok(h:find("%-%-help") ~= nil, "help lists --help")
    end
end

-- ===== gen_completion bash/pwsh produce shell-specific text =========
do
    local p = cli.new({ name = "cmpl", version = "0.1" })
    p:option("path")
    p:subcommand("run", {})
    local bok, bash = pcall(p.gen_completion, p, "bash")
    ok(bok and type(bash) == "string", "gen_completion bash returns string")
    if bok then
        ok(bash:find("complete -F", 1, true) ~= nil, "bash completion has 'complete -F'")
        ok(bash:find("compgen", 1, true) ~= nil, "bash completion uses compgen")
        ok(bash:find("--path", 1, true) ~= nil, "bash completion lists --path")
    end
    local pok2, pwsh = pcall(p.gen_completion, p, "pwsh")
    ok(pok2 and type(pwsh) == "string", "gen_completion pwsh returns string")
    if pok2 then
        ok(pwsh:find("Register-ArgumentCompleter", 1, true) ~= nil, "pwsh completion registers completer")
    end
    local sbad = pcall(p.gen_completion, p, "fish")
    ok(not sbad, "gen_completion rejects unknown shell")
end

if fails == 0 then print("[+] PASS test_cli") os.exit(0) else os.exit(1) end
