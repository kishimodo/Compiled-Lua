-- tests/packages/test_diff.lua : Myers diff (line/word/char), unified-diff
-- text, patch application, and three-way merge. Assertions check against
-- known-correct round-trips and reference values, not the code's own echo.
local ok_req, diff = pcall(require, "diff")
if not ok_req then print("[~] SKIP test_diff") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_diff: " .. tostring(m)) end end

-- ===== diff.lines + diff.apply round-trip =====
-- apply(orig, diff.lines(a,b)) reconstructs b (apply replays equal+insert).
local a1 = "alpha\nbeta\ngamma\n"
local b1 = "alpha\nBETA\ngamma\ndelta\n"
ok(diff.apply(a1, diff.lines(a1, b1)) == b1, "lines: apply(diff(a,b)) reconstructs b")

-- identical inputs -> all equal, reconstructs same
local same = "one\ntwo\nthree\n"
local sscript = diff.lines(same, same)
ok(diff.apply(same, sscript) == same, "lines: identical inputs reconstruct")
do
  local all_equal = true
  for _, op in ipairs(sscript) do if op.kind ~= "equal" then all_equal = false end end
  ok(all_equal, "lines: identical inputs produce only equal ops")
end

-- empty -> non-empty: all inserts; reconstruct b
local fullB = "x\ny\n"
local escript = diff.lines("", fullB)
ok(diff.apply("", escript) == fullB, "lines: empty->b reconstructs b")
do
  local all_insert = (#escript > 0)
  for _, op in ipairs(escript) do if op.kind ~= "insert" then all_insert = false end end
  ok(all_insert, "lines: empty->b is all inserts")
end

-- non-empty -> empty: all deletes; reconstruct ""
local dscript = diff.lines(fullB, "")
ok(diff.apply(fullB, dscript) == "", "lines: a->empty reconstructs empty")
do
  local all_delete = (#dscript > 0)
  for _, op in ipairs(dscript) do if op.kind ~= "delete" then all_delete = false end end
  ok(all_delete, "lines: a->empty is all deletes")
end

-- both empty -> empty script
ok(#diff.lines("", "") == 0, "lines: empty->empty is empty script")

-- ===== known edit script content (single changed line) =====
do
  local A = "keep\nremove\nkeep2\n"
  local B = "keep\nadd\nkeep2\n"
  local s = diff.lines(A, B)
  local ndel, nins, neq = 0, 0, 0
  for _, op in ipairs(s) do
    if op.kind == "delete" then ndel = ndel + 1
    elseif op.kind == "insert" then nins = nins + 1
    elseif op.kind == "equal" then neq = neq + 1 end
  end
  ok(ndel == 1, "lines: one deletion for changed line")
  ok(nins == 1, "lines: one insertion for changed line")
  ok(neq == 2, "lines: two equal lines preserved")
  ok(diff.apply(A, s) == B, "lines: single-change reconstructs b")
  for _, op in ipairs(s) do
    if op.kind == "equal" and op.text == "keep\n" then
      ok(op.a_line == 1 and op.b_line == 1, "lines: equal 'keep' has a_line=b_line=1")
    end
  end
end

-- ===== char-level round-trip + reference edit count =====
do
  -- Classic kitten->sitting: 3 single-char edits = 3 deletes + 3 inserts
  -- (k->s, e->i substitutions, +g append) = 5 non-equal Myers ops.
  local A, B = "kitten", "sitting"
  local s = diff.chars(A, B)
  ok(diff.apply(A, s) == B, "chars: apply(diff) reconstructs b (kitten->sitting)")
  local edits = 0
  for _, op in ipairs(s) do if op.kind ~= "equal" then edits = edits + 1 end end
  ok(edits == 5, "chars: minimal edit ops for kitten->sitting == 5 (got " .. edits .. ")")
end

-- ===== word-level round-trip =====
do
  local A = "the quick brown fox"
  local B = "the slow brown fox"
  ok(diff.apply(A, diff.words(A, B)) == B, "words: apply(diff) reconstructs b")
end

-- ===== unified + patch round-trip =====
do
  local A = "line1\nline2\nline3\nline4\nline5\n"
  local B = "line1\nline2\nCHANGED\nline4\nline5\n"
  local u = diff.unified(A, B)
  ok(u:find("@@", 1, true) ~= nil,        "unified: contains a hunk header")
  ok(u:find("\n-line3", 1, true) ~= nil,  "unified: shows deleted line3")
  ok(u:find("\n+CHANGED", 1, true) ~= nil,"unified: shows inserted CHANGED")
  ok(diff.patch(A, u) == B,               "patch(A, unified(A,B)) == B")
end

-- unified of identical inputs -> empty string; patching empty diff is a no-op
ok(diff.unified(same, same) == "", "unified: identical inputs -> empty string")
ok(diff.patch(same, "") == same,   "patch: empty diff leaves source unchanged")

-- ===== merge: disjoint edits on different lines -> no conflict =====
do
  local base   = "a\nb\nc\nd\n"
  local ours   = "A\nb\nc\nd\n"   -- changed line 1
  local theirs = "a\nb\nc\nD\n"   -- changed line 4
  local res = diff.merge(base, ours, theirs)
  ok(type(res) == "table" and type(res.merged) == "string", "merge: returns merged string")
  ok(#res.conflicts == 0, "merge: disjoint edits -> no conflicts")
end

-- merge: identical inserts by both -> no conflict, insert present once
do
  local base   = "x\ny\nz\n"
  local ours   = "x\nINS\ny\nz\n"
  local theirs = "x\nINS\ny\nz\n"
  local res = diff.merge(base, ours, theirs)
  ok(#res.conflicts == 0, "merge: identical inserts -> no conflict")
  ok(res.merged:find("INS", 1, true) ~= nil, "merge: identical insert present in merged")
end

-- merge: divergent inserts at same spot -> conflict + markers
do
  local base   = "x\ny\n"
  local ours   = "x\nOURS\ny\n"
  local theirs = "x\nTHEIRS\ny\n"
  local res = diff.merge(base, ours, theirs)
  ok(#res.conflicts >= 1, "merge: divergent inserts -> conflict recorded")
  ok(res.merged:find("<<<<<<<", 1, true) ~= nil, "merge: conflict markers emitted")
end

-- ===== legacy aliases relabel kinds (ctx/add/del) =====
do
  local s = diff.diff_lines("p\nq\n", "p\nQ\n")
  local labels = {}
  for _, op in ipairs(s) do labels[op.kind] = true end
  ok(labels.ctx or labels.add or labels.del, "diff_lines: uses legacy kind labels")
  ok(not (labels.equal or labels.insert or labels.delete), "diff_lines: no new-style labels leak")
end

if fails == 0 then print("[+] PASS test_diff") os.exit(0) else os.exit(1) end
