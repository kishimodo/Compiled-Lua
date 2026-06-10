-- hot_reload -- Module hot-swap on file change.
--
-- Public surface:
--   hot_reload.watch(target, opts?)    -> id    target is module name or glob path
--   hot_reload.unwatch(id_or_pattern)
--   hot_reload.reload(name)            -> ok, new_or_err
--   hot_reload.tick()                  -> reloaded_names   poll once (call from a loop)
--   hot_reload.start(opts?)            -> id    spawn a background coroutine via scheduler
--   hot_reload.stop()                  cancel the background poller
--   hot_reload.list()                  -> list of {id, target, file, mtime}
--   hot_reload.on(event, fn)           events: "reload","error","before","after"
--
-- opts (watch):
--   interval_ms   500     polling interval if watcher unavailable
--   on_reload     fn(name, new, old)        per-target callback
--   keep_state    fn(old) -> state         pull state out of the old module
--   apply_state   fn(new, state)           inject state into the freshly required new module
--
-- Behaviour notes:
--   * Hot reload patches package.loaded so future requires see the new module.
--   * If the old module is a *table* and the new module is too, the old table is
--     mutated in place so existing references continue to work. New keys are
--     added, removed keys are deleted, replaced keys overwritten.
--   * Functions inside the table get rewired transparently.
--   * Circular requires are broken by clearing package.loaded[name] *before*
--     the re-require.

local M = {}

local _state = {
    targets   = {},     -- [id] = { kind="module"|"file", name=, path=, mtime=, opts= }
    by_name   = {},     -- [module_name] = id  (fast lookup for reload(name))
    by_file   = {},     -- [path] = id
    next_id   = 1,
    listeners = { reload = {}, error = {}, before = {}, after = {} },
    running   = nil,    -- scheduler task handle when started
}

-- ===== Helpers =========================================================

local function emit(event, ...)
    local list = _state.listeners[event]
    if not list then return end
    for _, fn in ipairs(list) do pcall(fn, ...) end
end

local function get_mtime(path)
    -- Prefer fs.stat; fall back to opening the file (mtime unknown -> a stub).
    local ok, fs = pcall(require, "fs")
    if ok and fs and type(fs.stat) == "function" then
        local st = fs.stat(path)
        if st then return st.mtime end
    end
    local f = io.open(path, "rb")
    if not f then return nil end
    f:close()
    -- No portable mtime: use file size as a change signal. Better than nothing.
    local fs_ok, fs2 = pcall(require, "fs")
    if fs_ok and fs2 and type(fs2.size) == "function" then
        return fs2.size(path)
    end
    return 0
end

local function module_to_path(name)
    -- Mirror Lua's require search: replace dots with separators, walk package.path
    -- substituting `?` with the module name, then with name/init.
    local rel = name:gsub("%.", "/")
    for path_template in package.path:gmatch("[^;]+") do
        local candidate = path_template:gsub("%?", rel)
        local f = io.open(candidate, "rb")
        if f then f:close(); return candidate end
        candidate = path_template:gsub("%?", rel .. "/init")
        f = io.open(candidate, "rb")
        if f then f:close(); return candidate end
    end
    -- Last resort: cwd-relative fallbacks.
    for _, fallback in ipairs({ rel .. ".lua", rel .. "/init.lua" }) do
        local f = io.open(fallback, "rb")
        if f then f:close(); return fallback end
    end
    return nil
end

-- ===== In-place table patching =========================================

-- Recursively rewire the old table to match the new one. This preserves
-- identity (foreign references stay valid) while still picking up changes.
local function patch_table(old, new, seen)
    seen = seen or {}
    if seen[old] then return old end
    seen[old] = true

    -- Add or update keys present in new.
    for k, v in pairs(new) do
        local ov = rawget(old, k)
        if type(ov) == "table" and type(v) == "table" and ov ~= v then
            patch_table(ov, v, seen)
        else
            rawset(old, k, v)
        end
    end
    -- Remove keys absent from new.
    for k in pairs(old) do
        if rawget(new, k) == nil then rawset(old, k, nil) end
    end
    -- Preserve / patch the metatable too.
    local nmt = getmetatable(new)
    if nmt ~= nil then
        local omt = getmetatable(old)
        if type(omt) == "table" and type(nmt) == "table" then
            patch_table(omt, nmt, seen)
        else
            setmetatable(old, nmt)
        end
    end
    return old
end

-- ===== Public API =======================================================

function M.on(event, fn)
    if not _state.listeners[event] then
        error("hot_reload: unknown event " .. tostring(event))
    end
    table.insert(_state.listeners[event], fn)
end

function M.watch(target, opts)
    opts = opts or {}
    local id = _state.next_id
    _state.next_id = id + 1
    local entry = {
        id   = id,
        opts = opts,
        kind = target:find("[/\\]") and "file" or "module",
    }
    if entry.kind == "module" then
        entry.name = target
        entry.path = module_to_path(target)
        if not entry.path then
            error("hot_reload: cannot locate module " .. target)
        end
        _state.by_name[target] = id
    else
        entry.path = target
        _state.by_file[target] = id
    end
    entry.mtime = get_mtime(entry.path)
    _state.targets[id] = entry
    return id
end

function M.unwatch(id_or_pattern)
    if type(id_or_pattern) == "number" then
        local e = _state.targets[id_or_pattern]
        if e then
            if e.name then _state.by_name[e.name] = nil end
            if e.path then _state.by_file[e.path] = nil end
            _state.targets[id_or_pattern] = nil
        end
        return
    end
    -- String pattern: match against module name and file path.
    for id, e in pairs(_state.targets) do
        if (e.name and e.name:find(id_or_pattern)) or (e.path and e.path:find(id_or_pattern)) then
            M.unwatch(id)
        end
    end
end

local function do_reload(entry)
    local name = entry.name
    if not name then
        -- File-only watch: just notify listeners; nothing to require.
        emit("reload", entry.path)
        if entry.opts.on_reload then entry.opts.on_reload(entry.path) end
        return true, nil
    end
    emit("before", name)
    local old = package.loaded[name]
    local kept
    if entry.opts.keep_state and old then
        local ok, st = pcall(entry.opts.keep_state, old)
        if ok then kept = st end
    end

    -- Clear package.loaded so circular require chains rebuild correctly.
    package.loaded[name] = nil

    local ok, new = pcall(require, name)
    if not ok then
        -- Roll back: restore old module so the world keeps working.
        package.loaded[name] = old
        emit("error", name, new)
        return false, new
    end

    -- Patch old table in place when possible.
    if type(old) == "table" and type(new) == "table" and old ~= new then
        patch_table(old, new)
        package.loaded[name] = old
        new = old
    end

    if entry.opts.apply_state and kept ~= nil then
        pcall(entry.opts.apply_state, new, kept)
    end
    if entry.opts.on_reload then
        pcall(entry.opts.on_reload, name, new, old)
    end
    emit("reload", name, new, old)
    emit("after", name)
    return true, new
end

function M.reload(name)
    local id = _state.by_name[name]
    local entry = id and _state.targets[id]
    if not entry then
        -- Allow ad-hoc reload of any loaded module.
        local path = module_to_path(name)
        entry = { name = name, path = path, opts = {} }
    end
    if entry.path then entry.mtime = get_mtime(entry.path) end
    return do_reload(entry)
end

function M.tick()
    local reloaded = {}
    for _, entry in pairs(_state.targets) do
        if entry.path then
            local mt = get_mtime(entry.path)
            if mt and mt ~= entry.mtime then
                entry.mtime = mt
                local ok = do_reload(entry)
                if ok then reloaded[#reloaded + 1] = entry.name or entry.path end
            end
        end
    end
    return reloaded
end

function M.list()
    local out = {}
    for _, e in pairs(_state.targets) do
        out[#out + 1] = {
            id    = e.id,
            target= e.name or e.path,
            file  = e.path,
            mtime = e.mtime,
        }
    end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

-- Background polling loop. Hands off to either the watcher package (push)
-- or the scheduler package (timer). Falls back to a coroutine the caller
-- must drive via tick().
function M.start(opts)
    opts = opts or {}
    if _state.running then return _state.running end
    local interval = opts.interval_ms or 500

    -- Try fs watcher first (event-driven, no polling cost).
    local ok_w, watcher = pcall(require, "watcher")
    if ok_w and watcher and type(watcher.watch) == "function" then
        local paths = {}
        for _, e in pairs(_state.targets) do
            if e.path then paths[#paths + 1] = e.path end
        end
        if #paths > 0 then
            _state.running = watcher.watch(paths, function(path)
                -- Locate the matching entry and reload it.
                local id = _state.by_file[path] or _state.by_name[path]
                if id then do_reload(_state.targets[id]) end
            end)
            return _state.running
        end
    end

    -- Otherwise schedule a timer.
    local ok_s, scheduler = pcall(require, "scheduler")
    if ok_s and scheduler and type(scheduler.every) == "function" then
        _state.running = scheduler.every(interval, function() M.tick() end)
        return _state.running
    end

    -- No async runtime: caller must call tick() themselves.
    return nil
end

function M.stop()
    if not _state.running then return end
    local ok, watcher = pcall(require, "watcher")
    if ok and watcher and type(watcher.cancel) == "function" then
        pcall(watcher.cancel, _state.running)
    end
    local ok2, scheduler = pcall(require, "scheduler")
    if ok2 and scheduler and type(scheduler.cancel) == "function" then
        pcall(scheduler.cancel, _state.running)
    end
    _state.running = nil
end

-- ===== Spec-style facade ================================================
--
-- The richer watch()/start()/stop() API above is the primitive layer.
-- enable()/disable()/register()/with_state() are the friendlier surface
-- described in the package spec.

-- Cross-call state shared by with_state for preserving values across reloads.
_state.preserved = _state.preserved or {}

local function debounce(fn, ms)
    if not ms or ms <= 0 then return fn end
    local last = 0
    return function(...)
        local now = os.time() * 1000
        if now - last < ms then return end
        last = now
        return fn(...)
    end
end

-- Auto-discover candidate package paths from package.path templates.
local function auto_watch_paths()
    local paths, np = {}, 0
    local seen = {}
    for tmpl in package.path:gmatch("[^;]+") do
        local dir = tmpl:match("^(.-)[/\\]?%?") or tmpl
        if dir ~= "" and not seen[dir] then
            seen[dir] = true
            np = np + 1; paths[np] = dir
        end
    end
    return paths
end

-- enable(opts) -- top-level activation. Watches everything in package.loaded
-- whose source file we can locate, unless opts.filter is supplied.
function M.enable(opts)
    opts = opts or {}
    if opts.on_reload then table.insert(_state.listeners.reload, opts.on_reload) end
    if opts.on_error  then table.insert(_state.listeners.error,  opts.on_error)  end

    local filter = opts.filter
    for name in pairs(package.loaded) do
        if not filter or filter(name) then
            local p = module_to_path(name)
            if p then
                local id = _state.by_name[name]
                if not id then
                    pcall(M.watch, name, {})
                end
            end
        end
    end

    -- Honor watch_paths by scanning each directory for .lua files via fs.
    local watch_paths = opts.watch_paths
    if watch_paths == nil then watch_paths = auto_watch_paths() end
    local ok_fs, fs = pcall(require, "fs")
    if ok_fs and fs and type(fs.walk) == "function" then
        for _, dir in ipairs(watch_paths) do
            local ok_walk, iter = pcall(fs.walk, dir)
            if ok_walk and iter then
                for path in iter do
                    if path:sub(-4) == ".lua" and not _state.by_file[path] then
                        pcall(M.watch, path, {})
                    end
                end
            end
        end
    end

    -- Start background polling.
    local effective = opts.debounce_ms and debounce(M.tick, opts.debounce_ms)
    if effective then
        local ok_s, scheduler = pcall(require, "scheduler")
        if ok_s and scheduler and type(scheduler.every) == "function" then
            _state.running = scheduler.every(opts.debounce_ms or 200, effective)
        end
    else
        M.start({ interval_ms = opts.debounce_ms or 200 })
    end
end

function M.disable()
    M.stop()
    for id in pairs(_state.targets) do M.unwatch(id) end
end

-- register(module_name, on_reload?) -- add a single module to the watch set.
function M.register(module_name, on_reload)
    local id = _state.by_name[module_name]
    if id then
        if on_reload then _state.targets[id].opts.on_reload = on_reload end
        return id
    end
    return M.watch(module_name, { on_reload = on_reload })
end

-- with_state(key) -- returns get/set fns for a value that survives reloads.
function M.with_state(key)
    return function() return _state.preserved[key] end,
           function(value) _state.preserved[key] = value end
end

return M
