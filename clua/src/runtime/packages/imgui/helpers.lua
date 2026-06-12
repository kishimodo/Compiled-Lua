-- imgui_helpers: opt-in convenience helpers on top of the imgui module.
--
-- These cover idiomatic patterns that come up in every non-trivial menu
-- UI and that the cimgui surface alone makes a little fiddly: matched
-- Push/Pop scopes, layout math, ImU32 packing, mouse-button names,
-- two-state invisible buttons.
--
-- All helpers are pure Lua and have no global side effects; require it
-- only where you use it: `local UI = require("imgui_helpers")`.

local imgui = require("imgui")
local C     = ffi.C

local M = {}

-- ---- 1. ImVec2 / ImVec4 packing -----------------------------------------

-- v2_pack(x, y): packed ImVec2-as-uint64 (Win64 ABI hack). Alias of
-- imgui.ImVec2 -- exposed under a name that reads better at callsites
-- that are doing math:  layout.cursor = UI.v2_pack(x + 6, y).
M.v2_pack = imgui.ImVec2

-- v2(x, y) -> struct cdata you can do .x / .y / arithmetic on. Alias of
-- imgui.vec2.
M.v2 = imgui.vec2

-- v4(r, g, b, a) -> ImVec4 cdata. Alias of imgui.ImVec4.
M.v4 = imgui.ImVec4

-- u32(r, g, b, a) -> packed ImU32 in IM_COL32 layout (0xAABBGGRR). Each
-- component is 0..255 (integer) or 0..1.0 (float, auto-scaled).
function M.u32(r, g, b, a)
    if a == nil then a = 255 end
    if r <= 1 and g <= 1 and b <= 1 and a <= 1 then
        r = math.floor(r * 255 + 0.5)
        g = math.floor(g * 255 + 0.5)
        b = math.floor(b * 255 + 0.5)
        a = math.floor(a * 255 + 0.5)
    end
    return (a << 24) | (b << 16) | (g << 8) | r
end

-- u32_alpha(rgba, mul): rescale alpha component of an existing IM_COL32
-- by mul (0..1). Cheap; runs in u32 throughout.
function M.u32_alpha(rgba, mul)
    if mul == nil or mul == 1.0 then return rgba end
    local a = ((rgba >> 24) & 0xFF) * mul
    return (rgba & 0x00FFFFFF) | (math.floor(a + 0.5) << 24)
end

-- ---- 2. Scope helpers ---------------------------------------------------

-- with_colors({{slot, color}, ...}, body): push all listed colors, run
-- body, pop them. `color` may be ImU32 or ImVec4 (auto-routed to the
-- matching PushStyleColor overload). Pops always run, even if body
-- errors.
function M.with_colors(pairs_list, body)
    local n = #pairs_list
    for i = 1, n do
        local p = pairs_list[i]
        local slot, color = p[1], p[2]
        if type(color) == "number" then
            C.igPushStyleColor_U32(slot, color)
        else
            C.igPushStyleColor_Vec4(slot, color)
        end
    end
    local ok, err = pcall(body)
    C.igPopStyleColor(n)
    if not ok then error(err, 2) end
end

-- with_style_vars({{var, value_or_v2}, ...}, body): same shape for
-- StyleVars. Numbers route to PushStyleVar_Float; ImVec2-packed uint64
-- routes to PushStyleVar_Vec2.
function M.with_style_vars(pairs_list, body)
    local n = #pairs_list
    for i = 1, n do
        local p = pairs_list[i]
        local var, value = p[1], p[2]
        if type(value) == "cdata" then
            -- expect uint64 packed ImVec2 (from imgui.ImVec2 / UI.v2_pack)
            C.igPushStyleVar_Vec2(var, value)
        else
            C.igPushStyleVar_Float(var, value)
        end
    end
    local ok, err = pcall(body)
    C.igPopStyleVar(n)
    if not ok then error(err, 2) end
end

-- with_id(id, body): PushID/PopID around body. `id` may be integer
-- (PushID_Int), string (PushID_Str), or pointer cdata (PushID_Ptr).
function M.with_id(id, body)
    local t = type(id)
    if t == "number" then
        C.igPushID_Int(id)
    elseif t == "string" then
        C.igPushID_Str(id)
    else
        C.igPushID_Ptr(id)
    end
    local ok, err = pcall(body)
    C.igPopID()
    if not ok then error(err, 2) end
end

-- ---- 3. Layout helpers --------------------------------------------------

-- text_centered(s, avail_w): emit s centered in `avail_w` (pixels). If
-- avail_w is nil, uses GetContentRegionAvail().x.
function M.text_centered(s, avail_w)
    s = tostring(s)
    if avail_w == nil then
        local ra = imgui.GetContentRegionAvail()
        avail_w = ra.x
    end
    local ts = imgui.CalcTextSize(s, nil, false, -1.0)
    local pad = (avail_w - ts.x) * 0.5
    if pad > 0 then
        C.igSetCursorPosX(C.igGetCursorPosX() + pad)
    end
    C.igTextUnformatted(s, nil)
end

-- ---- 4. Mouse-button names ---------------------------------------------

-- mouse_button_name[idx] for hot-key / keybind UI. Names match cimgui's
-- ImGuiMouseButton_ enum order: 0=Left, 1=Right, 2=Middle, 3..4=X1/X2.
M.mouse_button_name = {
    [0] = "Left",
    [1] = "Right",
    [2] = "Middle",
    [3] = "X1",
    [4] = "X2",
}

-- ---- 5. Invisible button + state ---------------------------------------

-- invisible_button_state(id, size_packed): emit an InvisibleButton and
-- return (clicked, hovered, held). `size_packed` is an ImVec2 uint64
-- (UI.v2_pack / imgui.ImVec2). Saves callers the three follow-up cimgui
-- calls.
function M.invisible_button_state(id, size_packed)
    local clicked = C.igInvisibleButton(id, size_packed, 0)
    local hovered = C.igIsItemHovered(0)
    local held    = C.igIsItemActive()
    return clicked, hovered, held
end

return M
