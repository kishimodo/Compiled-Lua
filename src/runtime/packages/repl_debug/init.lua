-- repl_debug -- Step debugger over Lua, driven by debug.sethook.
--
-- Public surface:
--   repl_debug.start(opts?)            install hooks (idempotent)
--   repl_debug.stop()                  remove hooks
--   repl_debug.breakpoint(file, line, opts?) -> id
--   repl_debug.clear(id)               remove a breakpoint
--   repl_debug.breakpoints()           -> list of {id, file, line, condition, hits}
--   repl_debug.set_watch(expr)         -> id  evaluates expr in caller scope at each pause
--   repl_debug.clear_watch(id)
--   repl_debug.break_now()             trip on the next executed line
--   repl_debug.run()                   continue after a pause (resume)
--   repl_debug.is_paused()             true while inside the interactive prompt
--
-- Prompt commands:
--   cont|c              continue
--   step|s              step into
--   next|n              step over
--   finish|fin          step out of the current function
--   where|bt            stack trace
--   locals|l            print locals at current frame
--   ups|u               print upvalues
--   globals|g           print global names (filtered)
--   up                  move up the call stack
--   down                move down the call stack
--   frame N             jump to frame N
--   print|p EXPR        evaluate EXPR in the current frame
--   break FILE:LINE     add breakpoint
--   clear ID|FILE:LINE  remove breakpoint
--   list                show breakpoints
--   watch EXPR          add a watch
--   unwatch ID
--   src [N]             show N lines around current location
--   quit|q              detach the debugger entirely
--
-- The prompt itself reads lines via the `repl` package when available,
-- falling back to io.read().

local M = {}

local _state = {
    installed   = false,
    bps         = {},           -- [id] = { file=, line=, condition=, hits=0 }
    bps_by_loc  = {},           -- [file..":"..line] = id
    next_id     = 1,
    watches     = {},           -- [id] = expr
    next_watch  = 1,
    paused      = false,
    mode        = nil,          -- "step"|"next"|"finish"|nil
    step_depth  = 0,            -- depth marker for next/finish
    cur_frame   = 0,            -- 0 = inner; up/down adjusts
    base_level  = 0,            -- hook level baseline of paused frame
    break_now   = false,
    on_pause    = nil,
    on_resume   = nil,
    inspect     = nil,
}

-- ===== Helpers =========================================================

local function get_inspect()
    if _state.inspect then return _state.inspect end
    local ok, mod = pcall(require, "inspect")
    if ok then _state.inspect = mod end
    return _state.inspect
end

local function read_line(prompt)
    -- Prefer repl package for proper line editing; fall back to io.read.
    local ok, repl = pcall(require, "repl")
    if ok and repl and type(repl.read_line) == "function" then
        return repl.read_line(prompt)
    end
    io.write(prompt); io.flush()
    return io.read("*l")
end

local function short_src(info)
    local s = info.source or info.short_src or "?"
    if s:sub(1, 1) == "@" then s = s:sub(2) end
    return s
end

local function pretty(v)
    local mod = get_inspect()
    if mod then return mod(v) end
    return tostring(v)
end

-- Walk the stack from a known depth, returning a list of frames.
local function collect_stack(start_level)
    local frames, n = {}, 0
    local lvl = start_level
    while true do
        local info = debug.getinfo(lvl, "Slnf")
        if not info then break end
        n = n + 1
        frames[n] = { level = lvl, info = info }
        lvl = lvl + 1
    end
    return frames
end

local function get_locals(level)
    local out = {}
    local i = 1
    while true do
        local name, value = debug.getlocal(level, i)
        if not name then break end
        if name:sub(1, 1) ~= "(" then  -- skip "(*temporary)" etc.
            out[#out + 1] = { name = name, value = value, index = i }
        end
        i = i + 1
    end
    return out
end

local function get_upvalues(level)
    local info = debug.getinfo(level, "f")
    if not info or not info.func then return {} end
    local out = {}
    local i = 1
    while true do
        local name, value = debug.getupvalue(info.func, i)
        if not name then break end
        out[#out + 1] = { name = name, value = value, index = i, func = info.func }
        i = i + 1
    end
    return out
end

-- Build an environment that resolves names against locals -> upvalues -> _G,
-- and routes writes back into the proper slot via debug.setlocal/setupvalue.
local function frame_env(level)
    local locals  = get_locals(level)
    local ups     = get_upvalues(level)
    local lookup_local = {}
    for _, e in ipairs(locals) do lookup_local[e.name] = e end
    local lookup_up = {}
    for _, e in ipairs(ups) do lookup_up[e.name] = e end
    return setmetatable({}, {
        __index = function(_, k)
            local e = lookup_local[k]
            if e then return e.value end
            e = lookup_up[k]
            if e then return e.value end
            return rawget(_G, k)
        end,
        __newindex = function(_, k, v)
            local e = lookup_local[k]
            if e then
                debug.setlocal(level, e.index, v)
                e.value = v
                return
            end
            e = lookup_up[k]
            if e then
                debug.setupvalue(e.func, e.index, v)
                e.value = v
                return
            end
            rawset(_G, k, v)
        end,
    })
end

local function eval_expr(level, src)
    -- Try expression form first ("return EXPR"), then statement form.
    local env = frame_env(level)
    local chunk, err = load("return " .. src, "=(expr)", "t", env)
    if not chunk then
        chunk, err = load(src, "=(stmt)", "t", env)
    end
    if not chunk then return nil, err end
    return pcall(chunk)
end

-- ===== Breakpoint matching ==============================================

local function loc_match(file, line)
    -- Match by basename or by suffix to be lenient about absolute vs relative.
    local id = _state.bps_by_loc[file .. ":" .. line]
    if id then return id end
    local base = file:match("[^/\\]+$")
    if base then
        id = _state.bps_by_loc[base .. ":" .. line]
        if id then return id end
    end
    return nil
end

-- ===== Prompt loop ======================================================

local function show_locals(level)
    local locs = get_locals(level)
    if #locs == 0 then print("  (no locals)") return end
    for _, e in ipairs(locs) do
        print(string.format("  %s = %s", e.name, pretty(e.value)))
    end
end

local function show_ups(level)
    local ups = get_upvalues(level)
    if #ups == 0 then print("  (no upvalues)") return end
    for _, e in ipairs(ups) do
        print(string.format("  %s = %s", e.name, pretty(e.value)))
    end
end

local function show_globals(filter)
    for k, v in pairs(_G) do
        if not filter or tostring(k):find(filter, 1, true) then
            print(string.format("  %s = %s", tostring(k), pretty(v)))
        end
    end
end

local function show_stack(frames, current)
    for i, f in ipairs(frames) do
        local info = f.info
        local mark = (i == current) and "*" or " "
        local name = info.name or info.what or "?"
        print(string.format(" %s [%d] %s:%d in %s", mark, i, short_src(info), info.currentline or -1, name))
    end
end

local function show_source(info, span)
    span = span or 5
    local src = short_src(info)
    local line = info.currentline or info.linedefined or 0
    local f = io.open(src, "r")
    if not f then print("  (source unavailable: " .. src .. ")") return end
    local lines, ln = {}, 0
    for L in f:lines() do ln = ln + 1; lines[ln] = L end
    f:close()
    local lo = math.max(1, line - span)
    local hi = math.min(ln, line + span)
    for i = lo, hi do
        local marker = (i == line) and ">>" or "  "
        print(string.format("%s %4d| %s", marker, i, lines[i] or ""))
    end
end

local function fire_watches(level)
    if not next(_state.watches) then return end
    print("[watches]")
    for id, expr in pairs(_state.watches) do
        local ok, val = eval_expr(level, expr)
        if ok then
            print(string.format("  #%d %s = %s", id, expr, pretty(val)))
        else
            print(string.format("  #%d %s -- error: %s", id, expr, tostring(val)))
        end
    end
end

-- The hook's level for the user code; computed when we enter the prompt.
-- frame_level(stack_offset) returns the absolute debug-level for that frame.
local function frame_level(offset)
    return _state.base_level + offset
end

local function pause(why, info)
    _state.paused = true
    _state.cur_frame = 1
    print(string.format("\n[%s] %s:%d", why, short_src(info), info.currentline or -1))
    if _state.on_pause then pcall(_state.on_pause, why, info) end

    -- Capture the stack starting from the user frame.
    local frames = collect_stack(_state.base_level)
    fire_watches(frame_level(0))

    while true do
        local line = read_line(string.format("dbg [%d]> ", _state.cur_frame))
        if not line then  -- EOF: behave like quit
            line = "quit"
        end
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line == "" then line = "step" end

        local cmd, rest = line:match("^(%S+)%s*(.*)$")
        if cmd == "cont" or cmd == "c" then
            _state.mode = nil
            break
        elseif cmd == "step" or cmd == "s" then
            _state.mode = "step"
            break
        elseif cmd == "next" or cmd == "n" then
            _state.mode = "next"
            _state.step_depth = #frames
            break
        elseif cmd == "finish" or cmd == "fin" then
            _state.mode = "finish"
            _state.step_depth = #frames - 1
            break
        elseif cmd == "where" or cmd == "bt" then
            show_stack(frames, _state.cur_frame)
        elseif cmd == "locals" or cmd == "l" then
            show_locals(frame_level(_state.cur_frame - 1))
        elseif cmd == "ups" or cmd == "u" then
            show_ups(frame_level(_state.cur_frame - 1))
        elseif cmd == "globals" or cmd == "g" then
            show_globals(rest ~= "" and rest or nil)
        elseif cmd == "up" then
            if _state.cur_frame < #frames then _state.cur_frame = _state.cur_frame + 1 end
            local f = frames[_state.cur_frame]
            print(string.format(" => frame %d %s:%d", _state.cur_frame, short_src(f.info), f.info.currentline or -1))
        elseif cmd == "down" then
            if _state.cur_frame > 1 then _state.cur_frame = _state.cur_frame - 1 end
            local f = frames[_state.cur_frame]
            print(string.format(" => frame %d %s:%d", _state.cur_frame, short_src(f.info), f.info.currentline or -1))
        elseif cmd == "frame" then
            local n = tonumber(rest)
            if n and frames[n] then _state.cur_frame = n end
        elseif cmd == "print" or cmd == "p" then
            local ok, val = eval_expr(frame_level(_state.cur_frame - 1), rest)
            if ok then print(pretty(val)) else print("error: " .. tostring(val)) end
        elseif cmd == "break" then
            local file, lineno = rest:match("^(.+):(%d+)$")
            if file and lineno then
                local id = M.breakpoint(file, tonumber(lineno))
                print(string.format(" breakpoint #%d at %s:%s", id, file, lineno))
            else
                print(" usage: break FILE:LINE")
            end
        elseif cmd == "clear" then
            local n = tonumber(rest)
            if n then
                M.clear(n)
            else
                local file, lineno = rest:match("^(.+):(%d+)$")
                if file and lineno then
                    local id = loc_match(file, tonumber(lineno))
                    if id then M.clear(id) end
                end
            end
        elseif cmd == "list" then
            for _, b in ipairs(M.breakpoints()) do
                print(string.format(" #%d %s:%d hits=%d cond=%s", b.id, b.file, b.line, b.hits, b.condition or "-"))
            end
        elseif cmd == "watch" then
            local id = M.set_watch(rest)
            print(string.format(" watch #%d added", id))
        elseif cmd == "unwatch" then
            local n = tonumber(rest)
            if n then M.clear_watch(n) end
        elseif cmd == "src" then
            local span = tonumber(rest) or 5
            show_source(frames[_state.cur_frame].info, span)
        elseif cmd == "quit" or cmd == "q" then
            _state.mode = nil
            M.stop()
            break
        else
            -- Unknown commands fall back to "print rest" if it parses, otherwise help.
            local ok, val = eval_expr(frame_level(_state.cur_frame - 1), line)
            if ok then print(pretty(val))
            else print("unknown command: " .. cmd .. "  (try: cont, step, next, finish, where, locals, p EXPR, quit)") end
        end
    end
    _state.paused = false
    if _state.on_resume then pcall(_state.on_resume) end
end

-- ===== Hook =============================================================

local function hook(event, line)
    if event == "line" then
        -- The hook runs at level 2 (this fn + the user line); record the user level.
        local info = debug.getinfo(2, "Sl")
        if not info then return end
        _state.base_level = 2

        -- Forced break (e.g. break_now or external trigger).
        if _state.break_now then
            _state.break_now = false
            return pause("break", info)
        end

        -- Breakpoint match.
        local src = short_src(info)
        if info.currentline then
            local id = loc_match(src, info.currentline)
            if id then
                local b = _state.bps[id]
                b.hits = b.hits + 1
                local hit = true
                if b.condition then
                    local ok, val = eval_expr(_state.base_level, b.condition)
                    hit = ok and val and true or false
                end
                if hit then return pause("breakpoint #" .. id, info) end
            end
        end

        -- Stepping modes.
        if _state.mode == "step" then
            return pause("step", info)
        elseif _state.mode == "next" then
            local depth = #collect_stack(2)
            if depth <= _state.step_depth then
                return pause("next", info)
            end
        elseif _state.mode == "finish" then
            local depth = #collect_stack(2)
            if depth <= _state.step_depth then
                return pause("finish", info)
            end
        end
    end
end

-- ===== Public API =======================================================

function M.start(opts)
    opts = opts or {}
    _state.on_pause  = opts.on_pause
    _state.on_resume = opts.on_resume
    if _state.installed then return end
    debug.sethook(hook, "l")
    _state.installed = true
end

function M.stop()
    if not _state.installed then return end
    debug.sethook()
    _state.installed = false
    _state.mode = nil
end

function M.breakpoint(file, line, opts)
    opts = opts or {}
    local id = _state.next_id
    _state.next_id = id + 1
    _state.bps[id] = {
        id = id, file = file, line = line,
        condition = opts.condition,
        hits = 0,
    }
    _state.bps_by_loc[file .. ":" .. line] = id
    -- Also index by basename so resolving works regardless of cwd.
    local base = file:match("[^/\\]+$")
    if base and base ~= file then
        _state.bps_by_loc[base .. ":" .. line] = id
    end
    return id
end

function M.clear(id)
    local b = _state.bps[id]
    if not b then return end
    _state.bps_by_loc[b.file .. ":" .. b.line] = nil
    local base = b.file:match("[^/\\]+$")
    if base then _state.bps_by_loc[base .. ":" .. b.line] = nil end
    _state.bps[id] = nil
end

function M.breakpoints()
    local out = {}
    for _, b in pairs(_state.bps) do out[#out + 1] = b end
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

function M.set_watch(expr)
    local id = _state.next_watch
    _state.next_watch = id + 1
    _state.watches[id] = expr
    return id
end

function M.clear_watch(id)
    _state.watches[id] = nil
end

function M.break_now()
    _state.break_now = true
end

function M.run()
    _state.mode = nil
end

function M.is_paused()
    return _state.paused
end

-- ===== Spec-style facade ================================================

M.attach = M.start
M.detach = M.stop

-- Programmatic stepping (alternative to running the interactive prompt).
function M.step()      _state.mode = "step";   return true end
function M.next()      _state.mode = "next";   _state.step_depth = math.huge; return true end
function M.finish()    _state.mode = "finish"; _state.step_depth = 1;         return true end
function M.continue()  _state.mode = nil;      return true end

-- Trigger a pause point from user code.
function M.pause()
    if not _state.installed then M.start() end
    _state.break_now = true
end

-- Helpers that surface debug state from outside the prompt. `frame` counts
-- user frames starting at 1 = direct caller of the M.* function.
local function level_for_frame(frame)
    frame = frame or 1
    -- debug.getlocal level 1 = the immediate frame (M.locals), 2 = its caller.
    -- frame=1 should target the caller -> level 2 + (frame-1).
    return frame + 1
end

function M.locals(frame)
    local lvl = level_for_frame(frame) + 1  -- +1 to skip M.locals itself
    local out = {}
    for _, e in ipairs(get_locals(lvl)) do out[e.name] = e.value end
    return out
end

function M.upvalues(frame)
    local lvl = level_for_frame(frame) + 1
    local out = {}
    for _, e in ipairs(get_upvalues(lvl)) do out[e.name] = e.value end
    return out
end

function M.stack()
    -- Skip ourselves; the caller wants their own stack.
    return collect_stack(2)
end

function M.eval_in_frame(frame_idx, expr)
    local lvl = level_for_frame(frame_idx) + 1
    return eval_expr(lvl, expr)
end

-- repl() -- start an interactive prompt against the current frame without
-- waiting for the hook to trip. Useful as a `breakpoint()`-style helper.
function M.repl()
    if not _state.installed then M.start() end
    local info = debug.getinfo(2, "Sl") or { source = "?", currentline = 0 }
    _state.base_level = 2
    pause("user", info)
end

return M
