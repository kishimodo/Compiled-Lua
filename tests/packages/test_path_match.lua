-- tests/packages/test_path_match.lua : pure-Lua find-style path predicates.
-- Asserts against known-correct reference values / round-trips, not the
-- package's own output. No native DLL needed.
local ok_req, path_match = pcall(require, "path_match")
if not ok_req then print("[~] SKIP test_path_match") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_path_match: " .. tostring(m)) end end

-- ----- basename glob: name / iname -------------------------------------
local p_lua = path_match.name("*.lua")
ok(p_lua("foo.lua") == true,        "name *.lua matches foo.lua")
ok(p_lua("dir/sub/x.lua") == true,  "name globs basename only (dir/sub/x.lua)")
ok(p_lua("foo.txt") == false,       "name *.lua rejects foo.txt")
ok(path_match.name("foo?.c")("foox.c") == true,  "name ? matches one char")
ok(path_match.name("foo?.c")("foo.c") == false,  "name ? requires a char")

-- '/' is literal for name(): a basename glob never crosses directories.
ok(path_match.name("*.lua")("a/b.lua") == true,  "name uses basename of a/b.lua")
ok(path_match.iname("*.LUA")("Foo.lua") == true, "iname is case-insensitive")
ok(path_match.iname("*.LUA")("Foo.txt") == false,"iname still rejects wrong ext")

-- charclass + negation
ok(path_match.name("[ab].txt")("a.txt") == true,   "charclass matches a")
ok(path_match.name("[ab].txt")("c.txt") == false,  "charclass rejects c")
ok(path_match.name("[!ab].txt")("c.txt") == true,  "negated class matches c")
ok(path_match.name("[!ab].txt")("a.txt") == false, "negated class rejects a")

-- ----- full-path glob: path / ipath ('**' crosses slashes) -------------
ok(path_match.path("**/x.lua")("a/b/x.lua") == true,  "path ** crosses slashes")
ok(path_match.path("*/x.lua")("a/b/x.lua") == false,  "path single * stops at slash")
ok(path_match.path("a/*/x.lua")("a/b/x.lua") == true, "path single * within one segment")
ok(path_match.ipath("**/X.LUA")("a/b/x.lua") == true, "ipath is case-insensitive")

-- ----- type predicate (needs stat) -------------------------------------
local p_file = path_match.type("file")
ok(p_file("x", { type = "file" }) == true,  "type file matches stat.type=file")
ok(p_file("x", { type = "dir" })  == false, "type file rejects dir")
ok(not p_file("x", nil),                    "type without stat is falsy")
ok(path_match.type("d")("x", { type = "dir" }) == true, "type short letter d == dir")

-- ----- size spec --------------------------------------------------------
-- "+N" => > N ; "-N" => < N ; "=N" / "N" => == N ; suffixes k/M etc.
local big = path_match.size("+1M")              -- > 1048576
ok(big("x", { size = 2 * 1024 * 1024 }) == true,  "size +1M true for 2M")
ok(big("x", { size = 512 * 1024 }) == false,      "size +1M false for 512k")
ok(path_match.size("<1k")("x", { size = 1023 }) == true,  "size <1k true for 1023")
ok(path_match.size("<1k")("x", { size = 1024 }) == false, "size <1k false for 1024")
ok(path_match.size("=512")("x", { size = 512 }) == true,  "size =512 exact match")
ok(path_match.size("=512")("x", { size = 513 }) == false, "size =512 rejects 513")
ok(path_match.size("+10")("x", { size = 11 }) == true,    "size +10 (no suffix) > 10")
ok(path_match.size("+10")("x", { size = 10 }) == false,   "size +10 strict greater")
ok(path_match.size(">=2k")("x", { size = 2048 }) == true, "size >=2k inclusive")
ok(path_match.size("!=0")("x", { size = 5 }) == true,     "size !=0 true for 5")
ok(path_match.size("!=0")("x", { size = 0 }) == false,    "size !=0 false for 0")

-- ----- depth spec (counts separators; bare name = 0) -------------------
ok(path_match.depth("=0")("file.txt") == true,    "depth =0 for bare name")
ok(path_match.depth("=2")("a/b/c.txt") == true,   "depth =2 for a/b/c.txt")
ok(path_match.depth(">1")("a/b/c.txt") == true,   "depth >1 for a/b/c.txt")
ok(path_match.depth("<2")("a/b/c.txt") == false,  "depth <2 false for a/b/c.txt")
ok(path_match.depth(3)("a/b/c/d") == true,        "depth as number arg works")

-- ----- mtime: compares AGE (now - mtime) -------------------------------
local now = os.time()
-- A file modified 100s ago has age ~100 => "+50" (age > 50s) is true.
ok(path_match.mtime("+50s")("x", { mtime = now - 100 }) == true,  "mtime +50s true for 100s-old")
ok(path_match.mtime("+50s")("x", { mtime = now - 10 }) == false,  "mtime +50s false for 10s-old")
ok(path_match.mtime("+50s")("x", nil) == false,                   "mtime without stat is false")
ok(path_match.mtime("-50s")("x", { mtime = now - 10 }) == true,   "mtime -50s true for fresh file")

-- ----- combinators ------------------------------------------------------
local both = path_match.and_(path_match.name("*.lua"), path_match.size("+10"))
ok(both("a.lua", { size = 100 }) == true,  "and_ both true")
ok(both("a.txt", { size = 100 }) == false, "and_ short-circuits on name")
ok(both("a.lua", { size = 5 })   == false, "and_ false when size fails")
local either = path_match.or_(path_match.name("*.lua"), path_match.name("*.txt"))
ok(either("a.txt") == true,  "or_ matches second")
ok(either("a.md")  == false, "or_ rejects neither")
ok(path_match.not_(path_match.name("*.lua"))("a.txt") == true, "not_ inverts")

-- matches() coerces to strict boolean
ok(path_match.matches("a.lua", path_match.name("*.lua")) == true, "matches returns true")
ok(path_match.matches("a.txt", path_match.name("*.lua")) == false,"matches returns false")

-- ----- compile_find: parse a find(1)-style expression ------------------
local pred, err = path_match.compile_find('-name "*.lua" -size +10')
ok(pred ~= nil, "compile_find returns predicate (" .. tostring(err) .. ")")
if pred then
  ok(pred("foo.lua", { size = 50 }) == true,  "compiled: lua + size>10 matches")
  ok(pred("foo.lua", { size = 5 })  == false, "compiled: size fails")
  ok(pred("foo.txt", { size = 50 }) == false, "compiled: name fails")
end

local pred_or = path_match.compile_find('-name "*.lua" -or -name "*.txt"')
ok(pred_or ~= nil, "compile_find -or returns predicate")
if pred_or then
  ok(pred_or("a.txt") == true,  "compiled -or: txt matches")
  ok(pred_or("a.md")  == false, "compiled -or: md rejected")
end

local pred_not = path_match.compile_find('-not -name "*.lua"')
ok(pred_not ~= nil, "compile_find -not returns predicate")
if pred_not then
  ok(pred_not("a.txt") == true,  "compiled -not: txt matches")
  ok(pred_not("a.lua") == false, "compiled -not: lua rejected")
end

-- parenthesised grouping + -type letter
local pred_grp = path_match.compile_find('( -name "*.c" -or -name "*.h" ) -type f')
ok(pred_grp ~= nil, "compile_find grouping returns predicate")
if pred_grp then
  ok(pred_grp("a.c", { type = "file" }) == true,  "grouped: a.c file matches")
  ok(pred_grp("a.c", { type = "dir" })  == false, "grouped: a.c dir rejected by -type f")
  ok(pred_grp("a.o", { type = "file" }) == false, "grouped: a.o rejected by name group")
end

-- empty source => always-true predicate
local pred_empty = path_match.compile_find("")
ok(pred_empty ~= nil and pred_empty("anything") == true, "compile_find empty => always true")

-- malformed => nil + error message (no throw)
local bad, berr = path_match.compile_find('-bogusflag')
ok(bad == nil and type(berr) == "string", "compile_find unknown flag => nil,err")

-- ----- pred.* convenience namespace ------------------------------------
local pr = path_match.pred
ok(pr ~= nil, "pred namespace present")
if pr then
  ok(pr.ext("lua")("a.lua") == true,        "pred.ext string matches")
  ok(pr.ext(".lua")("a.lua") == true,       "pred.ext tolerates leading dot")
  ok(pr.ext("lua")("a.LUA") == true,        "pred.ext is case-insensitive")
  ok(pr.ext("lua")("a.txt") == false,       "pred.ext rejects wrong ext")
  ok(pr.ext({ "lua", "txt" })("a.txt") == true, "pred.ext list matches any")
  ok(pr.size_above(10)("x", { size = 11 }) == true,  "pred.size_above")
  ok(pr.size_above(10)("x", { size = 10 }) == false, "pred.size_above strict")
  ok(pr.size_below(10)("x", { size = 9 })  == true,  "pred.size_below")
  ok(pr.mtime_after(100)("x", { mtime = 200 }) == true,  "pred.mtime_after (raw mtime)")
  ok(pr.mtime_before(100)("x", { mtime = 50 }) == true,  "pred.mtime_before (raw mtime)")
  -- exec: x-bit via mode, or executable flag
  ok(pr.exec()("x", { mode = 0x49 }) == true,  "pred.exec sees x-bit in mode")
  ok(pr.exec()("x", { mode = 0x124 }) == false,"pred.exec false without x-bit")
  ok(pr.exec()("x", { executable = true }) == true, "pred.exec sees executable flag")
end

if fails == 0 then print("[+] PASS test_path_match") os.exit(0) else os.exit(1) end
