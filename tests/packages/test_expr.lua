-- Regression test for the builtin `expr` package: a sandboxed expression
-- evaluator. It rewrites a parsed expression into a Lua chunk loaded with an
-- empty _ENV, so arithmetic/coercion semantics must match Lua 5.4 exactly.
-- We assert against known-correct Lua reference values, never the code's own
-- output. (expr.eval here is the package's own SANDBOXED evaluator, not raw
-- load/eval; exercising that sandbox is the intended use.)

local ok_req, expr = pcall(require, "expr")
if not ok_req then print("[~] SKIP test_expr") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_expr: " .. tostring(m)) end end

local function val(src, env, opts)
  return (expr.eval(src, env, opts))
end

-- ===== Arithmetic precedence / associativity (vs Lua 5.4 reference) =====
ok(val("2+3*4") == 14, "2+3*4 == 14")
ok(val("-2^2") == -4, "-2^2 == -4 (^ binds tighter than unary minus)")
ok(val("2^3^2") == 512, "2^3^2 == 512 (^ right assoc)")
ok(val("(2+3)*4") == 20, "(2+3)*4 == 20")
ok(val("10/2/5") == 1.0, "10/2/5 left assoc == 1.0")
ok(val("7%3") == 1, "7%3 == 1")
ok(val("2*3+4*5") == 26, "2*3+4*5 == 26")
ok(val("100-10-1") == 89, "100-10-1 left assoc == 89")

-- ===== Comparison =====
ok(val("1<2") == true, "1<2 true")
ok(val("2<=2") == true, "2<=2 true")
ok(val("3>5") == false, "3>5 false")
ok(val("1==1") == true, "1==1 true")
ok(val("1~=2") == true, "1~=2 true")

-- ===== Logical operators (return operand value, Lua-style short circuit) =====
ok(val("true and 5") == 5, "true and 5 == 5")
ok(val("false and 5") == false, "false and 5 == false")
ok(val("nil or 7") == 7, "nil or 7 == 7")
ok(val("1 or 2") == 1, "1 or 2 == 1")
ok(val("not true") == false, "not true == false")
ok(val("not nil") == true, "not nil == true")
ok(val("1 < 2 and 3 < 4") == true, "chained logical comparison")
ok(val("1 > 2 or 3 < 4") == true, "or with comparisons")

-- ===== Concat (right assoc) and strings =====
ok(val([["a".."b".."c"]]) == "abc", "concat \"a\"..\"b\"..\"c\" == abc")
ok(val([["x" == "x"]]) == true, "string equality")
-- BUG: a number literal as the LEFT operand of `..` mis-compiles. See bug_found.
ok(val("1 .. 2") == "12", "number .. number coercion == \"12\"")

-- ===== Lexer: string escapes =====
ok(val([["a\tb"]]) == "a\tb", "tab escape")
ok(val([["a\nb"]]) == "a\nb", "newline escape")

-- ===== Length operator =====
ok(val([[#"hello"]]) == 5, "#\"hello\" == 5")

-- ===== Number lexing: hex, float, exponent =====
ok(val("0xff") == 255, "0xff == 255")
ok(val("0x10 + 1") == 17, "0x10 + 1 == 17")
ok(val("1e3") == 1000, "1e3 == 1000")
ok(val("1.5 + 0.5") == 2.0, "1.5+0.5 == 2.0")

-- ===== Environment variable lookup =====
ok(val("x + y", {x = 3, y = 4}) == 7, "x+y with env")
ok(val("a * b - c", {a = 2, b = 5, c = 3}) == 7, "a*b-c with env")
ok(val("missing") == nil, "missing var resolves to nil")

-- ===== Table indexing through env =====
ok(val("t.k", {t = {k = 42}}) == 42, "t.k field access")
ok(val("t[1]", {t = {10, 20}}) == 10, "t[1] index access")
ok(val("t.a.b", {t = {a = {b = 9}}}) == 9, "nested t.a.b")
ok(val("t[\"key\"]", {t = {key = "v"}}) == "v", "t[\"key\"] index")

-- ===== Function calls: disabled by default =====
do
  local r, err = expr.eval("f(1)", {f = function(x) return x end})
  ok(r == nil and err ~= nil, "calls disabled by default -> nil,err")
end

-- ===== allow_functions = true =====
do
  local r = expr.eval("f(3)", {f = function(x) return x * 2 end}, {allow_functions = true})
  ok(r == 6, "allow_functions=true: f(3) == 6")
end

-- ===== allow_functions = "safe" uses bundled SAFE_FUNCS =====
do
  local r = expr.eval("floor(3.7)", {floor = expr.safe_funcs.floor}, {allow_functions = "safe"})
  ok(r == 3, "safe floor(3.7) == 3")
  local r2 = expr.eval("max(1, 9, 4)", {max = expr.safe_funcs.max}, {allow_functions = "safe"})
  ok(r2 == 9, "safe max(1,9,4) == 9")
end

-- ===== Function not in allowlist is rejected =====
do
  local evil = function() return "boom" end
  local r, err = expr.eval("f()", {f = evil}, {allow_functions = "safe"})
  ok(r == nil and err ~= nil, "non-allowlisted function rejected")
end

-- ===== Syntax errors return nil,err (never throw) =====
do
  local r, err = expr.eval("1 +")
  ok(r == nil and err ~= nil, "incomplete expr -> nil,err")
  local r2, err2 = expr.eval("1 + 2 foo")
  ok(r2 == nil and err2 ~= nil, "trailing tokens -> nil,err")
end

-- ===== compile() returns a reusable closure across envs =====
do
  local fn = expr.compile("a + b")
  ok(fn({a = 1, b = 2}) == 3, "compiled reuse env1")
  ok(fn({a = 10, b = 20}) == 30, "compiled reuse env2")
end

-- ===== High-level evaluator object =====
do
  local ev = assert(expr.compile_evaluator("price * qty + tax"))
  ok(ev:eval({price = 2, qty = 3, tax = 1}) == 7, "evaluator:eval == 7")
  ok(ev:source() == "price * qty + tax", "evaluator:source preserved")
  local set = {}
  for _, v in ipairs(ev:variables()) do set[v] = true end
  ok(set.price and set.qty and set.tax, "evaluator:variables lists price,qty,tax")
end

-- ===== variables() excludes dotted fields, keeps the base name =====
do
  local ev = assert(expr.compile_evaluator("obj.field + n"))
  local set = {}
  for _, v in ipairs(ev:variables()) do set[v] = true end
  ok(set.obj and set.n and not set.field, "field excluded from variables()")
end

-- ===== Friendly opt `functions` forwards to allow_functions =====
do
  local ev = assert(expr.compile_evaluator("dbl(5)", {functions = true}))
  ok(ev:eval({dbl = function(x) return x + x end}) == 10, "functions opt enables call")
end

-- ===== max_depth / max_complexity guard captured as nil,err =====
do
  local r, err = expr.eval("((((((1))))))", nil, {max_depth = 2})
  ok(r == nil and err ~= nil, "max_depth exceeded -> nil,err")
end

if fails == 0 then print("[+] PASS test_expr") os.exit(0) else os.exit(1) end
