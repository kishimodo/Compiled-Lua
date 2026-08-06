-- tools/gen-cli-docs.lua : cli reference generator.
--
-- Shells out to `clua help` (and `rover help` if rover.exe is on the path or
-- next to clua.exe) and parses the output into per-command reference pages
-- under docs/site/cli/. The reference style is the same windows-api layout
-- used by the hand-written pages already in that directory:
--
--   # <command>
--   short one-line description.
--
--   ## syntax
--   ```
--   <invocation line>
--   ```
--
--   ## parameters
--   ...
--   ## return codes
--   ...
--   ## examples
--   ...
--   ## remarks
--   ...
--
-- This script is deliberately conservative: it does not overwrite a page
-- unless invoked with --force. The hand-written pages under docs/site/cli/
-- are the authoritative reference today; the generator's job is to produce
-- a machine-checkable fallback when a new subcommand ships and the docs
-- have not been touched yet.
--
-- Usage:
--
--   build\bin\clua-interp.exe tools\gen-cli-docs.lua [--force] [--dry-run]
--
-- Exit codes:
--   0 - everything the generator was asked to write got written.
--   1 - io error, or `clua help` did not run.
--   2 - argv error.

local OUT_ROOT = "docs/site/cli"

local function slurp(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a") or ""
  f:close()
  return s
end

local function spit(path, s)
  local f, err = io.open(path, "wb")
  if not f then return nil, err end
  f:write(s)
  f:close()
  return true
end

local function file_exists(path)
  local f = io.open(path, "rb")
  if not f then return false end
  f:close()
  return true
end

local function shell(cmd)
  local p = io.popen(cmd .. " 2>&1")
  if not p then return nil end
  local out = p:read("*a") or ""
  p:close()
  return out
end

-- Locate a candidate binary. Try the plain name first (assume PATH), then
-- fall back to a few well-known layouts in this repo. Returns nil if
-- nothing works so the caller can print a clean skip message.
local function find_binary(name)
  local out = shell(string.format('cmd /c "where %s"', name))
  if out and out:match("[%w]") and not out:match("INFO:") then
    for line in out:gmatch("([^\r\n]+)") do
      line = line:gsub("^%s+", ""):gsub("%s+$", "")
      if line ~= "" and file_exists(line) then return line end
    end
  end
  local guesses = {
    "build\\bin\\" .. name,
    "dist\\" .. name,
    name,
  }
  for _, g in ipairs(guesses) do
    if file_exists(g) then return g end
  end
  return nil
end

-- Take the "usage:" section of a `clua help` transcript and return an
-- ordered list of { command, syntax, description } records. Commands are
-- recognised by the leading two-space indent followed by `clua ` and a
-- verb; the syntax is the whole line minus the leading spaces, and the
-- description is the trailing text after the invocation, if any.
local function parse_clua_usage(help)
  local commands = {}
  local in_usage = false
  for line in help:gmatch("([^\r\n]+)") do
    if line:match("^usage:") then
      in_usage = true
    elseif in_usage then
      local body = line:match("^  (clua .*)$")
      if body then
        local verb = body:match("^clua%s+([%w-]+)")
        if verb and verb ~= "" then
          commands[#commands + 1] = { command = verb, syntax = body,
                                      description = "" }
        end
      elseif line:match("^%S") then
        -- left the usage block
        in_usage = false
      end
    end
  end
  return commands
end

local function page_for(binary, rec)
  local buf = {}
  local title = binary .. " " .. rec.command
  buf[#buf + 1] = "# " .. title
  buf[#buf + 1] = ""
  buf[#buf + 1] = "auto-generated placeholder for `" .. title
                  .. "`. the hand-written reference page (if one exists)"
  buf[#buf + 1] = "is authoritative; this file exists so a newly added"
  buf[#buf + 1] = "subcommand shows up in the site index while the human"
  buf[#buf + 1] = "reference catches up."
  buf[#buf + 1] = ""
  buf[#buf + 1] = "## syntax"
  buf[#buf + 1] = ""
  buf[#buf + 1] = "```"
  buf[#buf + 1] = rec.syntax
  buf[#buf + 1] = "```"
  buf[#buf + 1] = ""
  buf[#buf + 1] = "## parameters"
  buf[#buf + 1] = ""
  buf[#buf + 1] = "see `" .. binary .. " help` for the full flag list."
  buf[#buf + 1] = ""
  buf[#buf + 1] = "## return codes"
  buf[#buf + 1] = ""
  buf[#buf + 1] = "- `0`: success."
  buf[#buf + 1] = "- non-zero: see the command output."
  buf[#buf + 1] = ""
  buf[#buf + 1] = "## examples"
  buf[#buf + 1] = ""
  buf[#buf + 1] = "```"
  buf[#buf + 1] = rec.syntax
  buf[#buf + 1] = "```"
  buf[#buf + 1] = ""
  buf[#buf + 1] = "## remarks"
  buf[#buf + 1] = ""
  buf[#buf + 1] = "this page was generated from the output of `"
                  .. binary .. " help`. edit the hand-written reference"
  buf[#buf + 1] = "under `docs/site/cli/" .. binary .. "-" .. rec.command
                  .. ".md` for authoritative content."
  buf[#buf + 1] = ""
  return table.concat(buf, "\n")
end

local function main(argv)
  local force, dry_run = false, false
  for i = 1, #argv do
    if argv[i] == "--force" then force = true
    elseif argv[i] == "--dry-run" then dry_run = true
    else
      io.stderr:write("gen-cli-docs: unknown arg " .. tostring(argv[i]) .. "\n")
      os.exit(2)
    end
  end

  local wrote, skipped, missing = 0, 0, {}

  for _, binary in ipairs({ "clua", "rover" }) do
    local path = find_binary(binary .. ".exe")
    if not path then
      missing[#missing + 1] = binary
      io.write(string.format("[=] %s: not found on PATH or in build\\bin, "
                             .. "skipping.\n", binary))
    else
      local help = shell(string.format('"%s" help', path))
      if not help or help == "" then
        io.stderr:write(string.format("[-] %s: help output empty\n", binary))
        os.exit(1)
      end
      local commands = parse_clua_usage(help)
      for _, rec in ipairs(commands) do
        local out = string.format("%s/%s-%s.md", OUT_ROOT, binary, rec.command)
        if file_exists(out) and not force then
          io.write(string.format("[=] %s: exists, keeping (pass --force to "
                                 .. "overwrite)\n", out))
          skipped = skipped + 1
        elseif dry_run then
          io.write(string.format("[+] %s: (dry run)\n", out))
        else
          local ok, err = spit(out, page_for(binary, rec))
          if not ok then
            io.stderr:write(string.format("[-] write %s: %s\n", out, err))
            os.exit(1)
          end
          wrote = wrote + 1
          io.write(string.format("[+] %s\n", out))
        end
      end
    end
  end

  io.write(string.format("done: %d written, %d kept, %d binary(ies) missing\n",
                         wrote, skipped, #missing))
  os.exit(0)
end

main(arg or {})
