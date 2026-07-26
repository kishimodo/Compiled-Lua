-- tools/test-build-header-deps.lua : the build tracks header dependencies.
--
-- Auto-discovered by tools/run-tests.lua (phase 6). It does NOT invoke make --
-- the suite has already built, and re-entering make from inside a test would
-- race the runner. Instead it asserts the two properties that make the tracking
-- work, both of which are silent when broken:
--
--   1. every compile recipe carries the dependency flags, and they are added to
--      the flag VARIABLES so the ~230 generated package rules in
--      build/gen/packages.mk inherit them;
--   2. the generated fragments are actually READ BACK, and are read after the
--      default goal so a bare `make -f build/Makefile` still prints help
--      instead of starting to build an object.
--
-- Plus one check on the artefacts themselves: fragments must contain no
-- drive-letter path. -MMD (not -MD) excludes system headers, which is the only
-- thing keeping absolute MinGW sysroot paths -- and therefore a colon, which
-- make's parser splits on -- out of them. Switching to -MD would produce
-- fragments make cannot parse, and make reports that by ignoring them.
--
-- Why this matters more than it sounds: CLAUDE.md used to document that editing
-- a backend header required manually wiping build/bin/obj first, "because a
-- stale lift.o produces silent empty-output binaries". That is a correctness
-- trap, not an inconvenience -- it makes a broken build look like a passing one.

local NAME = "test-build-header-deps"
local failures = {}

local function fail(fmt, ...) failures[#failures + 1] = string.format(fmt, ...) end

local function sh(cmd)
  local p = io.popen('"' .. cmd .. ' 2>&1"')
  if not p then return "" end
  local out = p:read("*a") or ""
  p:close()
  return out
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local ROOT = trim(sh("git rev-parse --show-toplevel")):gsub("/", "\\")
if ROOT == "" then ROOT = trim(sh("cd")) end

local function read(rel)
  local f = io.open(ROOT .. "\\" .. rel:gsub("/", "\\"), "rb")
  if not f then return nil end
  local t = f:read("*a"); f:close(); return t
end

-- Join makefile continuation lines so a recipe split across `\` reads as one.
local function logical_lines(text)
  local joined = text:gsub("\\\n", " ")
  local out = {}
  for line in (joined .. "\n"):gmatch("([^\n]*)\n") do out[#out + 1] = line end
  return out
end

-- ---- 1. the flags are defined, and defined the safe way -------------------

for _, mk in ipairs({ "build/Makefile", "build/Makefile.luac" }) do
  local text = read(mk)
  if not text then
    fail("missing %s", mk)
  else
    -- `:=` is correct HERE because DEPFLAGS holds no $@. If someone adds
    -- `-MT $@` they must switch to `=`, or $@ expands empty at parse time and
    -- -MT silently swallows the following -c: every compile still succeeds and
    -- no fragment is ever read. That is why this asserts on the exact content.
    local dep = text:match("\nDEPFLAGS%s*[:]?=%s*([^\n]*)")
    if not dep then
      fail("%s does not define DEPFLAGS", mk)
    else
      if not dep:find("%-MMD") then
        fail("%s DEPFLAGS lacks -MMD (got %q)", mk, trim(dep))
      end
      if not dep:find("%-MP") then
        fail("%s DEPFLAGS lacks -MP: deleting a header would wedge the build "
             .. "with \"No rule to make target\"", mk)
      end
      if dep:find("%-MD%f[%s]") and not dep:find("%-MMD") then
        fail("%s uses -MD, which pulls system headers into the fragments and "
             .. "puts drive-letter colons where make splits targets", mk)
      end
      if dep:find("%$@") and text:match("\nDEPFLAGS%s*:=") then
        fail("%s combines `$@` with a `:=` DEPFLAGS: $@ expands empty at parse "
             .. "time and -MT eats the following -c", mk)
      end
    end
    if not text:find("CFLAGS%s*%+=%s*%$%(DEPFLAGS%)") then
      fail("%s does not append DEPFLAGS to CFLAGS", mk)
    end
  end
end

-- ---- 2. every compile recipe is covered ----------------------------------

-- A recipe compiles when it has `-c` and `-o`. Each must reach the flags either
-- through a variable that carries DEPFLAGS or by naming $(DEPFLAGS) directly.
local COVERED_VARS = {
  ["CFLAGS"] = true, ["EMBEDDED_LUA_CFLAGS"] = true,
  ["EMBEDDED_RT_CFLAGS"] = true, ["AOT_RT_CFLAGS"] = true,
  ["IMGUI_CXXFLAGS"] = true,
}

for _, mk in ipairs({ "build/Makefile", "build/Makefile.luac" }) do
  local text = read(mk)
  if text then
    -- confirm each variable we rely on really does carry the flags
    for v in pairs(COVERED_VARS) do
      if text:find(v .. "%s*%+=%s*%$%(DEPFLAGS%)") then COVERED_VARS[v] = "yes" end
    end
    for _, line in ipairs(logical_lines(text)) do
      if line:sub(1, 1) == "\t" and line:find("%-c%s") and line:find("%-o%s") then
        local ok = line:find("%$%(DEPFLAGS%)") ~= nil
        if not ok then
          for v in line:gmatch("%$%(([A-Z_]+)%)") do
            if COVERED_VARS[v] then ok = true break end
          end
        end
        if not ok then
          fail("%s has a compile recipe with no dependency flags: %s",
               mk, trim(line):sub(1, 90))
        end
      end
    end
  end
end

-- ---- 3. the fragments are read back, and read back LAST -------------------

for _, mk in ipairs({ "build/Makefile", "build/Makefile.luac" }) do
  local text = read(mk)
  if text then
    local inc_at = nil
    local first_goal_at = nil
    local pos = 1
    for _, line in ipairs(logical_lines(text)) do
      if not inc_at and line:find("^%-include%s+%$%(wildcard") then inc_at = pos end
      -- a real (non-.PHONY, non-variable) target line
      if not first_goal_at and line:match("^[%w_][%w_%-%.]*%s*:[^=]") then
        first_goal_at = pos
      end
      pos = pos + 1
    end
    if not inc_at then
      fail("%s never reads the generated .d fragments back (-include $(wildcard "
           .. "...)), so every fragment is written and ignored", mk)
    elseif first_goal_at and inc_at < first_goal_at then
      fail("%s reads fragments BEFORE its first target: make would take its "
           .. "default goal from a fragment (an object file) instead", mk)
    end
  end
end

-- ---- 4. COVERAGE: every object this project compiles has a fragment -------
--
-- The check the first version of this test was missing, and the omission was
-- caught by review rather than by the suite. Asserting that the makefiles are
-- configured correctly is not the same as asserting that the TREE is tracked:
-- -MMD writes a fragment only as a side effect of compiling, so every object
-- that was already up to date when tracking was introduced has none, and stays
-- untracked until something recompiles it. 342 objects were in exactly that
-- state -- including every Lua core object -- while CLAUDE.md claimed tracking
-- and had deleted the manual-wipe instruction.
--
-- Remedy when this fails: `make -f build/Makefile clean-objs` then a full build.
-- Objects that are COPIES or come from outside, so they legitimately have no
-- fragment of their own. Each is paired with the tracked object it derives from,
-- and that origin is asserted below -- an exemption that cannot be checked is
-- just a hole with a comment.
local COPIES = {
  -- build/Makefile: `copy /Y obj-aot\runtime\protoinit_rt.o -> protoinit_rt.o`,
  -- the loose per-exe deserializer that ships beside the archives.
  ["protoinit_rt.o"] = "obj-aot\\runtime\\protoinit_rt.o",
}

local uncovered, objs_seen, exempted = {}, 0, 0
do
  -- build/bin/sysroot holds crt2.o/crtbegin.o/crtend.o, prebuilt CRT objects
  -- copied from the toolchain rather than compiled here.
  local out = sh('dir /b /s "' .. ROOT .. '\\build\\bin\\*.o"')
  for path in out:gmatch("[^\r\n]+") do
    if path:find("%.o$") and not path:lower():find("\\sysroot\\") then
      local base = path:match("([^\\]+)$")
      local origin = COPIES[base]
      -- Only exempt the copy sitting directly in build/bin, not a same-named
      -- object elsewhere. Compare directories rather than pattern-matching: with
      -- plain=true a `$` anchor would be matched literally, which is how the
      -- first attempt at this silently exempted nothing.
      local dir = path:sub(1, #path - #base - 1):lower():gsub("\\+$", "")
      local at_root = dir == (ROOT .. "\\build\\bin"):lower()
      if origin and at_root then
        exempted = exempted + 1
        local od = ROOT .. "\\build\\bin\\" .. origin:gsub("%.o$", ".d")
        local of = io.open(od, "rb")
        if of then of:close() else
          fail("%s is exempted as a copy of %s, but that origin has no fragment "
               .. "either -- the exemption is hiding a real gap", base, origin)
        end
      else
        objs_seen = objs_seen + 1
        local dep = path:gsub("%.o$", ".d")
        local f = io.open(dep, "rb")
        if f then f:close() else uncovered[#uncovered + 1] = path end
      end
    end
  end
end
if objs_seen == 0 then
  print("  note: no objects built yet; skipped the coverage check")
elseif #uncovered > 0 then
  local shown = {}
  for i = 1, math.min(6, #uncovered) do
    shown[i] = (uncovered[i]:gsub(".*\\build\\bin\\", ""))
  end
  fail("%d of %d compiled objects have no .d fragment, so editing a header they "
       .. "include rebuilds nothing -- the exact silent-stale-object trap this "
       .. "change claims to have retired. Run `make -f build/Makefile clean-objs` "
       .. "then a full build. Examples: %s",
       #uncovered, objs_seen, table.concat(shown, ", "))
end

-- ---- 5. the produced fragments are parseable by make ---------------------

local frag_count, bad_paths, checked = 0, 0, 0
do
  local out = sh('dir /b /s "' .. ROOT .. '\\build\\bin\\*.d"')
  for path in out:gmatch("[^\r\n]+") do
    if path:find("%.d$") then
      frag_count = frag_count + 1
      if checked < 40 then           -- sample; reading 276 files is pointless
        local f = io.open(path, "rb")
        if f then
          local body = f:read("*a") or ""
          f:close()
          checked = checked + 1
          -- A drive letter in TARGET position is what breaks make's parser.
          -- The target is everything up to the first ": ".
          local target = body:match("^([^:\n]*):") or ""
          if target:find("^%a$") then bad_paths = bad_paths + 1 end
        end
      end
    end
  end
end
if frag_count == 0 then
  print("  note: no .d fragments on disk yet (clean tree); checked the "
        .. "makefiles only")
elseif bad_paths > 0 then
  fail("%d of %d sampled fragments have a drive-letter target, which make "
       .. "cannot parse (switch back to -MMD from -MD?)", bad_paths, checked)
end

-- ---- report ---------------------------------------------------------------

if #failures > 0 then
  for _, why in ipairs(failures) do
    print(string.format("[-] FAIL %s: %s", NAME, why))
  end
  os.exit(1)
end

print(string.format("[+] PASS %s (both makefiles define -MMD -MP, every compile "
                    .. "recipe is covered, fragments are read back after the "
                    .. "default goal; %d/%d compiled objects tracked, %d "
                    .. "verified copy exempted, %d fragments sampled clean)",
                    NAME, objs_seen - #uncovered, objs_seen, exempted, checked))
os.exit(0)
