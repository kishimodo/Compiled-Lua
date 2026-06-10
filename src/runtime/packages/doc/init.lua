-- doc -- Doc comment extractor for Lua.
--
-- Recognized doc markers:
--   --- doc line       (a run of consecutive `--- ` lines forms one block)
--   --[[doc ... ]]     (a single block, contents trimmed)
--
-- Inside a block, recognized tags:
--   @param NAME [TYPE] DESCRIPTION
--   @return [TYPE] DESCRIPTION
--   @throws [TYPE] DESCRIPTION
--   @see TARGET
--   @example -- the rest of the block is treated as a fenced code example
--   @since VERSION
--   @module NAME       -- declare module name for index
--   @field NAME TYPE   -- for table-style declarations
--   @deprecated [VERSION] REASON
--
-- Cross-references inside descriptions use [[other.thing]] markdown-style.
--
-- API:
--   doc.extract(source)              -> docnodes
--   doc.extract_file(path)           -> docnodes
--   doc.extract_dir(dir, pattern?)   -> docnodes  (recursive walk via fs)
--   doc.render_markdown(nodes, opts?)
--   doc.render_html(nodes, opts?)
--   doc.render_json(nodes)

local M = {}

-- ===== Source scanning ==================================================

-- Split a Lua source into a list of lines with their numbers.
local function lines_of(src)
    local out, no = {}, 0
    local n = 0
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1
        no = no + 1
        out[no] = { n = n, text = line }
    end
    return out
end

-- Scan a source string into docnodes: each node is
--   { module, name, kind, signature, params={...}, returns={...},
--     throws={...}, see={...}, since=, deprecated=, examples={...},
--     description=, raw_block=, source_line= }
-- kind is "function" | "table" | "variable" | "module" | "free".
local function parse_block(text_lines, opts)
    -- text_lines is the raw doc-comment content, one entry per stripped line.
    local node = {
        params = {}, returns = {}, throws = {}, see = {},
        examples = {}, description = "",
    }
    local desc_buf, db = {}, 0
    local mode = "desc"   -- "desc" | "example"
    local example_buf, eb = nil, 0

    for _, ln in ipairs(text_lines) do
        local t = ln

        -- Tag line?
        local tag, rest = t:match("^@(%w+)%s*(.*)$")
        if tag then
            -- Close any open example block.
            if mode == "example" then
                node.examples[#node.examples + 1] = table.concat(example_buf, "\n")
                mode = "desc"
                example_buf, eb = nil, 0
            end
            if tag == "param" then
                -- @param NAME [TYPE] DESCRIPTION       where [TYPE] is optional `(type)`
                local name, type_part, desc = rest:match("^(%S+)%s*(%b())%s*(.*)$")
                if not name then name, desc = rest:match("^(%S+)%s*(.*)$"); type_part = nil end
                node.params[#node.params + 1] = {
                    name = name,
                    type = type_part and type_part:sub(2, -2) or nil,
                    description = desc or "",
                }
            elseif tag == "return" then
                local type_part, desc = rest:match("^(%b())%s*(.*)$")
                if not type_part then desc = rest end
                node.returns[#node.returns + 1] = {
                    type = type_part and type_part:sub(2, -2) or nil,
                    description = desc or "",
                }
            elseif tag == "throws" then
                local type_part, desc = rest:match("^(%b())%s*(.*)$")
                if not type_part then desc = rest end
                node.throws[#node.throws + 1] = {
                    type = type_part and type_part:sub(2, -2) or nil,
                    description = desc or "",
                }
            elseif tag == "see" then
                node.see[#node.see + 1] = rest
            elseif tag == "since" then
                node.since = rest
            elseif tag == "deprecated" then
                node.deprecated = rest ~= "" and rest or true
            elseif tag == "module" then
                node.module = rest
            elseif tag == "field" then
                node.fields = node.fields or {}
                local name, type_part, desc = rest:match("^(%S+)%s*(%b())%s*(.*)$")
                if not name then name, desc = rest:match("^(%S+)%s*(.*)$") end
                node.fields[#node.fields + 1] = {
                    name = name,
                    type = type_part and type_part:sub(2, -2) or nil,
                    description = desc or "",
                }
            elseif tag == "example" then
                -- Subsequent lines are the example body.
                mode = "example"
                example_buf, eb = {}, 0
                if rest ~= "" then eb = eb + 1; example_buf[eb] = rest end
            else
                -- Unknown tag: store under a generic table for forward-compat.
                node.tags = node.tags or {}
                node.tags[#node.tags + 1] = { tag = tag, text = rest }
            end
        else
            if mode == "example" then
                eb = eb + 1; example_buf[eb] = t
            else
                db = db + 1; desc_buf[db] = t
            end
        end
    end
    if mode == "example" and example_buf then
        node.examples[#node.examples + 1] = table.concat(example_buf, "\n")
    end
    -- Trim leading/trailing blank lines from description.
    while #desc_buf > 0 and desc_buf[1]:match("^%s*$") do table.remove(desc_buf, 1) end
    while #desc_buf > 0 and desc_buf[#desc_buf]:match("^%s*$") do desc_buf[#desc_buf] = nil end
    node.description = table.concat(desc_buf, "\n")
    return node
end

-- Pull a signature from the first non-comment line below a doc block.
local function parse_signature(line)
    if not line then return nil end
    -- function NAME(args) | local function NAME(args) | NAME = function(args)
    local name, args = line:match("^%s*function%s+([%w%._:]+)%s*(%b())")
    if name then return { kind = "function", name = name, signature = name .. args } end
    name, args = line:match("^%s*local%s+function%s+([%w_]+)%s*(%b())")
    if name then return { kind = "function", name = name, signature = name .. args, scope = "local" } end
    name, args = line:match("^%s*([%w%._:]+)%s*=%s*function%s*(%b())")
    if name then return { kind = "function", name = name, signature = name .. args } end
    name = line:match("^%s*local%s+([%w_]+)%s*=")
    if name then return { kind = "variable", name = name, scope = "local" } end
    name = line:match("^%s*([%w%._]+)%s*=")
    if name then return { kind = "variable", name = name } end
    return nil
end

function M.extract(src)
    local lines = lines_of(src)
    local nodes, nn = {}, 0
    local current_module
    local i = 1

    while i <= #lines do
        local line = lines[i]
        local text = line.text

        -- Long doc block: --[[doc ... ]]
        local block_start = text:match("^%s*%-%-%[%[doc%s*$")
            or text:match("^%s*%-%-%[=%[doc%s*$")
        if block_start then
            -- Find closing ]] or ]=]
            local block_lines, bn = {}, 0
            local j = i + 1
            while j <= #lines do
                local lt = lines[j].text
                if lt:match("^%s*%]%]") or lt:match("^%s*%]=%]") then break end
                bn = bn + 1; block_lines[bn] = lt
                j = j + 1
            end
            local node = parse_block(block_lines)
            -- Look at next non-blank, non-comment line for signature.
            local k = j + 1
            while k <= #lines and lines[k].text:match("^%s*$") do k = k + 1 end
            local sig = lines[k] and parse_signature(lines[k].text) or nil
            if sig then
                for kk, vv in pairs(sig) do node[kk] = vv end
            else
                node.kind = node.kind or "free"
            end
            node.source_line = line.n
            node.module = node.module or current_module
            if node.kind == "module" or (node.module and not current_module) then
                current_module = node.module or current_module
            end
            nn = nn + 1; nodes[nn] = node
            i = k > 0 and k + 1 or j + 1
        elseif text:match("^%s*%-%-%-") then
            -- Run of --- lines.
            local block_lines, bn = {}, 0
            local j = i
            while j <= #lines do
                local body = lines[j].text:match("^%s*%-%-%-%s?(.*)$")
                if body == nil then break end
                bn = bn + 1; block_lines[bn] = body
                j = j + 1
            end
            local node = parse_block(block_lines)
            -- Signature on the next non-blank line.
            local k = j
            while k <= #lines and lines[k].text:match("^%s*$") do k = k + 1 end
            local sig = lines[k] and parse_signature(lines[k].text) or nil
            if sig then
                for kk, vv in pairs(sig) do node[kk] = vv end
            else
                node.kind = node.kind or "free"
            end
            node.source_line = line.n
            if node.module then current_module = node.module end
            node.module = node.module or current_module
            nn = nn + 1; nodes[nn] = node
            i = j
        else
            i = i + 1
        end
    end
    return nodes
end

function M.extract_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local src = f:read("*a"); f:close()
    local nodes = M.extract(src)
    for _, n in ipairs(nodes) do n.file = path end
    return nodes
end

function M.extract_dir(dir, pattern)
    pattern = pattern or "%.lua$"
    local ok_fs, fs = pcall(require, "fs")
    if not ok_fs or not fs or type(fs.walk) ~= "function" then
        error("doc.extract_dir: fs package with walk() required")
    end
    local all, na = {}, 0
    for path in fs.walk(dir) do
        if path:match(pattern) then
            local nodes = M.extract_file(path) or {}
            for _, n in ipairs(nodes) do na = na + 1; all[na] = n end
        end
    end
    return all
end

-- ===== Rendering ========================================================

local function resolve_xrefs(text, style)
    -- [[ref]] -> markdown link `[ref](#ref)` or html anchor.
    if style == "html" then
        return (text:gsub("%[%[([^%]]+)%]%]", function(ref)
            local anchor = ref:gsub("[^%w_]+", "-"):lower()
            return string.format('<a href="#%s">%s</a>', anchor, ref)
        end))
    end
    return (text:gsub("%[%[([^%]]+)%]%]", function(ref)
        local anchor = ref:gsub("[^%w_]+", "-"):lower()
        return string.format("[`%s`](#%s)", ref, anchor)
    end))
end

local function group_by_module(nodes)
    local groups, order = {}, {}
    for _, n in ipairs(nodes) do
        local mod = n.module or "(global)"
        if not groups[mod] then
            groups[mod] = {}
            order[#order + 1] = mod
        end
        groups[mod][#groups[mod] + 1] = n
    end
    table.sort(order)
    return groups, order
end

function M.render_markdown(nodes, opts)
    opts = opts or {}
    local groups, order = group_by_module(nodes)
    local buf, nb = {}, 0
    local function w(s) nb = nb + 1; buf[nb] = s end

    if opts.title then w("# " .. opts.title); w("") end
    -- Module index.
    if #order > 1 or opts.always_index then
        w("## Index"); w("")
        for _, mod in ipairs(order) do
            w(string.format("- [%s](#%s)", mod, mod:gsub("[^%w_]+", "-"):lower()))
        end
        w("")
    end

    for _, mod in ipairs(order) do
        w("## " .. mod); w("")
        for _, n in ipairs(groups[mod]) do
            local heading = n.name or n.kind or "?"
            if n.kind == "function" and n.signature then
                w("### `" .. n.signature .. "`")
            elseif n.name then
                w("### `" .. n.name .. "`")
            else
                w("### " .. heading)
            end
            w("")
            if n.deprecated then
                local s = type(n.deprecated) == "string"
                    and ("**Deprecated**: " .. n.deprecated)
                    or "**Deprecated**"
                w(s); w("")
            end
            if n.since then w("_Since " .. n.since .. "._"); w("") end
            if n.description and n.description ~= "" then
                w(resolve_xrefs(n.description)); w("")
            end
            if #n.params > 0 then
                w("**Parameters**"); w("")
                for _, p in ipairs(n.params) do
                    local t = p.type and (" *(" .. p.type .. ")*") or ""
                    w(string.format("- `%s`%s -- %s", p.name or "?", t, resolve_xrefs(p.description)))
                end
                w("")
            end
            if n.fields and #n.fields > 0 then
                w("**Fields**"); w("")
                for _, p in ipairs(n.fields) do
                    local t = p.type and (" *(" .. p.type .. ")*") or ""
                    w(string.format("- `%s`%s -- %s", p.name or "?", t, resolve_xrefs(p.description)))
                end
                w("")
            end
            if #n.returns > 0 then
                w("**Returns**"); w("")
                for _, r in ipairs(n.returns) do
                    local t = r.type and ("*(" .. r.type .. ")* ") or ""
                    w("- " .. t .. resolve_xrefs(r.description))
                end
                w("")
            end
            if #n.throws > 0 then
                w("**Throws**"); w("")
                for _, e in ipairs(n.throws) do
                    local t = e.type and ("*(" .. e.type .. ")* ") or ""
                    w("- " .. t .. resolve_xrefs(e.description))
                end
                w("")
            end
            if #n.see > 0 then
                w("**See also:** " .. table.concat(n.see, ", "))
                w("")
            end
            for _, ex in ipairs(n.examples) do
                w("```lua"); w(ex); w("```"); w("")
            end
        end
    end
    return table.concat(buf, "\n")
end

local function html_escape(s)
    return (s:gsub("[&<>]", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;" }))
end

function M.render_html(nodes, opts)
    opts = opts or {}
    local groups, order = group_by_module(nodes)
    local buf, nb = {}, 0
    local function w(s) nb = nb + 1; buf[nb] = s end

    w("<!doctype html><html><head><meta charset='utf-8'>")
    w("<title>" .. html_escape(opts.title or "API") .. "</title>")
    w("<style>body{font-family:system-ui,sans-serif;max-width:48rem;margin:2rem auto;padding:0 1rem;}")
    w("code{background:#f5f5f5;padding:.1em .3em;border-radius:3px;}pre{background:#f5f5f5;padding:1em;overflow:auto;}</style>")
    w("</head><body>")
    if opts.title then w("<h1>" .. html_escape(opts.title) .. "</h1>") end
    for _, mod in ipairs(order) do
        local anchor = mod:gsub("[^%w_]+", "-"):lower()
        w(string.format("<h2 id='%s'>%s</h2>", anchor, html_escape(mod)))
        for _, n in ipairs(groups[mod]) do
            local title = n.signature or n.name or "?"
            local sub_anchor = (n.name or title):gsub("[^%w_]+", "-"):lower()
            w(string.format("<h3 id='%s'><code>%s</code></h3>", sub_anchor, html_escape(title)))
            if n.deprecated then
                w("<p><strong>Deprecated</strong></p>")
            end
            if n.since then w("<p><em>Since " .. html_escape(n.since) .. "</em></p>") end
            if n.description and n.description ~= "" then
                w("<p>" .. resolve_xrefs(html_escape(n.description), "html") .. "</p>")
            end
            if #n.params > 0 then
                w("<p><strong>Parameters</strong></p><ul>")
                for _, p in ipairs(n.params) do
                    w(string.format("<li><code>%s</code>%s -- %s</li>",
                        html_escape(p.name or "?"),
                        p.type and (" <em>(" .. html_escape(p.type) .. ")</em>") or "",
                        resolve_xrefs(html_escape(p.description), "html")))
                end
                w("</ul>")
            end
            if #n.returns > 0 then
                w("<p><strong>Returns</strong></p><ul>")
                for _, r in ipairs(n.returns) do
                    w("<li>" .. (r.type and ("<em>(" .. html_escape(r.type) .. ")</em> ") or "")
                        .. resolve_xrefs(html_escape(r.description), "html") .. "</li>")
                end
                w("</ul>")
            end
            for _, ex in ipairs(n.examples) do
                w("<pre><code>" .. html_escape(ex) .. "</code></pre>")
            end
        end
    end
    w("</body></html>")
    return table.concat(buf, "\n")
end

function M.render_json(nodes)
    local ok, json = pcall(require, "json")
    if ok and json then return json.encode(nodes) end
    -- Best-effort manual encode (tooling consumers should have json installed).
    error("doc.render_json: json package required")
end

-- ===== Unified entry points ============================================

-- render(entries, format, opts?) -- format in {"markdown","html","json"}.
function M.render(entries, fmt, opts)
    fmt = fmt or "markdown"
    if fmt == "markdown" then return M.render_markdown(entries, opts) end
    if fmt == "html"     then return M.render_html(entries, opts)     end
    if fmt == "json"     then return M.render_json(entries)           end
    error("doc.render: unknown format " .. tostring(fmt))
end

-- extract(path_or_source) -- accept either a filesystem path or raw source.
-- Detection: if the argument contains no newline AND a file with that name
-- exists, treat as a path; else treat as source.
local _extract_raw = M.extract
function M.extract(input)
    if type(input) == "string" and not input:find("\n", 1, true) then
        local f = io.open(input, "rb")
        if f then
            local src = f:read("*a"); f:close()
            local nodes = _extract_raw(src)
            for _, n in ipairs(nodes) do n.file = input end
            return nodes
        end
    end
    return _extract_raw(input)
end

-- Expand a list of paths/globs to .lua files; fall back to literal entries
-- when fs/glob aren't available.
local function expand_targets(paths)
    local out, no = {}, 0
    local seen = {}
    local ok_fs, fs = pcall(require, "fs")
    local ok_glob, glob = pcall(require, "glob")
    for _, p in ipairs(paths or {}) do
        if p:find("[%*%?%[]") and ok_glob and glob and type(glob.expand) == "function" then
            for _, q in ipairs(glob.expand(p) or {}) do
                if not seen[q] then seen[q] = true; no = no + 1; out[no] = q end
            end
        else
            local is_dir
            if ok_fs and fs and type(fs.stat) == "function" then
                local st = fs.stat(p); is_dir = st and st.kind == "directory"
            end
            if is_dir and ok_fs and fs and type(fs.walk) == "function" then
                for q in fs.walk(p) do
                    if q:sub(-4) == ".lua" and not seen[q] then
                        seen[q] = true; no = no + 1; out[no] = q
                    end
                end
            else
                if not seen[p] then seen[p] = true; no = no + 1; out[no] = p end
            end
        end
    end
    return out
end

-- build(paths, opts?) -- aggregate doc entries from many files and (optionally)
-- write the rendered output to disk. opts = { output_dir, format, index, search,
-- project_name }.
function M.build(paths, opts)
    opts = opts or {}
    local format = opts.format or "markdown"
    local files = expand_targets(paths)

    local all, na = {}, 0
    for _, path in ipairs(files) do
        local nodes = M.extract_file(path) or {}
        for _, n in ipairs(nodes) do na = na + 1; all[na] = n end
    end

    local rendered = M.render(all, format, {
        title          = opts.project_name,
        always_index   = opts.index ~= false,
    })

    if opts.output_dir then
        local ext = ({ markdown = ".md", html = ".html", json = ".json" })[format] or ".txt"
        local name = (opts.project_name or "api"):gsub("[^%w_]+", "_"):lower()
        local path = opts.output_dir
        -- Be lenient about trailing separator.
        if path:sub(-1) ~= "/" and path:sub(-1) ~= "\\" then path = path .. "/" end
        local out_path = path .. name .. ext
        local f, err = io.open(out_path, "wb")
        if not f then error("doc.build: cannot write " .. out_path .. ": " .. tostring(err)) end
        f:write(rendered); f:close()
        return out_path, all
    end
    return rendered, all
end

return M
