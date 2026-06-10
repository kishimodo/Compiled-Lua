-- tests/packages/test_mime.lua : multipart round-trip with realistic boundaries
-- (which contain Lua-pattern metacharacters) and Content-Type parameter parsing
-- with ';' inside a quoted value. Both were broken by pattern misuse.
local mime = require "mime"
local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_mime: " .. tostring(m)) end end

-- format_multipart -> parse_multipart must round-trip for boundaries that
-- contain pattern metacharacters (-, ., +, =) and ones that do not.
local parts = {
  { headers = { ["content-disposition"] = 'form-data; name="a"' }, order = { "content-disposition" }, body = "hello" },
  { headers = { ["content-disposition"] = 'form-data; name="b"' }, order = { "content-disposition" }, body = "world" },
}
local boundaries = {
  "----WebKitFormBoundary7MA4YWxkTrZu0gW",  -- dash-leading
  "boundary_string",                         -- no metachars, no leading dash
  "d41d8cd98f00b204e9800998ecf8427e",        -- hex
  "NextPart.000.001+x=y",                    -- dots, plus, equals
  "--==_NextPart_001",                       -- equals + underscores
}
for _, b in ipairs(boundaries) do
  local enc = mime.format_multipart(parts, b)
  local got = mime.parse_multipart(enc, b)
  ok(#got == 2, "multipart part count for boundary '" .. b .. "' (got " .. #got .. ")")
  if #got == 2 then
    ok(got[1].body == "hello", "part 1 body for boundary '" .. b .. "' (got '" .. tostring(got[1].body) .. "')")
    ok(got[2].body == "world", "part 2 body for boundary '" .. b .. "'")
  end
end

-- Content-Type with ';' inside a quoted parameter value.
local ct = mime.parse_content_type('text/plain; charset="a;b"; x=1')
ok(ct.type == "text/plain",  "content-type main type")
ok(ct.params.charset == "a;b", "quoted param value keeps ';' (got '" .. tostring(ct.params.charset) .. "')")
ok(ct.params.x == "1",        "trailing param after quoted value")

local ct2 = mime.parse_content_type('multipart/form-data; boundary=----X.Y+Z')
ok(ct2.type == "multipart/form-data", "ct2 type")
ok(ct2.params.boundary == "----X.Y+Z", "unquoted boundary param (got '" .. tostring(ct2.params.boundary) .. "')")

local ct3 = mime.parse_content_type('application/json')
ok(ct3.type == "application/json" and next(ct3.params) == nil, "no-params content-type")

if fails == 0 then print("[+] PASS test_mime") os.exit(0) else os.exit(1) end
