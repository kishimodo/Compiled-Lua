-- tree -- walk + size accounting on top of fs.
--
-- Public surface:
--   tree.walk(root, opts?)   -> stateless iterator yielding entry tables
--                                { path, name, depth, is_dir, is_symlink, size }
--   tree.du(root, opts?)     -> total bytes  (or, with by_dir=true, a tree
--                                of { name, path, size, children = { ... } })
--   tree.find(root, pred, opts?) -> { matching paths }
--
-- opts (walk / du / find share most of them):
--   recursive       (default true)
--   follow_symlinks (default false) -- protects against reparse loops
--   filter          fn(entry) -> bool  -- if false, skip (and skip descent if dir)
--   max_depth       integer or nil (no limit)

local fs   = require "fs"
local path = require "path"

local M = {}

-- Build an entry table for `full` (assumes it exists). Returns nil if
-- we can't stat (e.g. permission denied) -- caller should treat as skip.
local function entry_for(full, depth)
    local st = fs.stat(full)
    if not st then return nil end
    local _, name = path.split(full)
    return {
        path       = full,
        name       = name,
        depth      = depth,
        is_dir     = st.is_dir,
        is_symlink = st.is_symlink,
        size       = st.size,
        stat       = st,
    }
end

function M.walk(root, opts)
    opts = opts or {}
    local recursive = opts.recursive ~= false
    local follow    = opts.follow_symlinks == true
    local filter    = opts.filter
    local max_depth = opts.max_depth

    -- DFS stack of { path, depth, names, idx }. We list names lazily so we
    -- don't load the whole tree into memory.
    local stack = {}

    -- Push the root unless it was already pushed.
    local function push_dir(p, depth)
        local names, err = fs.list(p)
        if not names then return end
        table.sort(names)
        stack[#stack + 1] = { path = p, depth = depth, names = names, idx = 0 }
    end

    -- Yield the root itself first.
    local root_entry = entry_for(root, 0)
    if not root_entry then
        return function() return nil end
    end
    local yielded_root = false
    if root_entry.is_dir and recursive and (not max_depth or 0 < max_depth) then
        push_dir(root, 0)
    end

    return function()
        if not yielded_root then
            yielded_root = true
            if filter == nil or filter(root_entry) then
                return root_entry
            end
        end
        while #stack > 0 do
            local frame = stack[#stack]
            frame.idx = frame.idx + 1
            if frame.idx > #frame.names then
                stack[#stack] = nil
            else
                local name = frame.names[frame.idx]
                local full = path.join(frame.path, name)
                local depth = frame.depth + 1
                local entry = entry_for(full, depth)
                if entry then
                    -- Skip via filter?
                    local keep = (filter == nil) or filter(entry)
                    if keep then
                        if entry.is_dir and recursive
                           and (follow or not entry.is_symlink)
                           and (not max_depth or depth < max_depth) then
                            push_dir(full, depth)
                        end
                        return entry
                    end
                end
                -- otherwise fall through and continue the loop
            end
        end
        return nil
    end
end

function M.du(root, opts)
    opts = opts or {}
    local by_dir = opts.by_dir == true

    if not by_dir then
        local total = 0
        for entry in M.walk(root, {
                recursive       = true,
                follow_symlinks = opts.follow_symlinks,
                filter          = opts.filter,
                max_depth       = opts.max_depth,
            }) do
            if not entry.is_dir then total = total + entry.size end
        end
        return total
    end

    -- Build a tree mirror.
    local nodes = {}   -- path -> node
    local function ensure(p, name, is_dir)
        local n = nodes[p]
        if n then return n end
        n = { name = name, path = p, size = 0, children = is_dir and {} or nil, is_dir = is_dir }
        nodes[p] = n
        return n
    end

    local _, root_name = path.split(root)
    if root_name == "" then root_name = root end
    local root_node = ensure(root, root_name, true)

    for entry in M.walk(root, {
            recursive       = true,
            follow_symlinks = opts.follow_symlinks,
            filter          = opts.filter,
            max_depth       = opts.max_depth,
        }) do
        if entry.path == root then
            -- already created
        else
            local node = ensure(entry.path, entry.name, entry.is_dir)
            -- Attach to parent.
            local parent_path = path.dirname(entry.path)
            local parent_node = nodes[parent_path]
            if parent_node and parent_node.children then
                parent_node.children[#parent_node.children + 1] = node
            end
            if not entry.is_dir then
                node.size = entry.size
                -- Roll size up the chain.
                local pp = parent_path
                while pp and nodes[pp] do
                    nodes[pp].size = nodes[pp].size + entry.size
                    if pp == root then break end
                    local up = path.dirname(pp)
                    if up == pp then break end
                    pp = up
                end
            end
        end
    end
    return root_node
end

function M.find(root, predicate, opts)
    opts = opts or {}
    if type(predicate) ~= "function" then
        error("tree.find: predicate must be a function", 2)
    end
    local out, n = {}, 0
    for entry in M.walk(root, {
            recursive       = opts.recursive,
            follow_symlinks = opts.follow_symlinks,
            max_depth       = opts.max_depth,
        }) do
        if predicate(entry) then
            n = n + 1; out[n] = entry.path
        end
    end
    return out
end

-- ===== tree(root, opts?) -- structured tree result =====================
--
-- Returns a nested table:
--   { name, path, is_dir, size, children = { ... } }
-- where children is a list of subentries (files + subdirectories,
-- alphabetically sorted). Pure-data; safe to JSON-encode.

function M.tree(root, opts)
    opts = opts or {}
    -- Reuse du(by_dir=true) which already builds the structure.
    local merged = {
        recursive       = true,
        follow_symlinks = opts.follow_symlinks,
        filter          = opts.filter,
        max_depth       = opts.max_depth,
        by_dir          = true,
    }
    return M.du(root, merged)
end

-- ===== Extended du with per-extension breakdown =========================
--
-- The old M.du(root, opts) handles the simple total + by_dir cases. The
-- spec also asks for opts.by_extension, which returns
--   { total = <bytes>, by_extension = { [".lua"] = n, [".png"] = n, ... } }

local _du_original = M.du
function M.du(root, opts)
    opts = opts or {}
    if not opts.by_extension then return _du_original(root, opts) end

    local total = 0
    local by_ext = {}
    for entry in M.walk(root, {
            recursive       = true,
            follow_symlinks = opts.follow_symlinks,
            filter          = opts.filter,
            max_depth       = opts.max_depth,
        }) do
        if not entry.is_dir then
            total = total + entry.size
            local ext = path.extname(entry.name)
            if ext == "" then ext = "<none>" end
            ext = ext:lower()
            by_ext[ext] = (by_ext[ext] or 0) + entry.size
        end
    end
    return { total = total, by_extension = by_ext }
end

-- count(root, opts?) -- {files, dirs, symlinks, total}.
function M.count(root, opts)
    opts = opts or {}
    local files, dirs, links = 0, 0, 0
    for entry in M.walk(root, {
            recursive       = opts.recursive,
            follow_symlinks = opts.follow_symlinks,
            filter          = opts.filter,
            max_depth       = opts.max_depth,
        }) do
        if entry.is_symlink then links = links + 1
        elseif entry.is_dir then dirs = dirs + 1
        else files = files + 1 end
    end
    return {
        files    = files,
        dirs     = dirs,
        symlinks = links,
        total    = files + dirs + links,
    }
end

-- iter is just an alias to walk so code that wants a "tree iterator" can
-- spell the dependency clearly.
M.iter = M.walk

return M
