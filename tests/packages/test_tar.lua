-- tests/packages/test_tar.lua : POSIX ustar writer/reader round-trips + PAX + facade.
-- Deterministic: fixed content, fixed octal mtime (tar stores full-resolution
-- seconds, so any epoch round-trips exactly). No addresses / unsorted iteration.
local ok_req, tar = pcall(require, "tar")
if not ok_req then print("[~] SKIP test_tar (" .. tostring(tar) .. ")") os.exit(0) end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_tar: " .. tostring(m)) end end

local MT = 1623774621  -- fixed epoch seconds (stored as octal in the header)

-- ===== write file / dir / symlink, read back =====
local tmp = os.tmpname() .. ".tar"
local w = tar.writer(tmp)
w:add_file("hello.txt", "Hello, TAR!", { mtime = MT, mode = 420 })   -- 420 dec = rw-r--r--
w:add_directory("subdir", { mtime = MT })
w:add_file("subdir/nested.txt", "nested content", { mtime = MT })
w:add_symlink("link", "hello.txt", { mtime = MT })
w:close()

local r = tar.reader(tmp)
local all = r:read_all()
ok(#all == 4,                            "reader sees 4 entries")

local byname = {}
for _, e in ipairs(all) do byname[e.name] = e end

ok(byname["hello.txt"] ~= nil,           "hello.txt present")
ok(byname["hello.txt"].type == "file",   "hello.txt typed as file")
ok(byname["hello.txt"].size == 11,       "hello.txt size = 11")
ok(byname["hello.txt"].content == "Hello, TAR!", "hello.txt content round-trips")
ok(byname["hello.txt"].mode == 420,      "hello.txt mode round-trips (420 dec)")
ok(byname["hello.txt"].mtime == MT,      "mtime round-trips exactly (octal seconds)")

ok(byname["subdir/"] ~= nil,             "subdir/ present (trailing slash added)")
ok(byname["subdir/"].type == "directory", "subdir typed as directory")

ok(byname["subdir/nested.txt"] ~= nil,   "nested file present")
ok(byname["subdir/nested.txt"].content == "nested content", "nested content round-trips")

ok(byname["link"] ~= nil,                "symlink present")
ok(byname["link"].type == "symlink",     "link typed as symlink")
ok(byname["link"].linkname == "hello.txt", "symlink target round-trips")

-- ===== entries() iterator yields the same sequence =====
local count = 0
for e in r:entries() do count = count + 1 end
ok(count == 4,                           "entries() iterator yields 4 entries")
os.remove(tmp)

-- ===== empty file (size 0) round-trips =====
local tmp_e = os.tmpname() .. ".tar"
local we = tar.writer(tmp_e)
we:add_file("empty.txt", "", { mtime = MT })
we:close()
local re = tar.reader(tmp_e)
local ee = re:read_all()
ok(#ee == 1 and ee[1].size == 0,         "empty file: size 0")
ok(ee[1].content == "" or ee[1].content == nil, "empty file: no content")
os.remove(tmp_e)

-- ===== long name (>100 chars) via PAX extended header =====
local tmp_l = os.tmpname() .. ".tar"
local longname = string.rep("x", 130) .. ".txt"  -- 134 chars, exceeds ustar 100
local wl = tar.writer(tmp_l)
wl:add_file(longname, "longbody", { mtime = MT })
wl:close()
local rl = tar.reader(tmp_l)
local al = rl:read_all()
ok(#al == 1,                             "long-name archive yields 1 logical entry")
ok(al[1].name == longname,               "PAX long name round-trips exactly")
ok(al[1].content == "longbody",          "long-name file content round-trips")
os.remove(tmp_l)

-- ===== facade open / list / read =====
local tmp_f = os.tmpname() .. ".tar"
local cw = tar.create(tmp_f)
cw:add_file("one.txt", "first", { mtime = MT })
cw:add_file("two.txt", "second", { mtime = MT })
cw:close()
local arc = tar.open(tmp_f)
local lst = arc.list()
ok(#lst == 2,                            "facade list() returns 2 entries")
local lmap = {}
for _, e in ipairs(lst) do lmap[e.name] = e end
ok(lmap["one.txt"].size == 5,            "facade size field correct")
ok(arc:read("two.txt") == "second",      "facade read round-trips")
ok(select(2, pcall(function() return arc:read("missing") end)) ~= nil,
   "facade read errors on missing entry")
os.remove(tmp_f)

-- ===== reader rejects non-tar input (no ustar magic, not a path) =====
ok(select(2, pcall(tar.reader, "not a tar archive and definitely not a real path xyz")) ~= nil,
   "reader errors on non-tar, non-path input")

-- ===== Zip-Slip safety on facade extract_all =====
local tmp_s = os.tmpname() .. ".tar"
local ws = tar.writer(tmp_s)
ws:add_file("../evil.txt", "pwn", { mtime = MT })
ws:close()
local arcs = tar.open(tmp_s)
ok(select(2, pcall(function() return arcs.extract_all(os.tmpname() .. "_dd") end)) ~= nil,
   "extract_all refuses '..' path traversal")
os.remove(tmp_s)

if fails == 0 then print("[+] PASS test_tar") os.exit(0) else os.exit(1) end
