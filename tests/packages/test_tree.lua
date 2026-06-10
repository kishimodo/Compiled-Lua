-- tests/packages/test_tree.lua : the `tree` package -- filesystem walk + size
-- accounting on top of `fs`/`path`. The runner compiles this with compiler.exe
-- (bundling tree + fs + path + windows...) then runs the standalone exe.
--
-- We build a deterministic on-disk tree under the system temp dir with KNOWN
-- file sizes, then assert tree's reference-correct accounting (count/du/find/
-- walk/structured-tree) against those known values -- never against the code's
-- own output. (This exercises fs.stat, whose uint64_t-cdata-arithmetic crash --
-- TREE-FS-001 -- was fixed by computing the FILETIME with Lua integer math.)

local ok_req, tree = pcall(require, "tree")
if not ok_req then print("[~] SKIP test_tree") os.exit(0) end
local ok_fs, fs = pcall(require, "fs")
if not ok_fs then print("[~] SKIP test_tree (no fs)") os.exit(0) end
local path = require "path"

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_tree: " .. tostring(m)) end end

-- ===== pure-Lua surface (no fs.stat needed) =============================

-- iter is documented as an alias of walk.
ok(tree.iter == tree.walk, "tree.iter is an alias of tree.walk")

-- find rejects a non-function predicate before touching the filesystem.
ok(pcall(tree.find, ".", "not a function") == false,
   "tree.find errors on a non-function predicate")

-- ===== filesystem accounting against KNOWN values =======================
--
-- Build:
--   root/a.txt        ("hello")  -> 5 bytes
--   root/b.lua        ("xyz")    -> 3 bytes
--   root/sub/c.txt    ("hi")     -> 2 bytes
--   root/sub/deep/d.md("deep")   -> 4 bytes
-- => 4 files, 3 dirs (root, sub, deep), total 14 bytes.
local tmproot, mkerr = fs.temp_dir()
if not tmproot then print("[~] SKIP test_tree (no temp dir: " .. tostring(mkerr) .. ")") os.exit(0) end

local setup_ok = pcall(function()
  local function mkfile(rel, content)
    local full = path.join(tmproot, rel)
    local dir = path.dirname(full)
    if dir ~= "" and not fs.is_dir(dir) then assert(fs.mkdir(dir, true)) end
    assert(fs.write(full, content))
  end
  mkfile("a.txt",          "hello")
  mkfile("b.lua",          "xyz")
  mkfile("sub/c.txt",      "hi")
  mkfile("sub/deep/d.md",  "deep")
end)

if not setup_ok then
  -- Could not even write the fixture (fs.write/mkdir broken). Skip the
  -- accounting block rather than report a false tree bug.
  print("[~] SKIP test_tree (could not create fixture tree)")
  os.exit(0)
end

-- All of the following call fs.stat under the hood (fixed -- see TREE-FS-001).
-- Run them inside a pcall so a fixture/permission hiccup degrades cleanly, then
-- assert the call itself did not throw.

local acc_ok, acc_err = pcall(function()
  -- count
  local c = tree.count(tmproot)
  ok(c.files == 4,    "count.files == 4 (got " .. tostring(c.files) .. ")")
  ok(c.dirs == 3,     "count.dirs == 3 (got " .. tostring(c.dirs) .. ")")
  ok(c.symlinks == 0, "count.symlinks == 0 (got " .. tostring(c.symlinks) .. ")")
  ok(c.total == 7,    "count.total == 7 (got " .. tostring(c.total) .. ")")

  -- du total
  ok(tree.du(tmproot) == 14, "du total bytes == 14 (got " .. tostring(tree.du(tmproot)) .. ")")

  -- du by_extension
  local bx = tree.du(tmproot, { by_extension = true })
  ok(bx.total == 14,                "du by_extension.total == 14")
  ok(bx.by_extension[".txt"] == 7,  ".txt bytes == 7 (got " .. tostring(bx.by_extension[".txt"]) .. ")")
  ok(bx.by_extension[".lua"] == 3,  ".lua bytes == 3 (got " .. tostring(bx.by_extension[".lua"]) .. ")")
  ok(bx.by_extension[".md"] == 4,   ".md bytes == 4 (got " .. tostring(bx.by_extension[".md"]) .. ")")

  -- find: the two .txt files
  local txts = tree.find(tmproot, function(e) return not e.is_dir and e.name:sub(-4) == ".txt" end)
  ok(#txts == 2, "find .txt returns 2 paths (got " .. tostring(#txts) .. ")")
  local fa, fc = false, false
  for _, p in ipairs(txts) do
    if p:sub(-5) == "a.txt" then fa = true end
    if p:sub(-5) == "c.txt" then fc = true end
  end
  ok(fa and fc, "find returns a.txt and c.txt")

  -- walk: root first at depth 0, 7 entries total (4 files + 3 dirs)
  local first, n = nil, 0
  for e in tree.walk(tmproot) do if first == nil then first = e end n = n + 1 end
  ok(first ~= nil and first.path == tmproot and first.depth == 0,
     "walk yields root first at depth 0")
  ok(n == 7, "walk yields 7 entries (got " .. tostring(n) .. ")")

  -- walk max_depth=1: root (0) + a.txt, b.lua, sub (1) = 4 entries
  local n1 = 0
  for _ in tree.walk(tmproot, { max_depth = 1 }) do n1 = n1 + 1 end
  ok(n1 == 4, "walk max_depth=1 yields 4 entries (got " .. tostring(n1) .. ")")

  -- walk filter dropping 'sub' prunes its whole subtree: root, a.txt, b.lua = 3
  local kept = 0
  for _ in tree.walk(tmproot, { filter = function(en) return en.name ~= "sub" end }) do
    kept = kept + 1
  end
  ok(kept == 3, "walk filter pruning 'sub' yields 3 entries (got " .. tostring(kept) .. ")")

  -- structured tree(): root node size rolls up to 14
  local t = tree.tree(tmproot)
  ok(t.size == 14,             "structured tree root size == 14 (got " .. tostring(t.size) .. ")")
  ok(t.is_dir == true,         "structured tree root is_dir true")
  ok(type(t.children) == "table", "structured tree root has a children list")
end)

ok(acc_ok, "tree.count/du/find/walk/tree accounting over an on-disk tree (" .. tostring(acc_err) .. ")")

-- Best-effort cleanup.
pcall(fs.rmdir, tmproot, true)

if fails == 0 then print("[+] PASS test_tree") os.exit(0) else os.exit(1) end
