#!/usr/bin/env python3
"""
Generate the LuaVM ImGui Lua bindings from cimgui's JSON metadata.

Input  : third_party/cimgui-gen-output/{definitions,structs_and_enums}.json
Output : clua/src/runtime/preload/imgui_bindings.lua

The generated file contains:
  1. A single ffi.cdef string covering primitive typedefs, all enum typedefs
     (as plain int), the explicit ImVec2 / ImVec4 layouts, opaque forward
     decls for every other ImGui struct, struct bodies for the
     field-accessible ones (ImGuiIO, ImGuiStyle, ImFontAtlas, ImFontConfig),
     and function decls for every ig* function we can mechanically wrap.
  2. Per-enum tables keyed by their short suffix (imgui.Col.Text = 0, ...).
  3. A wrapper table mapping `funcname` -> Lua closure that forwards to
     the cimgui export, packing ImVec2 args into uint64 and unpacking
     ImVec2/ImVec4 returns into Lua tables/cdata. Overloads are exposed
     under suffixed names (`PushStyleColor_U32`, `PushStyleColor_Vec4`).

Win64 ABI hack:
  ImVec2 (8 bytes, two floats) rides in a single integer register exactly
  like a uint64. We declare cimgui's ImVec2-by-value params as uint64_t
  in our cdef and pack `(x, y)` -> uint64 in the wrapper. Same trick for
  ImVec2 returns. ImVec4 (16 bytes) doesn't fit; the ABI passes 16-byte
  structs by hidden pointer, so we declare cimgui's ImVec4-by-value
  params as `const ImVec4*` and box on the stack. Returns get a hidden
  leading ImVec4* arg.
"""

import json
import os
import sys
import textwrap
from collections import OrderedDict

HERE        = os.path.dirname(os.path.abspath(__file__))
PROJ_ROOT   = os.path.dirname(HERE)
META_DIR    = os.path.join(PROJ_ROOT, "third_party", "cimgui-gen-output")
OUTPUT_LUA  = os.path.join(PROJ_ROOT, "src", "runtime", "preload",
                           "imgui_bindings.lua")

# Cimgui rewrites C++ types by appending `_c`. Translate back so our cdef
# matches the canonical ImGui names we declare for ImVec2 / ImVec4.
_CT_REWRITES = {
    "ImVec2_c":  "ImVec2",
    "ImVec4_c":  "ImVec4",
    "ImColor_c": "ImColor",
    "ImRect_c":  "ImRect",
    "ImVec2ih_c":"ImVec2ih",
    "ImVec2i_c": "ImVec2i",
}

# These structs we expose with full field bodies so Lua can do field
# access via FFI cdata (`io.DeltaTime`, `style.Colors[i].x`, etc).
# Everything else is forward-declared opaque.
#
# We don't open structs that contain ImVector<T> fields by value -- those
# instantiated template structs aren't emitted with bodies in our cdef,
# so emit_struct_cdef would skip them and our cdef parser would choke.
# That rules out ImDrawData, ImDrawList, ImGuiStyle (Colors[55] is fine
# but the ImVector-of-config fields aren't), etc. Use accessor functions
# for those (imgui.GetStyle returns ImGuiStyle*; field access still works
# through the pointer because cimgui exposes plain pointers everywhere).
_OPEN_STRUCTS = {
    "ImVec2", "ImVec4", "ImColor",
    "ImGuiIO", "ImGuiStyle", "ImGuiKeyData",
    "ImFontAtlas", "ImFontConfig", "ImFontGlyph",
    "ImDrawCmd", "ImDrawVert",
    "ImGuiSizeCallbackData", "ImGuiTextRange",
    "ImGuiTableColumnSortSpecs",
    "ImGuiPlatformImeData", "ImGuiPlatformMonitor",
}

# Template-instantiated types whose layout we know. Used to substitute
# field bodies in open structs so we don't have to emit cdef for every
# ImVector<T> permutation. Padded char arrays preserve layout.
_TEMPLATE_SIZES = {
    "ImVector":        16,  # struct { int Size; int Capacity; T* Data; }
    "ImSpan":          16,  # struct { T* Data; T* DataEnd; }
    "ImChunkStream":   16,  # wraps ImVector
    "ImStableVector":  40,  # rough guess; fields after this are inaccessible anyway
}

# Reserved Lua keywords or globals we can't use as bare table keys.
_LUA_RESERVED = {
    "end", "do", "if", "then", "else", "elseif", "for", "while", "repeat",
    "until", "function", "local", "nil", "true", "false", "and", "or",
    "not", "return", "break", "goto", "in",
}


def load_meta():
    defs = json.load(open(os.path.join(META_DIR, "definitions.json"), "r"))
    se   = json.load(open(os.path.join(META_DIR, "structs_and_enums.json"), "r"))
    # populate global enum-member -> value table for array-bound eval
    for members in se.get("enums", {}).values():
        for m in members:
            _ENUM_VALUES[m["name"]] = m["calc_value"]
    return defs, se


def rewrite_type(t):
    """Normalize cimgui type spelling to our cdef spelling."""
    # cimgui suffixes C++ POD types with `_c` (ImVec2_c, ImTextureRef_c
    # etc) so its generated C signatures don't clash with the imgui.h
    # C++ types it #includes. Strip them.
    import re as _re
    t = _re.sub(r"\b(Im[A-Za-z0-9]+)_c\b", r"\1", t)
    # Our cdef lexer accepts `_Bool` (the C99 keyword), not `bool`.
    t = _re.sub(r"\bbool\b", "_Bool", t)
    return t


def is_imvec2_byvalue(t):
    """Return True if t is ImVec2 (or its _c variant) passed/returned by value."""
    t = t.strip()
    base = t.replace("const ", "").replace("&", "").strip()
    return base in ("ImVec2", "ImVec2_c")


def is_imvec4_byvalue(t):
    t = t.strip()
    base = t.replace("const ", "").replace("&", "").strip()
    return base in ("ImVec4", "ImVec4_c")


def is_function_pointer_type(t):
    return "(*" in t or "(* " in t


def is_skippable_arg_type(t):
    """Types we can't represent in our cdef -- function pointers, va_list,
    templated junk. Marks the whole function as skippable."""
    if is_function_pointer_type(t):
        return True
    if "va_list" in t:
        return True
    # Variadic ellipsis (...) parameters -- our cdef parser doesn't
    # support vararg functions.
    if "..." in t:
        return True
    # Templated like ImSpan<int>, ImVector<x>
    if "<" in t:
        return True
    # ImVec4& (lvalue ref) is rare and tricky -- skip those overloads
    if "&" in t and not t.strip().endswith("*"):
        return True
    return False


def emit_function_cdef(fn):
    """Render a single cdef for one cimgui function overload, returning
    a string or None if the function is unsupported."""
    cname    = fn["ov_cimguiname"]
    ret      = fn.get("ret", "void").strip()
    args     = fn.get("argsT", [])
    inject   = []   # extra leading params (e.g. hidden ImVec4* for ret)
    new_args = []

    # Skip exotic returns we can't represent
    if is_function_pointer_type(ret):
        return None

    # Return-type rewriting
    if is_imvec2_byvalue(ret):
        cdef_ret = "uint64_t"
    elif is_imvec4_byvalue(ret):
        inject.append("ImVec4* _ret")
        cdef_ret = "void"
    else:
        cdef_ret = rewrite_type(ret)

    for a in args:
        t = a.get("type", "")
        n = a.get("name", "")
        # Variadic ellipsis args use type="..." or name="...".
        if t == "..." or n == "...":
            return None
        if not n or n in _LUA_RESERVED:
            # Cimgui sometimes emits `in` / `end` / `function` -- prefix.
            n = "_" + n if n else "_arg"
        if is_skippable_arg_type(t):
            return None
        if is_imvec2_byvalue(t):
            new_args.append(f"uint64_t {n}")
        elif is_imvec4_byvalue(t):
            new_args.append(f"const ImVec4 *{n}")
        else:
            # Convert C array syntax `type[N]` in the type field to
            # `type name[N]` in the declarator (cimgui emits the array
            # bound on the type side; standard C wants it on the name).
            # Bare `type[]` (no size) decays to `type*`.
            tt = rewrite_type(t)
            re_mod = __import__("re")
            arr_match = re_mod.match(r"^(.+?)\[(\d+)\]\s*$", tt)
            if arr_match:
                base, dim = arr_match.group(1).strip(), arr_match.group(2)
                new_args.append(f"{base} {n}[{dim}]")
            elif re_mod.search(r"\[\s*\]\s*$", tt):
                base = re_mod.sub(r"\[\s*\]\s*$", "", tt).strip()
                new_args.append(f"{base}* {n}")
            else:
                new_args.append(f"{tt} {n}")

    all_args = inject + new_args
    args_str = ", ".join(all_args) if all_args else "void"
    return f"{cdef_ret} {cname}({args_str});"


def should_wrap_function(name, fn):
    """Filter: only wrap simple ig* / ImGuiIO_ / ImFontAtlas_ / ImFont_ etc.
    Skip templates, constructors/destructors, and anything we can't cdef."""
    if fn.get("templated"):
        return False
    if fn.get("constructor") or fn.get("destructor"):
        return False
    if name.startswith(("ImVector_", "ImBitArray_", "ImChunkStream_",
                        "ImPool_", "ImSpan_", "ImStableVector_",
                        "ImSpanAllocator_")):
        return False
    return True


# ---------------- enum emission ----------------------------------------

def enum_short_name(full_enum_name, member_name):
    """ImGuiCol_ + ImGuiCol_Text -> "Text". Falls back to member name
    when the prefix doesn't match cleanly.

    Some cimgui enums (ImGuiAxis, ImGuiPlotType, ...) have no trailing
    underscore on the enum tag itself but their members are still
    ImGuiAxis_X / ImGuiAxis_Y -- naively stripping the tag would leave
    `_X`. Trim one extra leading underscore from `rest` in that case so
    the Lua-side name is `X` not `_X`."""
    prefix = full_enum_name
    if member_name.startswith(prefix):
        rest = member_name[len(prefix):]
        if rest.startswith("_") and len(rest) > 1:
            rest = rest[1:]
        return rest if rest else member_name
    return member_name


def emit_enum_table(enum_full_name, members):
    """Produce a Lua snippet: M.<short> = { Member = N, ... }"""
    # Short enum name: trim `ImGui` prefix and trailing `_`
    short = enum_full_name
    if short.endswith("_"):
        short = short[:-1]
    if short.startswith("ImGui"):
        short = short[len("ImGui"):]
    elif short.startswith("Im"):
        short = short[len("Im"):]
    if not short:
        short = enum_full_name.rstrip("_")

    lines = [f"M.{short} = {{"]
    seen = set()
    for m in members:
        sname = enum_short_name(enum_full_name, m["name"])
        if sname in seen:
            continue
        seen.add(sname)
        if sname[:1].isdigit():
            sname = "_" + sname
        if sname in _LUA_RESERVED:
            sname = "_" + sname
        lines.append(f"  {sname} = {m['calc_value']},")
    lines.append("}")
    return "\n".join(lines)


# ---------------- struct cdef emission ---------------------------------

_ARR_RE = __import__("re").compile(r"\[([^\]]+)\]")


# Populated by load_meta() once we know enum values. Keyed by member name
# (e.g. "ImGuiCol_COUNT" -> 55) so _eval_arrsize can substitute them when
# they appear in array bound expressions.
_ENUM_VALUES = {}


def _eval_arrsize(expr):
    """Evaluate a C-expression array size. Returns the int or the original
    expr if we can't evaluate. Handles +, -, *, /, parens, hex literals,
    and ImGui enum members like `ImGuiCol_COUNT`."""
    e = expr.strip()
    # Quick path: already an integer literal (decimal or hex)
    try:
        return str(int(e, 0))
    except ValueError:
        pass
    # Substitute known enum symbols with their numeric values, then try
    # the arithmetic evaluator below.
    import re as _re
    def _sub(m):
        name = m.group(0)
        if name in _ENUM_VALUES:
            return str(_ENUM_VALUES[name])
        return name  # unchanged -- safety check below will reject
    e = _re.sub(r"\b(Im[A-Za-z0-9_]+)\b", _sub, e)
    # Strict whitelist: only digits, hex digits, parens, basic arithmetic
    # operators, shift ops, and spaces. No identifiers, calls, attribute
    # access, or quoted strings can sneak through -- the eval below can
    # only compute pure integer arithmetic on the literals in expr.
    # eval() is intentional here: this is a dev-time build script that
    # consumes cimgui's own metadata. Inputs are not attacker-controlled.
    safe = all(c in "0123456789abcdefABCDEFxX+-*/()<> " for c in e)
    if not safe:
        return None
    try:
        v = eval(e, {"__builtins__": {}}, {})
        if isinstance(v, int):
            return str(v)
    except Exception:
        pass
    return None


def _fix_array_sizes(field_name):
    """Replace `[expr]` brackets with `[N]` where N is the evaluated value.
    Returns the rewritten name or None if any bracket can't be evaluated."""
    def sub(m):
        v = _eval_arrsize(m.group(1))
        if v is None:
            sub.bad = True
            return m.group(0)
        return f"[{v}]"
    sub.bad = False
    out = _ARR_RE.sub(sub, field_name)
    return None if sub.bad else out


def _template_padding(t):
    """If t is a template instantiation like `ImVector_ImWchar` and we know
    its size, return a `char [N]` substitute; otherwise None."""
    bare = t.replace("const ", "").replace("*", "").strip()
    if "_" not in bare:
        return None
    template = bare.split("_", 1)[0]
    sz = _TEMPLATE_SIZES.get(template)
    if sz is None:
        return None
    return f"char[{sz}]"


def emit_struct_cdef(struct_name, fields):
    """Emit a struct body for the cdef. Falls back to forward decl if any
    field has an unsupported type (e.g. function pointer, template) we
    can't substitute. Template instantiations by value (ImVector<T> etc.)
    are replaced with char[N] padding so layout is preserved -- the user
    can't reach those fields but everything around them stays accessible."""
    body_lines = []
    for f in fields:
        t = f.get("type", "")
        n = f.get("name", "")
        if not n:
            continue
        # Skip bitfields and unsupported types -- emit forward decl instead.
        if ":" in n or is_function_pointer_type(t) or "<" in t or "va_list" in t:
            return None
        # Strip C++ default initialisers from field names
        n_clean = n.split("=")[0].strip()
        # Evaluate array-size expressions like `[(0xFFFF+1)/8192/8]` into
        # plain integers; our cdef parser only accepts integer literals.
        if "[" in n_clean:
            fixed = _fix_array_sizes(n_clean)
            if fixed is None:
                return None
            n_clean = fixed
        # Substitute template-instantiated by-value fields (ImVector<T> etc)
        # with equivalently-sized char arrays so the surrounding layout
        # stays correct.
        type_str = rewrite_type(t)
        if ("ImVector_" in t or "ImSpan_" in t or "ImChunkStream_" in t or
            "ImStableVector_" in t) and "*" not in t:
            # C array syntax: `char name[N]`, not `char[N] name`
            bare = t.replace("const ", "").replace("*", "").strip()
            template = bare.split("_", 1)[0]
            sz = _TEMPLATE_SIZES.get(template)
            if sz is None:
                return None
            body_lines.append(f"    char {n_clean}[{sz}];  /* {t} */")
            continue
        body_lines.append(f"    {type_str} {n_clean};")
    body = "\n".join(body_lines)
    return f"typedef struct {struct_name} {{\n{body}\n}} {struct_name};"


# ---------------- main generation --------------------------------------

def main():
    defs, se = load_meta()

    # ---- Build cdef --------------------------------------------------------

    cdef_parts = []
    cdef_parts.append("/* === LuaVM ImGui bindings -- AUTOGENERATED ===")
    cdef_parts.append(" * Generated by tools/gen-imgui-bindings.py from cimgui metadata.")
    cdef_parts.append(" * Do not edit by hand; re-run the generator instead. */")
    cdef_parts.append("")

    # Primitive typedefs that cimgui uses
    cdef_parts.append("typedef unsigned int       ImU32;")
    cdef_parts.append("typedef unsigned short     ImU16;")
    cdef_parts.append("typedef signed short       ImS16;")
    cdef_parts.append("typedef unsigned char      ImU8;")
    cdef_parts.append("typedef signed char        ImS8;")
    cdef_parts.append("typedef unsigned long long ImU64;")
    cdef_parts.append("typedef signed long long   ImS64;")
    cdef_parts.append("typedef unsigned int       ImWchar32;")
    cdef_parts.append("typedef unsigned short     ImWchar16;")
    cdef_parts.append("typedef ImWchar32          ImWchar;")
    cdef_parts.append("typedef ImU32              ImGuiID;")
    cdef_parts.append("typedef ImU64              ImTextureID;")
    cdef_parts.append("typedef int                ImGuiSelectionUserData;")
    cdef_parts.append("typedef int                ImGuiKeyChord;")
    cdef_parts.append("typedef int                ImGuiMouseSource;")
    cdef_parts.append("typedef void*              ImFileHandle;")
    cdef_parts.append("typedef long long          ImTextureUserID;")
    cdef_parts.append("typedef long long          ptrdiff_t;")
    cdef_parts.append("typedef unsigned long long size_t;")
    cdef_parts.append("")
    # Function-pointer typedefs that our cdef parser can't represent --
    # alias them all to void* so they can be passed around as cdata. The
    # user supplies real callbacks via ffi.cast("type", lua_function).
    cdef_parts.append("typedef void* ImDrawCallback;")
    cdef_parts.append("typedef void* ImGuiInputTextCallback;")
    cdef_parts.append("typedef void* ImGuiSizeCallback;")
    cdef_parts.append("typedef void* ImGuiMemAllocFunc;")
    cdef_parts.append("typedef void* ImGuiMemFreeFunc;")
    cdef_parts.append("typedef void* ImGuiContextHookCallback;")
    cdef_parts.append("typedef void* ImGuiErrorCallback;")
    cdef_parts.append("typedef void* ImGuiSelectionRequest_TypeGetterFunc;")
    cdef_parts.append("typedef void* ImFontLoader_LoaderInit;")
    cdef_parts.append("typedef void* ImFontLoader_LoaderShutdown;")
    cdef_parts.append("typedef void* ImFontLoader_FontSrcInit;")
    cdef_parts.append("typedef void* ImFontLoader_FontSrcDestroy;")
    cdef_parts.append("typedef void* ImFontLoader_FontSrcContainsGlyph;")
    cdef_parts.append("typedef void* ImFontLoader_FontBakedInit;")
    cdef_parts.append("typedef void* ImFontLoader_FontBakedDestroy;")
    cdef_parts.append("typedef void* ImFontLoader_FontBakedLoadGlyph;")
    cdef_parts.append("")

    # Every enum becomes a typedef of int (cimgui treats them as ints).
    for enum_name in sorted(se.get("enums", {})):
        type_name = enum_name.rstrip("_")
        cdef_parts.append(f"typedef int {type_name};")
    cdef_parts.append("")

    # ImVec2 / ImVec4 / ImColor with explicit layout. Each field gets its
    # own declaration -- our ffi.cdef parser doesn't accept `float x, y;`.
    cdef_parts.append("typedef struct ImVec2  { float x; float y; } ImVec2;")
    cdef_parts.append("typedef struct ImVec4  { float x; float y; float z; float w; } ImVec4;")
    cdef_parts.append("typedef struct ImColor { ImVec4 Value; } ImColor;")
    cdef_parts.append("typedef struct ImVec2i { int x; int y; } ImVec2i;")
    cdef_parts.append("typedef struct ImVec2ih { short x; short y; } ImVec2ih;")
    cdef_parts.append("typedef struct ImRect { ImVec2 Min; ImVec2 Max; } ImRect;")
    cdef_parts.append("")

    # Opaque forward decls for every named struct we know about (including
    # template instantiations like ImVector_ImDrawListPtr). Other structs'
    # field types reference these names, so they need at least a forward
    # decl even if we never expose their bodies to Lua.
    all_struct_names = set(se.get("structs", {}).keys())
    all_struct_names |= set(se.get("templated_structs", {}).keys())
    # Scan all struct field type names for additional ImVector_* / ImSpan_*
    # / etc references that aren't in the master list. Use a strict
    # identifier pattern so we don't pick up stray syntax.
    import re as _re
    ident_re = _re.compile(r"\b(Im[A-Za-z0-9_]+)\b")
    primitive_typedefs = {
        "ImU8", "ImU16", "ImU32", "ImU64",
        "ImS8", "ImS16", "ImS32", "ImS64",
        "ImWchar", "ImWchar16", "ImWchar32",
        "ImTextureID", "ImGuiID", "ImGuiKeyChord", "ImGuiMouseSource",
        "ImGuiSelectionUserData", "ImTextureUserID",
        "ImDrawCallback", "ImGuiInputTextCallback", "ImGuiSizeCallback",
        "ImGuiMemAllocFunc", "ImGuiMemFreeFunc", "ImGuiContextHookCallback",
        "ImGuiErrorCallback", "ImGuiSelectionRequest_TypeGetterFunc",
    }
    extra_struct_names = set()
    for sname, fields in se.get("structs", {}).items():
        for f in fields:
            t = f.get("type", "")
            for m in ident_re.findall(t):
                if m in primitive_typedefs:
                    continue
                # Skip enum typedefs (already in primitive land)
                if m in se.get("enums", {}) or (m + "_") in se.get("enums", {}):
                    continue
                extra_struct_names.add(m)
    all_struct_names |= extra_struct_names
    skip_explicit = {
        "ImVec2", "ImVec4", "ImColor", "ImVec2i", "ImVec2ih", "ImRect",
    }
    for sname in sorted(all_struct_names):
        if sname in skip_explicit:
            continue
        if "<" in sname or ">" in sname or " " in sname:
            continue
        cdef_parts.append(f"typedef struct {sname} {sname};")
    cdef_parts.append("")

    # Open-body structs (only those without exotic fields).
    open_struct_cdefs   = []
    for sname in sorted(_OPEN_STRUCTS):
        if sname in skip_explicit:
            continue
        fields = se.get("structs", {}).get(sname)
        if not fields:
            continue
        body = emit_struct_cdef(sname, fields)
        if body is None:
            continue
        open_struct_cdefs.append(body)
    cdef_parts.extend(open_struct_cdefs)
    cdef_parts.append("")

    # Function decls -- iterate cimgui definitions, emit ig* + struct-method
    # functions that we know how to mechanically wrap.
    fn_count   = 0
    wrap_specs = []  # list of dicts: {cname, funcname, namespace_short, ret, args}
    for name in sorted(defs.keys()):
        for fn in defs[name]:
            if not should_wrap_function(name, fn):
                continue
            cdef_line = emit_function_cdef(fn)
            if cdef_line is None:
                continue
            cdef_parts.append(cdef_line)
            fn_count += 1
            wrap_specs.append({
                "cname":    fn["ov_cimguiname"],
                "funcname": fn.get("funcname", fn["ov_cimguiname"]),
                "stname":   fn.get("stname", ""),
                "ret":      fn.get("ret", "void"),
                "argsT":    fn.get("argsT", []),
            })

    cdef_text = "\n".join(cdef_parts) + "\n"

    # ---- Build wrappers ----------------------------------------------------
    # Group wrappers under tables: ig* -> M.<funcname>, ImGuiIO_* -> nothing
    # (Lua uses cdata field/method access directly), other ImXxx_* -> M.<Xxx>.<funcname>.

    lua_lines = []
    lua_lines.append("-- AUTOGENERATED by tools/gen-imgui-bindings.py from cimgui metadata.")
    lua_lines.append("-- Do not edit; re-run the generator.")
    lua_lines.append("")
    lua_lines.append("local M = {}")
    lua_lines.append("")
    lua_lines.append("M.__cdef = [==[")
    lua_lines.append(cdef_text)
    lua_lines.append("]==]")
    lua_lines.append("")

    # Enum tables
    enum_table_count = 0
    for enum_name in sorted(se.get("enums", {})):
        members = se["enums"][enum_name]
        if not members:
            continue
        lua_lines.append(emit_enum_table(enum_name, members))
        lua_lines.append("")
        enum_table_count += 1

    # Wrap specs as a SINGLE STRING (newline-separated records, semicolon-
    # separated fields, comma-separated arg tags). This avoids a giant
    # array-literal that would generate thousands of SETLIST/NEWTABLE/
    # SETFIELD bytecodes -- the resulting Lua chunk would be too large
    # for our JIT to compile reliably. One string constant + a runtime
    # parser is two orders of magnitude smaller bytecode.
    #
    # Record format:
    #   <cname>;<funcname>;<stname>;<ret_tag>;<arg_tags>
    #     cname     -- C symbol name (cimgui export)
    #     funcname  -- C++ name (or mangled funcname_suffix for overloads)
    #     stname    -- "" for top-level, struct name for type methods
    #     ret_tag   -- "p" plain | "v2" ImVec2 by value | "v4" ImVec4 by value
    #     arg_tags  -- comma-separated tags ("" if no args)
    lua_lines.append("M.__wraps_text = [==[")
    seen_names = OrderedDict()
    for spec in wrap_specs:
        key = (spec["stname"], spec["funcname"])
        if key in seen_names:
            mangled_func = spec["cname"].split("_")[-1]
            mkey = (spec["stname"], spec["funcname"] + "_" + mangled_func)
            if mkey in seen_names:
                mkey = (spec["stname"], spec["cname"])
            spec["funcname"] = mkey[1]
            key = mkey
        seen_names[key] = spec
        arg_tags = []
        for a in spec["argsT"]:
            t = a.get("type", "")
            tag = "p"
            if is_imvec2_byvalue(t):
                tag = "v2"
            elif is_imvec4_byvalue(t):
                tag = "v4"
            elif t.endswith("*") or "*" in t:
                tag = "ptr"
            arg_tags.append(tag)
        ret_tag = "p"
        ret = spec["ret"]
        if is_imvec2_byvalue(ret):
            ret_tag = "v2"
        elif is_imvec4_byvalue(ret):
            ret_tag = "v4"
        lua_lines.append(
            f'{spec["cname"]};{spec["funcname"]};{spec["stname"]};{ret_tag};{",".join(arg_tags)}'
        )
    lua_lines.append("]==]")
    lua_lines.append("")
    lua_lines.append("return M")
    lua_lines.append("")

    out_text = "\n".join(lua_lines)

    os.makedirs(os.path.dirname(OUTPUT_LUA), exist_ok=True)
    with open(OUTPUT_LUA, "w", encoding="utf-8", newline="\n") as f:
        f.write(out_text)

    print(f"[+] cdef        {fn_count} functions")
    print(f"[+] enum tables {enum_table_count}")
    print(f"[+] wrap specs  {len(wrap_specs)}")
    print(f"[+] wrote       {OUTPUT_LUA}")
    print(f"[+] size        {len(out_text):,} bytes")


if __name__ == "__main__":
    sys.exit(main() or 0)
