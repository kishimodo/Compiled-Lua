-- tools/test-doc-style.lua : prose gate for every tracked .md file.
--
-- Auto-discovered by tools/run-tests.lua (phase 6). Enforces a small, boring
-- set of typographic rules across the repository's Markdown so the docs read
-- like a human who has been up too long typed them, not like something an
-- assistant paste-glossed. Same shape as test-object-freshness.lua: enumerate
-- with `git ls-files`, read with io.open, one FAIL line per finding, one PASS
-- line on green, exit 0/1.
--
-- The rules, in one place so a reader does not have to chase the code:
--
--   1. no em dash        U+2014
--   2. no en dash        U+2013
--   3. no smart quotes   U+2018 U+2019 U+201C U+201D
--   4. no ellipsis char  U+2026    (three ASCII dots are fine)
--   5. no bullet char    U+2022    (ASCII hyphen for bullets)
--   6. no other >127 bytes in prose. EXCEPTION: content inside a fenced code
--      block ``` ... ``` and content between matching `backticks` is exempt,
--      because a Lua-package doc may legitimately show a UTF-8 string literal.
--   7. these case-insensitive whole-word phrases fail on sight:
--        "as an ai", "i hope this helps", "great question",
--        "let me know if you have any", "certainly!"
--
-- Reports each finding as  <path>:<line>:<col> <what>, so a grep-jump lands on
-- the exact byte. Column is 1-based BYTE index within the line (Markdown is
-- byte-oriented for this purpose and the bad characters are all multi-byte, so
-- the column points at the first byte of the offender).
--
-- Skips docs/plan-0.3.0-beta.2.md when present: that file predates the rules,
-- it is the reason the rules exist, and phase 1 of the plan is to re-humanise
-- it. Enforcing this gate against it before that phase would just gridlock.

local NAME = "test-doc-style"

local SKIP_FILES = {
  ["docs/plan-0.3.0-beta.2.md"] = true,
}

-- Whole-word case-insensitive phrases. "Whole word" means the character before
-- the match and the character after the match must not be an ASCII letter or
-- digit -- so "great question" fails but "greatquestioning" does not, and
-- "great" on its own does not fail either.
local PHRASES = {
  "as an ai",
  "i hope this helps",
  "great question",
  "let me know if you have any",
  "certainly!",
}

-- The named non-ASCII characters, keyed by their UTF-8 byte sequence, mapped
-- to a short human name for the FAIL line. Everything else with a byte > 127
-- (that is not shielded by a code fence or inline `code`) is reported as a
-- generic "non-ASCII U+XXXX".
local NAMED = {
  ["\xE2\x80\x94"] = "em dash (U+2014)",
  ["\xE2\x80\x93"] = "en dash (U+2013)",
  ["\xE2\x80\x98"] = "left single quote (U+2018)",
  ["\xE2\x80\x99"] = "right single quote (U+2019)",
  ["\xE2\x80\x9C"] = "left double quote (U+201C)",
  ["\xE2\x80\x9D"] = "right double quote (U+201D)",
  ["\xE2\x80\xA6"] = "horizontal ellipsis (U+2026); use three ASCII dots",
  ["\xE2\x80\xA2"] = "bullet (U+2022); use ASCII hyphen",
}

local function sh(cmd)
  local p = io.popen('"' .. cmd .. ' 2>&1"')
  if not p then return "" end
  local out = p:read("*a") or ""
  p:close()
  return out
end

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

-- Enumerate the tracked .md files. Untracked or ignored files (like a WIP
-- draft in a scratch dir) are deliberately out of scope: the gate covers what
-- ships in the repo, not everything a working tree happens to contain.
local function md_files()
  local out = sh("git ls-files -- \"*.md\"")
  local files = {}
  for line in out:gmatch("[^\r\n]+") do
    line = trim(line)
    if #line > 0 then files[#files + 1] = line end
  end
  return files
end

-- Read a whole file as bytes. Missing file returns nil, "" -- treated as a
-- skip below rather than a failure, because `git ls-files` can list a path
-- that a case-difference or filesystem oddity keeps io.open from opening.
local function read_all(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a") or ""
  f:close()
  return data
end

-- Split into lines WITHOUT dropping empty ones. gmatch("[^\n]+") elides
-- consecutive newlines, which would silently mis-number every line after a
-- blank one -- and this gate reports line numbers, so it has to be exact.
local function split_lines(s)
  local lines, start = {}, 1
  for i = 1, #s do
    if s:byte(i) == 10 then                       -- \n
      local ln = s:sub(start, i - 1)
      if ln:sub(-1) == "\r" then ln = ln:sub(1, -2) end
      lines[#lines + 1] = ln
      start = i + 1
    end
  end
  if start <= #s then
    local ln = s:sub(start)
    if ln:sub(-1) == "\r" then ln = ln:sub(1, -2) end
    lines[#lines + 1] = ln
  end
  return lines
end

-- Decode ONE UTF-8 codepoint starting at byte index i. Returns
-- codepoint, byte_length. On an invalid sequence returns the raw byte and 1,
-- so the scanner always makes progress even on malformed input.
local function utf8_at(s, i)
  local b1 = s:byte(i)
  if not b1 then return nil, 0 end
  if b1 < 0x80 then return b1, 1 end
  if b1 < 0xC0 then return b1, 1 end             -- stray continuation byte
  if b1 < 0xE0 then
    local b2 = s:byte(i + 1) or 0
    return ((b1 - 0xC0) * 0x40) + (b2 % 0x40), 2
  end
  if b1 < 0xF0 then
    local b2 = s:byte(i + 1) or 0
    local b3 = s:byte(i + 2) or 0
    return ((b1 - 0xE0) * 0x1000) + ((b2 % 0x40) * 0x40) + (b3 % 0x40), 3
  end
  local b2 = s:byte(i + 1) or 0
  local b3 = s:byte(i + 2) or 0
  local b4 = s:byte(i + 3) or 0
  return ((b1 - 0xF0) * 0x40000) + ((b2 % 0x40) * 0x1000)
       + ((b3 % 0x40) * 0x40)   + (b4 % 0x40), 4
end

-- Mask the ranges that a non-ASCII byte is ALLOWED to live inside on a given
-- line: anything between matching single backticks. Returns a boolean array
-- with `true` at every column that sits inside an inline code span. A stray
-- unmatched backtick leaves the tail of the line uncovered, which is the
-- correct behaviour -- Markdown itself renders it as a literal.
local function inline_code_mask(line)
  local mask = {}
  local n = #line
  local i, in_code = 1, false
  while i <= n do
    if line:byte(i) == 96 then                   -- `
      in_code = not in_code
      mask[i] = in_code                          -- the backtick itself: exempt if opening
    else
      mask[i] = in_code
    end
    i = i + 1
  end
  return mask
end

-- Whole-word phrase check. `s` is already lower-cased. Returns start column
-- (1-based) or nil.
local function find_phrase(s, phrase)
  local start = 1
  while true do
    local a, b = s:find(phrase, start, true)     -- plain, no pattern surprises
    if not a then return nil end
    local before = a > 1 and s:sub(a - 1, a - 1) or ""
    local after  = b < #s and s:sub(b + 1, b + 1) or ""
    local function wordish(c) return c ~= "" and c:match("[%w]") ~= nil end
    if not wordish(before) and not wordish(after) then
      return a
    end
    start = a + 1
  end
end

local failures = {}
local function fail(path, line, col, msg)
  failures[#failures + 1] = string.format("%s:%d:%d %s", path, line, col, msg)
end

local checked = 0
for _, path in ipairs(md_files()) do
  if not SKIP_FILES[path] then
    local data = read_all(path)
    if data then
      checked = checked + 1
      local lines = split_lines(data)
      local in_fence = false
      for lineno, line in ipairs(lines) do
        -- A fenced code block opens/closes on any line whose FIRST non-space
        -- content is ``` (optionally followed by a language tag). We stay
        -- inside the fence for the whole span, so a UTF-8 string literal in
        -- an example is allowed.
        local fence = line:match("^%s*```")
        if fence then
          in_fence = not in_fence
        elseif not in_fence then
          local mask = inline_code_mask(line)
          local i = 1
          while i <= #line do
            local b = line:byte(i)
            if b >= 128 then
              if not mask[i] then
                -- Prefer the named message if the byte sequence matches a
                -- rule-1..5 character; otherwise fall through to the generic
                -- rule-6 "any other non-ASCII" message.
                local named
                for seq, name in pairs(NAMED) do
                  if line:sub(i, i + #seq - 1) == seq then
                    named = name
                    break
                  end
                end
                if named then
                  fail(path, lineno, i, named)
                  i = i + 3                       -- all NAMED entries are 3 bytes
                else
                  local cp, len = utf8_at(line, i)
                  fail(path, lineno, i,
                       string.format("non-ASCII U+%04X (rule 6: prose must be ASCII outside code)", cp or b))
                  i = i + (len > 0 and len or 1)
                end
              else
                -- Inside inline code -- skip the whole codepoint, not one byte,
                -- otherwise the continuation bytes would be re-inspected and
                -- misreported as strays.
                local _, len = utf8_at(line, i)
                i = i + (len > 0 and len or 1)
              end
            else
              i = i + 1
            end
          end

          local lower = line:lower()
          for _, phrase in ipairs(PHRASES) do
            local col = find_phrase(lower, phrase)
            if col then
              fail(path, lineno, col,
                   string.format("prohibited phrase %q", phrase))
            end
          end
        end
      end
    end
  end
end

if #failures == 0 then
  print(string.format("[+] PASS %s: %d markdown files checked", NAME, checked))
  os.exit(0)
end

for _, f in ipairs(failures) do
  print(string.format("[-] FAIL %s: %s", NAME, f))
end
print(string.format("    %d finding(s) across %d markdown file(s); "
                    .. "re-humanise the prose or move the character into a "
                    .. "fenced code block / inline `code` span.",
                    #failures, checked))
os.exit(1)
