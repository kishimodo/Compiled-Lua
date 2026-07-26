-- tools/test-agent-workspace.lua : the shared agent workspace stays shared.
--
-- Auto-discovered by tools/run-tests.lua (phase 6, tools/test-*.lua) and run
-- under the reference interpreter. It gates the invariants that let two agents
-- work from different worktrees against one set of files:
--
--   * review / roadmap / benchmark / handoff / coordination material exists at
--     repository-relative locations, and nowhere under .codex/ or .claude/;
--   * the client files carry MCP registration only;
--   * CLAUDE.md and AGENTS.md point at the same shared locations;
--   * shared files hard-code no machine path and no worktree name;
--   * tools/agent-coordination/repo-paths.py derives the repository root and
--     Git common directory from Git at run time, and agrees with Git here.
--
-- Everything resolves from the worktree this runs in, so the test passes from
-- the main checkout and from any linked worktree.

local NAME = "test-agent-workspace"
local failures = {}

local function fail(fmt, ...)
  failures[#failures + 1] = string.format(fmt, ...)
end

local function sh(cmd)                    -- trimmed stdout, or nil
  local p = io.popen(cmd .. " 2>nul")
  if not p then return nil end
  local out = p:read("*a") or ""
  p:close()
  out = out:gsub("^%s+", ""):gsub("%s+$", "")
  if out == "" then return nil end
  return out
end

-- ---- dynamic roots: never a remembered path -------------------------------

local ROOT = sh("git rev-parse --show-toplevel") or "."
ROOT = ROOT:gsub("/", "\\"):gsub("\\+$", "")
local COMMON = sh("git rev-parse --path-format=absolute --git-common-dir")
if COMMON then COMMON = COMMON:gsub("/", "\\"):gsub("\\+$", "") end

local function abs(rel) return ROOT .. "\\" .. rel:gsub("/", "\\") end

local function read(rel)
  local f = io.open(abs(rel), "rb")
  if not f then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function exists(rel) return read(rel) ~= nil end

local function list_md(rel)
  local out = sh('dir /b "' .. abs(rel) .. '\\*.md"')
  local names = {}
  if out then
    for line in out:gmatch("[^\r\n]+") do names[#names + 1] = line end
  end
  return names
end

-- ---- 1. shared locations exist and hold documents -------------------------

local SHARED_DIRS = {
  audits       = "docs/audits",
  roadmaps     = "docs/roadmaps",
  benchmarks   = "docs/benchmarks",
  handoff      = "docs/handoff",
  coordination = "tools/agent-coordination",
}

for kind, rel in pairs(SHARED_DIRS) do
  local docs = list_md(rel)
  if #docs == 0 then
    fail("shared %s location %s holds no markdown", kind, rel)
  end
end

local REQUIRED = {
  "docs/audits/2026-07-25-concurrency-size-stability-audit.md",
  "docs/audits/2026-07-25-second-reviewer-challenge.md",
  "docs/roadmaps/concurrency-size-stability.md",
  "docs/benchmarks/README.md",
  "docs/benchmarks/linker-index.md",
  "docs/benchmarks/codegen-savedpc.md",
  "docs/handoff/README.md",
  "tools/agent-coordination/README.md",
  "tools/agent-coordination/repo-paths.py",
  "tools/agent-coordination/server.py",
  "tools/agent-coordination/new-worktree.ps1",
}
for _, rel in ipairs(REQUIRED) do
  if not exists(rel) then fail("missing shared file: %s", rel) end
end

-- ---- 2. nothing shared drifted into a client directory --------------------

for _, client in ipairs({ ".codex", ".claude" }) do
  for _, leaf in ipairs({ "audits", "roadmaps", "benchmarks", "handoff", "docs" }) do
    if #list_md(client .. "/" .. leaf) > 0 then
      fail("shared material must not live under %s/%s", client, leaf)
    end
  end
end

-- Client files carry MCP registration only: they name the coordination server
-- and nothing else about the shared workspace.
for _, rel in ipairs({ ".mcp.json", ".codex/config.toml" }) do
  local text = read(rel)
  if not text then
    fail("missing client registration file: %s", rel)
  else
    if not text:find("tools/agent%-coordination/server%.py", 1, false) then
      fail("%s should register tools/agent-coordination/server.py", rel)
    end
    if text:find("docs/", 1, true) then
      fail("%s carries shared content; it must hold registration only", rel)
    end
    -- A drive-letter path only; "%a:[\\/]" alone would also match a URL scheme.
    if text:find("%a:\\") or text:find("[Uu]sers[\\/]") then
      fail("%s hard-codes an absolute path", rel)
    end
  end
end

-- ---- 3. both guides point at the same shared locations -------------------

for _, guide in ipairs({ "CLAUDE.md", "AGENTS.md" }) do
  local text = read(guide)
  if not text then
    fail("missing %s", guide)
  else
    for _, rel in ipairs({ "docs/audits/", "docs/roadmaps/", "docs/benchmarks/",
                           "docs/handoff/", "tools/agent-coordination/README.md",
                           "tools/agent-coordination/repo-paths.py" }) do
      if not text:find(rel, 1, true) then
        fail("%s does not point at %s", guide, rel)
      end
    end
  end
end

-- ---- 4. shared files hard-code no machine path or worktree name ----------

-- A user-profile path or a sibling-worktree directory name would tie a shared
-- file to one machine. System paths are deliberately NOT banned: the audit and
-- the handoff legitimately discuss C:\Windows\System32\tar.exe and OneDrive as
-- Windows conditions to test. The developer-machine defaults in build/*.bat are
-- a separate, tracked item (roadmap: standing prerequisites).
local BANNED = {
  { pat = "%a:[\\/][Uu]sers[\\/]",  why = "absolute user-profile path" },
  { pat = "CLua%-codex%-",          why = "hard-coded worktree name" },
  { pat = "CLua%-claude%-",         why = "hard-coded worktree name" },
  { pat = "%.claude[\\/]projects",  why = "path outside the repository" },
}
local SCANNED = { "CLAUDE.md", "AGENTS.md" }
for _, rel in ipairs({ "docs/audits", "docs/roadmaps", "docs/benchmarks", "docs/handoff" }) do
  for _, doc in ipairs(list_md(rel)) do SCANNED[#SCANNED + 1] = rel .. "/" .. doc end
end
for _, doc in ipairs(list_md("tools/agent-coordination")) do
  SCANNED[#SCANNED + 1] = "tools/agent-coordination/" .. doc
end
SCANNED[#SCANNED + 1] = "tools/agent-coordination/repo-paths.py"
SCANNED[#SCANNED + 1] = "tools/agent-coordination/server.py"
SCANNED[#SCANNED + 1] = "tools/agent-coordination/new-worktree.ps1"

for _, rel in ipairs(SCANNED) do
  local text = read(rel)
  if text then
    for _, banned in ipairs(BANNED) do
      if text:find(banned.pat) then
        fail("%s contains a banned pattern: %s (/%s/)", rel, banned.why, banned.pat)
      end
    end
  end
end

-- ---- 5. the path helper derives, and agrees with Git ---------------------

local helper = read("tools/agent-coordination/repo-paths.py") or ""
for _, needed in ipairs({ "rev%-parse", "%-%-show%-toplevel", "%-%-git%-common%-dir" }) do
  if not helper:find(needed) then
    fail("repo-paths.py does not derive paths via git %s", (needed:gsub("%%", "")))
  end
end

local have_python = sh("python --version") ~= nil
if have_python then
  local reported_root = sh('python "' .. abs("tools/agent-coordination/repo-paths.py")
                           .. '" --get repo_root')
  local reported_common = sh('python "' .. abs("tools/agent-coordination/repo-paths.py")
                             .. '" --get git_common_dir')
  local function norm(p)
    return p and p:gsub("/", "\\"):gsub("\\+$", ""):lower() or nil
  end
  if norm(reported_root) ~= norm(ROOT) then
    fail("repo-paths.py repo_root %s does not match git %s",
         tostring(reported_root), tostring(ROOT))
  end
  if COMMON and norm(reported_common) ~= norm(COMMON) then
    fail("repo-paths.py git_common_dir %s does not match git %s",
         tostring(reported_common), tostring(COMMON))
  end
  -- --check is the same contract the helper offers to a human.
  local ok = os.execute('python "' .. abs("tools/agent-coordination/repo-paths.py")
                        .. '" --check >nul 2>nul')
  if ok ~= true and ok ~= 0 then
    fail("repo-paths.py --check reported a broken shared layout")
  end
else
  print("  note: python not on PATH; checked repo-paths.py statically only")
end

-- ---- report ---------------------------------------------------------------

if #failures > 0 then
  for _, why in ipairs(failures) do
    print(string.format("[-] FAIL %s: %s", NAME, why))
  end
  os.exit(1)
end

print(string.format("[+] PASS %s (%d shared files scanned, root derived from git)",
                    NAME, #SCANNED))
os.exit(0)
