local ok_req, path = pcall(require, "path")
if not ok_req then print("[~] SKIP test_path") os.exit(0) end
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_path: " .. tostring(m)) end end
local function eq(got, want, m)
    ok(got == want, (m or "") .. " -> got " .. tostring(got) .. " want " .. tostring(want))
end

-- ===== separators =====
eq(path.sep, "\\", "sep")
eq(path.altsep, "/", "altsep")

-- ===== join (absolute component resets, like Python os.path.join) =====
eq(path.join("a", "b"), "a\\b", "join two rel")
eq(path.join("a", "b", "c"), "a\\b\\c", "join three rel")
eq(path.join("a\\", "b"), "a\\b", "join no double sep when first ends in sep")
eq(path.join("a", "C:\\x"), "C:\\x", "join: absolute resets")
eq(path.join("", "b"), "b", "join: empty skipped at front")
eq(path.join("a", "", "b"), "a\\b", "join: empty skipped in middle")
eq(path.join("C:\\foo", "bar"), "C:\\foo\\bar", "join under drive")
eq(path.join("/foo", "bar"), "/foo\\bar", "join: rooted first keeps its slash style")

-- ===== normalize: collapse . and .. , dedup separators =====
eq(path.normalize("a/b/../c"), "a/c", "normalize .. pops (posix style preserved)")
eq(path.normalize("a/./b"), "a/b", "normalize . dropped")
eq(path.normalize("a//b"), "a/b", "normalize dedups separators")
eq(path.normalize("a\\b\\..\\c"), "a\\c", "normalize backslash .. pops")
eq(path.normalize(""), ".", "normalize empty -> dot")
eq(path.normalize("."), ".", "normalize lone dot")
eq(path.normalize("C:\\foo\\..\\bar"), "C:\\bar", "normalize under drive")
eq(path.normalize("C:\\..\\..\\foo"), "C:\\foo", "normalize: excess .. eaten under absolute anchor")
eq(path.normalize("../a"), "../a", "normalize: leading .. kept when relative (preserves slash style)")
eq(path.normalize("..\\a"), "..\\a", "normalize: leading .. kept when relative (preserves backslash style)")
eq(path.normalize("a/b/"), "a/b", "normalize: trailing slash dropped")

-- ===== resolve = join + normalize =====
eq(path.resolve("a", "b", "..", "c"), "a\\c", "resolve join+normalize")
eq(path.resolve("C:\\foo", "..\\bar"), "C:\\bar", "resolve under drive")

-- ===== split / basename / dirname =====
do
    local d, f = path.split("C:\\foo\\bar.txt")
    eq(d, "C:\\foo", "split dir")
    eq(f, "bar.txt", "split file")
end
eq(path.basename("C:\\foo\\bar.txt"), "bar.txt", "basename")
eq(path.basename("bar.txt"), "bar.txt", "basename no dir")
eq(path.basename("C:\\foo\\"), "", "basename of trailing-sep dir")
eq(path.dirname("C:\\foo\\bar.txt"), "C:\\foo", "dirname")
eq(path.dirname("bar.txt"), "", "dirname no dir")
eq(path.basename("a/b/c"), "c", "basename posix style")
eq(path.dirname("a/b/c"), "a/b", "dirname posix style")

-- ===== extname / stem =====
eq(path.extname("bar.txt"), ".txt", "extname")
eq(path.extname("archive.tar.gz"), ".gz", "extname last only")
eq(path.extname("noext"), "", "extname none")
eq(path.extname(".gitignore"), "", "extname: leading dot is not an extension")
eq(path.extname("C:\\dir.with.dot\\file"), "", "extname: dot in dir does not count")
eq(path.stem("bar.txt"), "bar", "stem")
eq(path.stem("archive.tar.gz"), "archive.tar", "stem strips last ext only")
eq(path.stem("noext"), "noext", "stem no ext")

-- ===== is_absolute / is_relative =====
ok(path.is_absolute("C:\\foo"), "is_absolute drive+sep")
ok(not path.is_absolute("C:foo"), "drive-relative is NOT absolute")
ok(path.is_absolute("\\foo"), "is_absolute rooted backslash")
ok(path.is_absolute("/foo"), "is_absolute rooted slash")
ok(path.is_absolute("\\\\server\\share\\x"), "is_absolute UNC")
ok(not path.is_absolute("foo\\bar"), "relative not absolute")
ok(path.is_relative("foo\\bar"), "is_relative")
ok(not path.is_relative("C:\\foo"), "abs not relative")

-- ===== drive helpers =====
ok(path.has_drive("C:\\foo"), "has_drive")
ok(path.has_drive("c:foo"), "has_drive lowercase")
ok(not path.has_drive("\\foo"), "no drive on rooted")
eq(path.drive("C:\\foo"), "C:", "drive letter")
eq(path.drive("foo\\bar"), "", "drive of relative is empty")
eq(path.strip_drive("C:\\foo"), "\\foo", "strip_drive")
eq(path.strip_drive("foo"), "foo", "strip_drive: no-op on relative")

-- ===== to_posix / to_native =====
eq(path.to_posix("C:\\foo\\bar"), "C:/foo/bar", "to_posix")
eq(path.to_native("C:/foo/bar"), "C:\\foo\\bar", "to_native")

-- ===== equals (case-insensitive, normalize-first) =====
ok(path.equals("C:\\Foo\\Bar", "c:\\foo\\bar"), "equals case-insensitive")
ok(path.equals("C:\\foo\\..\\bar", "C:\\bar"), "equals after normalize")
ok(not path.equals("C:\\foo", "C:\\bar"), "not equal distinct")

-- ===== UNC =====
ok(path.is_unc("\\\\server\\share\\x"), "is_unc")
ok(not path.is_unc("C:\\foo"), "drive is not UNC")
eq(path.unc_root("\\\\server\\share\\dir\\f"), "\\\\server\\share", "unc_root")

-- ===== long prefix / device =====
ok(path.is_long_prefixed("\\\\?\\C:\\x"), "is_long_prefixed")
ok(path.is_device("\\\\.\\PhysicalDrive0"), "is_device")
ok(not path.is_long_prefixed("C:\\x"), "plain drive not long-prefixed")
eq(path.strip_long_prefix("\\\\?\\C:\\x"), "C:\\x", "strip_long_prefix")

-- ===== relative =====
eq(path.relative("C:\\a\\b", "C:\\a\\b\\c\\d"), "c\\d", "relative descend")
eq(path.relative("C:\\a\\b\\c", "C:\\a\\b"), "..", "relative ascend")
eq(path.relative("C:\\a\\b", "C:\\a\\b"), ".", "relative same")
eq(path.relative("C:\\a\\x", "C:\\a\\y"), "..\\y", "relative sibling")

-- ===== parts / name / parent / extension aliases =====
do
    local pr = path.parts("C:\\foo\\bar.txt")
    eq(pr[1], "C:\\", "parts anchor")
    eq(pr[2], "foo", "parts comp 1")
    eq(pr[3], "bar.txt", "parts comp 2")
end
eq(path.name("C:\\foo\\bar.txt"), "bar.txt", "name alias = basename")
eq(path.parent("C:\\foo\\bar.txt"), "C:\\foo", "parent alias = dirname")
eq(path.extension("bar.txt"), ".txt", "extension alias = extname")

-- ===== split3 =====
do
    local dir, stem, ext = path.split3("C:\\foo\\bar.txt")
    eq(dir, "C:\\foo", "split3 dir")
    eq(stem, "bar", "split3 stem")
    eq(ext, ".txt", "split3 ext")
end

-- ===== is_reserved (DOS device names) =====
ok(path.is_reserved("CON"), "is_reserved CON")
ok(path.is_reserved("nul.txt"), "is_reserved nul.txt (ext stripped)")
ok(path.is_reserved("COM1"), "is_reserved COM1")
ok(not path.is_reserved("console"), "console is not reserved")
ok(not path.is_reserved("readme.txt"), "ordinary name not reserved")

if fails == 0 then print("[+] PASS test_path") os.exit(0) else os.exit(1) end
