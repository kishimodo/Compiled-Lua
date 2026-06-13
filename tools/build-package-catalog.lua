-- tools/build-package-catalog.lua
--
-- Walks clua/src/runtime/packages/, extracts the public surface from each
-- package's init.lua + package.lua manifest, and writes a browsable
-- Markdown catalog to docs/packages-catalog.md.
--
-- No external deps (pure Lua I/O); runs under either system Lua 5.4 or
-- the project's build/bin/clua-interp.exe (which doesn't preload the runtime
-- packages on its search path, so we don't try to require any of them).
--
-- Usage:
--   lua tools/build-package-catalog.lua
--   ./build/bin/clua-interp.exe tools/build-package-catalog.lua

-- ===== Paths ============================================================

local PROJECT_ROOT = (function()
    -- Prefer cwd if it already looks like the project root.
    local function has_packages(root)
        local f = io.open(root .. "/clua/clua/src/runtime/packages/json/package.lua", "rb")
        if f then f:close(); return true end
        return false
    end
    if has_packages(".") then return "." end
    -- Otherwise locate clua/src/runtime/packages relative to this script.
    -- arg[0] is the script path if invoked via `lua tools/...`.
    local self = arg and arg[0] or "tools/build-package-catalog.lua"
    -- Strip the trailing filename, then any trailing /tools or \tools.
    local d = self:match("^(.*)[\\/][^\\/]+$") or "."
    d = (d:gsub("[\\/]?tools$", ""))
    if d == "" then d = "." end
    if has_packages(d) then return d end
    -- Last resort: walk up from cwd looking for clua/src/runtime/packages.
    local p = "."
    for _ = 1, 6 do
        if has_packages(p) then return p end
        p = p .. "/.."
    end
    return "."
end)()

local function path_join(...)
    local parts = { ... }
    return table.concat(parts, "/")
end

local PACKAGES_DIR = path_join(PROJECT_ROOT, "clua", "src", "runtime", "packages")
local OUTPUT_FILE  = path_join(PROJECT_ROOT, "docs", "packages-catalog.md")

-- ===== Category map =====================================================
-- Hard-coded based on the 8 batch commits (and the foundational packages
-- shipped earlier: windows, dotnet, imgui, async).

local CATEGORY = {
    -- Data formats
    json="Data formats", msgpack="Data formats", cbor="Data formats",
    toml="Data formats", yaml="Data formats", xml="Data formats",
    ini="Data formats", csv="Data formats", tsv="Data formats",
    ndjson="Data formats", properties="Data formats",

    -- Encoding
    base16="Encoding", base32="Encoding", base64="Encoding",
    base85="Encoding", url="Encoding", querystring="Encoding",
    mime="Encoding", quoted_printable="Encoding", punycode="Encoding",
    cobs="Encoding", varint="Encoding",

    -- Cryptography
    hash="Cryptography", hmac="Cryptography", pbkdf2="Cryptography",
    aes="Cryptography", jwt="Cryptography", x509="Cryptography",
    random="Cryptography", uuid="Cryptography", secret="Cryptography",

    -- Security primitives
    dpapi="Security", wintrust="Security", keychain="Security",
    sandbox="Security", vuln_scan="Security",

    -- Compression
    zlib="Compression", lz4="Compression", zstd="Compression",
    xpress="Compression", zip="Compression", tar="Compression",
    cab="Compression",

    -- Networking
    socket="Networking", tls_client="Networking", http="Networking",
    websocket="Networking", dns="Networking", ntp="Networking",
    smtp="Networking", redis="Networking",

    -- Filesystem
    path="Filesystem", fs="Filesystem", glob="Filesystem",
    watcher="Filesystem", mmap="Filesystem", tempdir="Filesystem",
    tree="Filesystem",

    -- Process / system
    process="Process", pipe="Process", signal="Process", env="Process",
    tty="Process", daemon="Process", scheduler="Process", wmi="Process",

    -- Concurrency
    thread="Concurrency", channel="Concurrency", pool="Concurrency",
    mutex="Concurrency", semaphore="Concurrency", atomic="Concurrency",
    queue="Concurrency", event="Concurrency",
    async="Concurrency",

    -- Time
    time="Time", timezone="Time", cron="Time", rate_limit="Time",
    retry="Time", timer="Time",

    -- Databases / KV
    sqlite="Databases", lmdb="Databases", kv_file="Databases",
    cache_lru="Databases", cache_ttl="Databases",

    -- DSL
    expr="DSL", cron_expr="DSL", formula="DSL", glob_match="DSL",
    semver="DSL", path_match="DSL",

    -- Text / regex
    pcre="Text/regex", lpeg="Text/regex", peg="Text/regex",
    unicode="Text/regex", wcwidth="Text/regex", string_extra="Text/regex",
    slug="Text/regex", diff="Text/regex", re2="Text/regex",

    -- Memory / debug
    pe="Memory/debug", mem="Memory/debug", proc="Memory/debug",
    cpuid="Memory/debug", dis="Memory/debug", asm="Memory/debug",
    coredump="Memory/debug",

    -- Hardware / system info
    cpu="Hardware", gpu="Hardware", memory_info="Hardware",
    disk="Hardware", network_info="Hardware", usb="Hardware",
    serial="Hardware",

    -- Numerical
    bignum="Numerical", rational="Numerical", complex="Numerical",
    vector="Numerical", matrix="Numerical", stats="Numerical",
    random_dist="Numerical", fft="Numerical",

    -- Math / scientific
    units="Math", currency="Math", gis="Math", bezier="Math",
    noise="Math",

    -- CLI / TUI
    cli="CLI/TUI", repl="CLI/TUI", tui="CLI/TUI", prompt="CLI/TUI",
    progress="CLI/TUI", table_fmt="CLI/TUI", color="CLI/TUI",
    term="CLI/TUI", keyboard="CLI/TUI",

    -- GUI / graphics
    webview="GUI", tray="GUI", notify_toast="GUI", clipboard="GUI",
    screenshot="GUI", display="GUI", wndproc="GUI",
    imgui="GUI",

    -- Media
    image="Media", qrcode="Media", wic="Media", audio="Media",
    wasapi="Media", mediafound="Media", ffmpeg="Media",

    -- Documents
    rtf="Documents", docx="Documents", xlsx="Documents",
    epub="Documents", pdf_read="Documents", pdf_write="Documents",

    -- Logging / observability
    log="Logging", metrics="Logging", tracing="Logging",
    profile="Logging", bench="Logging", apperror="Logging",

    -- Testing
    test="Testing", assert_ex="Testing", mock="Testing",
    property="Testing", snapshot="Testing", fuzz="Testing",

    -- Dev tools
    inspect="Dev tools", repl_debug="Dev tools", hot_reload="Dev tools",
    lint="Dev tools", format="Dev tools", doc="Dev tools",

    -- Niche validators
    useragent="Niche", geoip="Niche", creditcard="Niche", bloom="Niche",
    hll="Niche", regex_set="Niche", email_validate="Niche",
    phone="Niche", iban="Niche",

    -- Foundation (Windows / .NET FFI)
    windows="Foundation", dotnet="Foundation",
}

-- ===== Directory walk via popen =========================================

-- Plain-Lua dir listing: we can't `lfs` without an external lib, and the
-- project's `fs` package isn't on clua-interp.exe's search path. Use `dir /b`
-- on Windows; fall back to `ls` for cross-platform safety.

local function list_dir(dir)
    local entries = {}
    -- Try `dir /b` (Windows). On non-Windows shells this errors silently
    -- via popen, leaving entries empty -- then we try `ls`.
    local p = io.popen('dir /b "' .. dir:gsub("/", "\\") .. '" 2>nul')
    if p then
        for line in p:lines() do
            entries[#entries + 1] = line
        end
        p:close()
    end
    if #entries == 0 then
        p = io.popen('ls -1 "' .. dir .. '" 2>/dev/null')
        if p then
            for line in p:lines() do
                entries[#entries + 1] = line
            end
            p:close()
        end
    end
    return entries
end

local function file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

local function read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local s = f:read("*a")
    f:close()
    return s
end

-- ===== Manifest parser (sandboxed) ======================================

local function load_manifest(path)
    local src, err = read_file(path)
    if not src then return nil, err end
    -- Strip a possible BOM.
    if src:sub(1, 3) == "\239\187\191" then src = src:sub(4) end
    local chunk, lerr = load(src, "@" .. path, "t", {})
    if not chunk then return nil, lerr end
    local ok, val = pcall(chunk)
    if not ok then return nil, val end
    if type(val) ~= "table" then return nil, "manifest is not a table" end
    return val
end

-- ===== init.lua surface extractor ======================================

-- Strategy:
--   1. The leading `-- comment` block (lines starting with `--` before any
--      code) is the module header. We pull the first non-comment paragraph
--      after the `Public surface:` marker (most packages document their
--      surface as part of this header) -- that gives us hand-written
--      signatures + one-line descriptions exactly as the package author
--      wrote them.
--   2. Additionally we scan the source for `function M.foo(...)`,
--      `M.foo = function(...)`, and `M.foo = <something>` so we catch
--      anything the header missed.
--   3. We pair each scanned entry with the immediately preceding short
--      comment (1-3 lines) so the catalog has a description per item.

-- Read the leading comment header (stops at first non-comment, non-blank line).
local function read_header_block(src)
    local lines = {}
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end
    local header, i = {}, 1
    while i <= #lines do
        local l = lines[i]
        if l:match("^%s*$") then
            header[#header + 1] = ""
        elseif l:match("^%s*%-%-") then
            header[#header + 1] = l
        else
            break
        end
        i = i + 1
    end
    return header
end

-- Take the lines that follow "Public surface:" (or "Public:") in the
-- header, until a blank line / another header tag.
local function extract_surface_section(header)
    local items = {}
    local in_surface, in_continuation = false, false
    for _, raw in ipairs(header) do
        local body = raw:match("^%s*%-%-%s?(.*)$") or ""
        -- Marker?
        if body:lower():match("^public surface:")
            or body:lower():match("^public api:")
            or body:lower():match("^api:")
            or body:lower():match("^public:")
        then
            in_surface = true
        elseif in_surface then
            if body == "" then
                in_surface = false
                in_continuation = false
            elseif body:match("^[A-Z][%w/-]+%s*:?%s*$")
                or body:match("^[A-Z][%w%s/-]+%s*%(%d+%)%s*:?%s*$")
            then
                -- A subsection heading like "Client:" or "Cron methods:".
                -- Keep absorbing the next bullets.
                in_continuation = false
            else
                -- A surface bullet. Strip the leading whitespace conserving
                -- the signature.
                local trimmed = body:gsub("^%s+", "")
                if trimmed ~= "" then
                    items[#items + 1] = trimmed
                    in_continuation = true
                end
            end
        end
    end
    return items
end

-- Fallback: parse the first sentence/paragraph of the header as a description
-- if package.lua has no description.
local function header_first_paragraph(header)
    local buf = {}
    for _, raw in ipairs(header) do
        local body = raw:match("^%s*%-%-%s?(.*)$")
        if body == nil then break end
        if body:match("^%s*$") then
            if #buf > 0 then break end
        else
            -- Skip the leading "name -- " or "name:" if present on first line.
            if #buf == 0 then
                body = body:gsub("^[%w_%.]+%s*%-%-%s*", "")
                body = body:gsub("^[%w_%.]+%s*:%s*", "")
            end
            buf[#buf + 1] = body
        end
    end
    return table.concat(buf, " ")
end

-- Scan source for M.foo assignments / function definitions. Pair each
-- with the immediately preceding short comment.
local function extract_scanned_surface(src)
    local lines = {}
    for line in (src .. "\n"):gmatch("([^\n]*)\n") do
        lines[#lines + 1] = line
    end

    local found = {}        -- list of { name, signature, comment, line }
    local seen  = {}

    local function add(name, sig, comment, lineno)
        if seen[name] then return end
        seen[name] = true
        found[#found + 1] = {
            name = name, signature = sig, comment = comment, line = lineno,
        }
    end

    -- Pull 1-3 short comment lines immediately above lineno (no blank gap).
    local function preceding_comment(lineno)
        local out = {}
        local j = lineno - 1
        local count = 0
        while j >= 1 and count < 3 do
            local prev = lines[j]
            if prev:match("^%s*$") then break end
            local body = prev:match("^%s*%-%-%s?(.*)$")
            if not body then break end
            -- Skip section dividers like "===== Foo =====".
            if body:match("^%s*=+") or body:match("^%s*%-+%s*$") then break end
            table.insert(out, 1, body)
            count = count + 1
            j = j - 1
        end
        return table.concat(out, " "):gsub("^%s+", ""):gsub("%s+$", "")
    end

    for idx, line in ipairs(lines) do
        -- function M.foo(args)
        local name, args = line:match("^%s*function%s+M%.([%w_]+)%s*(%b())")
        if name then
            add(name, name .. args, preceding_comment(idx), idx)
        else
            -- M.foo = function(args)
            local n2, a2 = line:match("^%s*M%.([%w_]+)%s*=%s*function%s*(%b())")
            if n2 then
                add(n2, n2 .. a2, preceding_comment(idx), idx)
            else
                -- M.foo = <anything else>  (variable / table / sentinel)
                local n3 = line:match("^%s*M%.([%w_]+)%s*=")
                if n3 then
                    -- Avoid duplicating entries that look local (capital
                    -- prefix uppercase constants we still want to surface).
                    add(n3, n3, preceding_comment(idx), idx)
                end
            end
        end
    end
    return found
end

-- LOC count for the package (sum across all .lua files in the dir).
local function count_lua_loc(dir)
    local total = 0
    for _, entry in ipairs(list_dir(dir)) do
        if entry:match("%.lua$") then
            local content = read_file(path_join(dir, entry))
            if content then
                -- Count newlines + 1 if last char isn't \n.
                local n = 0
                for _ in content:gmatch("\n") do n = n + 1 end
                if #content > 0 and content:sub(-1) ~= "\n" then n = n + 1 end
                total = total + n
            end
        end
    end
    return total
end

-- ===== Build per-package record ========================================

local function build_record(pkg_dir, pkg_name)
    local manifest_path = path_join(pkg_dir, "package.lua")
    local init_path     = path_join(pkg_dir, "init.lua")

    local rec = {
        name = pkg_name,
        category = CATEGORY[pkg_name] or "Other",
        version = nil,
        description = nil,
        requires = {},
        requires_native = {},
        surface_lines = {},
        scanned = {},
        modules = {},
        loc = count_lua_loc(pkg_dir),
    }

    local manifest, m_err = load_manifest(manifest_path)
    if manifest then
        rec.version          = manifest.version
        rec.description      = manifest.description
        rec.requires         = manifest.requires or {}
        rec.requires_native  = manifest.requires_native or {}
        rec.modules          = manifest.modules or {}
    else
        rec.manifest_error = m_err
    end

    if file_exists(init_path) then
        local src = read_file(init_path) or ""
        local header = read_header_block(src)
        rec.surface_lines = extract_surface_section(header)
        if not rec.description or rec.description == "" then
            rec.description = header_first_paragraph(header)
        end
        rec.scanned = extract_scanned_surface(src)
    end

    return rec
end

-- ===== Render Markdown =================================================

local function escape_md(s)
    if not s then return "" end
    -- Only escape the few characters that would break our generated output.
    -- We deliberately preserve `*`, `_`, etc. inside descriptions because the
    -- package headers already use Markdown-friendly punctuation.
    return s
end

local function anchor_for(s)
    -- GitHub-style anchor: lowercase, spaces -> dashes, drop other punct.
    local a = s:lower():gsub("[^%w%s%-]", ""):gsub("%s+", "-")
    return a
end

local function render(records)
    -- Group by category.
    local by_cat = {}
    for _, r in ipairs(records) do
        by_cat[r.category] = by_cat[r.category] or {}
        table.insert(by_cat[r.category], r)
    end

    local cats = {}
    for c in pairs(by_cat) do cats[#cats + 1] = c end
    table.sort(cats)

    -- Sort packages alphabetically within each category.
    for _, c in ipairs(cats) do
        table.sort(by_cat[c], function(a, b) return a.name < b.name end)
    end

    -- Totals.
    local total_pkgs = #records
    local total_modules = 0
    local total_loc = 0
    for _, r in ipairs(records) do
        total_loc = total_loc + r.loc
        local n = 0
        for _ in pairs(r.modules) do n = n + 1 end
        if n == 0 then n = 1 end -- assume single module if manifest absent
        total_modules = total_modules + n
    end

    local buf, nb = {}, 0
    local function w(s) nb = nb + 1; buf[nb] = s end

    w("# CLua Package Catalog")
    w("")
    w(string.format(
        "%d modules in %d packages, ~%s lines of Lua.",
        total_modules, total_pkgs,
        (function()
            -- thousands separator
            local s = tostring(total_loc)
            local r = s:reverse():gsub("(%d%d%d)", "%1,")
            return r:reverse():gsub("^,", "")
        end)()
    ))
    w("")
    w("Auto-generated by `tools/build-package-catalog.lua`. Do not edit by hand.")
    w("")
    w("## Categories")
    w("")
    for _, c in ipairs(cats) do
        w(string.format("- [%s](#%s) (%d)", c, anchor_for(c), #by_cat[c]))
    end
    w("")

    for _, c in ipairs(cats) do
        w("## " .. c)
        w("")
        for _, r in ipairs(by_cat[c]) do
            w(string.format("### `%s`", r.name))
            w("")
            if r.description and r.description ~= "" then
                -- Use the first sentence as the primary description; keep
                -- the remainder as a continuation if it isn't huge.
                local desc = r.description
                -- Collapse internal whitespace.
                desc = desc:gsub("%s+", " ")
                w("*" .. desc .. "*")
                w("")
            end
            -- Depends / native line.
            local function fmt_list(t)
                if not t then return "(none)" end
                local items = {}
                for _, v in ipairs(t) do
                    if type(v) == "string" then
                        items[#items + 1] = "`" .. v .. "`"
                    elseif type(v) == "table" and v[1] then
                        items[#items + 1] = "`" .. tostring(v[1]) .. "`"
                    end
                end
                if #items == 0 then
                    -- Look for {dll=..., ...} style (requires_native).
                    for k, v in pairs(t) do
                        if type(v) == "string" and k ~= "mode_default"
                           and k ~= "env_var" then
                            items[#items + 1] = "`" .. v .. "`"
                            break
                        end
                    end
                end
                if #items == 0 then return "(none)" end
                return table.concat(items, ", ")
            end
            w(string.format("Version: %s | Depends: %s | Native: %s",
                r.version or "?",
                fmt_list(r.requires),
                fmt_list(r.requires_native)))
            w("")

            -- Sub-modules other than the main one, if any.
            local extra_mods = {}
            for mname in pairs(r.modules or {}) do
                if mname ~= r.name then extra_mods[#extra_mods + 1] = mname end
            end
            if #extra_mods > 0 then
                table.sort(extra_mods)
                w("Sub-modules: " .. table.concat(
                    (function()
                        local t = {}
                        for _, m in ipairs(extra_mods) do
                            t[#t + 1] = "`" .. m .. "`"
                        end
                        return t
                    end)(), ", "))
                w("")
            end

            -- Public surface, preferring author-written header lines.
            if #r.surface_lines > 0 then
                w("**Public surface (from header):**")
                w("")
                w("```")
                for _, ln in ipairs(r.surface_lines) do
                    w(ln)
                end
                w("```")
                w("")
            end

            -- Scanned signatures supplement the header.
            if #r.scanned > 0 then
                -- Sort scanned entries alphabetically for stable output.
                local sorted = {}
                for _, s in ipairs(r.scanned) do sorted[#sorted + 1] = s end
                table.sort(sorted, function(a, b) return a.name < b.name end)
                w("**Exports (scanned):**")
                w("")
                for _, s in ipairs(sorted) do
                    local sig = s.signature or s.name
                    local comment = s.comment or ""
                    -- Normalize whitespace in comment, drop if it just
                    -- repeats the signature.
                    comment = comment:gsub("%s+", " ")
                    if comment ~= "" and not comment:match("^%-%-") then
                        w(string.format("- `%s` -- %s", sig, comment))
                    else
                        w(string.format("- `%s`", sig))
                    end
                end
                w("")
            end
        end
    end

    return table.concat(buf, "\n"), total_modules, total_pkgs, total_loc
end

-- ===== Main =============================================================

local function main()
    local packages = list_dir(PACKAGES_DIR)
    if #packages == 0 then
        io.stderr:write("error: no packages found at " .. PACKAGES_DIR .. "\n")
        os.exit(1)
    end

    local records = {}
    local missing_category = {}
    for _, name in ipairs(packages) do
        -- Skip files; we want directories only.
        local pkg_dir = path_join(PACKAGES_DIR, name)
        if file_exists(path_join(pkg_dir, "package.lua"))
           or file_exists(path_join(pkg_dir, "init.lua")) then
            local rec = build_record(pkg_dir, name)
            records[#records + 1] = rec
            if not CATEGORY[name] then
                missing_category[#missing_category + 1] = name
            end
        end
    end

    if #missing_category > 0 then
        io.stderr:write("warning: " .. #missing_category
            .. " packages without category mapping; bucketed as 'Other':\n")
        for _, n in ipairs(missing_category) do
            io.stderr:write("  - " .. n .. "\n")
        end
    end

    local md, n_mods, n_pkgs, loc = render(records)

    local out, err = io.open(OUTPUT_FILE, "wb")
    if not out then
        io.stderr:write("error: cannot write " .. OUTPUT_FILE .. ": "
            .. tostring(err) .. "\n")
        os.exit(1)
    end
    out:write(md)
    out:close()

    io.write(string.format(
        "wrote %s\n  %d packages, %d modules, %d LOC, %d bytes\n",
        OUTPUT_FILE, n_pkgs, n_mods, loc, #md))
end

main()
