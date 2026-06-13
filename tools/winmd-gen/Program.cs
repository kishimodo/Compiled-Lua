// CLua windows-package generator.
//
// Reads Microsoft's Windows.Win32.winmd file, walks the requested
// namespace, and emits a CLua packages/windows/<area>.lua file with
// proper ffi.cdef declarations for every P/Invoke function + struct
// + constant in that namespace.
//
// Invoked from tools/gen-windows-package.ps1.
//
// Usage:
//   winmd-gen <winmd-path> <namespace> <out-file>

using System.Collections.Immutable;
using System.Reflection.Metadata;
using System.Reflection.PortableExecutable;
using System.Text;

if (args.Length < 3)
{
    Console.Error.WriteLine("usage: winmd-gen <winmd-path> <namespace> <out-file>");
    return 1;
}

string winmdPath = args[0];
string nsArg     = args[1];
string outFile   = args[2];

if (!File.Exists(winmdPath))
{
    Console.Error.WriteLine($"winmd not found: {winmdPath}");
    return 1;
}

using var stream = File.OpenRead(winmdPath);
using var peReader = new PEReader(stream);
var reader = peReader.GetMetadataReader();

// ----- Pass 1: bucket types in the requested namespace ------------------
var pinvokes   = new List<MethodDefinitionHandle>();
var structs    = new List<TypeDefinitionHandle>();
var unions     = new List<TypeDefinitionHandle>();
var enums      = new List<TypeDefinitionHandle>();
var interfaces = new List<TypeDefinitionHandle>();   // COM interfaces -- v4 vtable emission
var delegates  = new List<TypeDefinitionHandle>();   // function-pointer typedefs
var constants  = new List<FieldDefinitionHandle>();
var handleTypeRefs = new HashSet<string>();   // win32metadata wraps HANDLEs as struct typedefs

// Cross-namespace lookup: enum-name -> (handle, underlying-C-type). Used
// to typedef enums referenced from THIS namespace but defined elsewhere
// (e.g. IMAGE_FILE_MACHINE lives in System.SystemInformation but
// REASON_CONTEXT.Flags pulls it in via the Threading namespace).
var allEnumsByName     = new Dictionary<string, (TypeDefinitionHandle Handle, string Underlying)>();
var allDelegatesByName = new Dictionary<string, TypeDefinitionHandle>();
var allStructsByName   = new Dictionary<string, TypeDefinitionHandle>();   // any namespace
var allInterfaceNames  = new HashSet<string>(StringComparer.Ordinal);      // any namespace

foreach (var th in reader.TypeDefinitions)
{
    var t  = reader.GetTypeDefinition(th);
    var ns = reader.GetString(t.Namespace);
    var tn = reader.GetString(t.Name);

    // Build the global enum / delegate / interface index up front so
    // cross-namespace lookups work regardless of declaration order.
    if ((t.Attributes & System.Reflection.TypeAttributes.Interface) != 0)
    {
        allInterfaceNames.Add(tn);
    }
    if (t.BaseType.Kind == HandleKind.TypeReference)
    {
        var bTr = reader.GetTypeReference((TypeReferenceHandle)t.BaseType);
        var bNm = reader.GetString(bTr.Name);
        if (bNm == "Enum" && !allEnumsByName.ContainsKey(tn))
        {
            allEnumsByName[tn] = (th, GetEnumUnderlyingC(reader, t));
        }
        if (bNm == "MulticastDelegate" && !allDelegatesByName.ContainsKey(tn))
        {
            allDelegatesByName[tn] = th;
        }
        if (bNm == "ValueType" && !allStructsByName.ContainsKey(tn))
        {
            allStructsByName[tn] = th;
        }
    }

    if (ns != nsArg) continue;

    if (tn == "Apis")
    {
        // P/Invoke entry points + namespace-scoped constants.
        foreach (var mh in t.GetMethods())   pinvokes .Add(mh);
        foreach (var fh in t.GetFields())    constants.Add(fh);
        continue;
    }

    // COM interfaces have System.Reflection.TypeAttributes.Interface set
    // and are emitted by win32metadata for every COM API surface.
    if ((t.Attributes & System.Reflection.TypeAttributes.Interface) != 0)
    {
        interfaces.Add(th);
        continue;
    }

    // Detect ValueType / Enum heritage.
    if (t.BaseType.Kind == HandleKind.TypeReference)
    {
        var baseTr  = reader.GetTypeReference((TypeReferenceHandle)t.BaseType);
        var baseNm  = reader.GetString(baseTr.Name);
        if (baseNm == "Enum")              { enums    .Add(th); continue; }
        if (baseNm == "MulticastDelegate") { delegates.Add(th); continue; }
        if (baseNm == "ValueType")
        {
            // win32metadata distinguishes structs vs unions via a
            // StructLayoutAttribute with LayoutKind.Explicit (== union).
            // We approximate by checking the layout of the FIRST field:
            // if all fields share offset 0, it's a union.
            var attrs = t.Attributes;
            bool isUnion = false;
            foreach (var ah in t.GetCustomAttributes())
            {
                var attr = reader.GetCustomAttribute(ah);
                var ctor = attr.Constructor;
                if (ctor.Kind != HandleKind.MemberReference) continue;
                var mr = reader.GetMemberReference((MemberReferenceHandle)ctor);
                if (mr.Parent.Kind != HandleKind.TypeReference) continue;
                var parentTr = reader.GetTypeReference((TypeReferenceHandle)mr.Parent);
                if (reader.GetString(parentTr.Name) == "StructLayoutAttribute")
                {
                    // The first fixed arg is the LayoutKind enum (Sequential=0, Explicit=2, Auto=3).
                    var blob = reader.GetBlobReader(attr.Value);
                    blob.ReadUInt16();   // prolog 0x0001
                    int layoutKind = blob.ReadInt32();
                    if (layoutKind == 2) isUnion = true;
                }
            }
            (isUnion ? unions : structs).Add(th);
            continue;
        }
    }
}

// ----- Pass 2: collect handle-type names so we can map field types ------
// win32metadata wraps HANDLE-like types as structs containing a single
// "Value" field (IntPtr). We'll emit those as typedefs to void* and
// reference them by name elsewhere.
var handleAliases = new Dictionary<string, string>();
foreach (var sh in structs.ToArray())
{
    var t = reader.GetTypeDefinition(sh);
    var fields = t.GetFields();
    int fieldCount = fields.Count;
    if (fieldCount != 1) continue;
    var fh = fields.First();
    var f  = reader.GetFieldDefinition(fh);
    if (reader.GetString(f.Name) != "Value") continue;
    var sig = f.DecodeSignature(new CTypeProvider(reader, null), null);
    if (sig == "void *" || sig == "IntPtr" || sig == "HANDLE")
    {
        var name = reader.GetString(t.Name);
        handleAliases[name] = "void *";
        structs.Remove(sh);   // emit as typedef instead of struct
    }
}

// ----- Pass 2.5: collect nested anonymous unions/structs ----------------
// win32metadata models C anonymous unions/structs inside another record
// as nested .NET types with a generated name like "_Reason_e__Union" or
// "_Anonymous_e__Struct" plus an explicit layout. The parent struct's
// field references the nested type by name. We need to emit the nested
// type definition (and a typedef forward-declaration) before the parent
// so the cdef parser can resolve it.
var nestedTypes      = new List<(TypeDefinitionHandle Handle, bool IsUnion)>();
var nestedSeen       = new HashSet<string>();
void CollectNested(TypeDefinitionHandle outer)
{
    var ot = reader.GetTypeDefinition(outer);
    foreach (var nh in ot.GetNestedTypes())
    {
        var nt = reader.GetTypeDefinition(nh);
        var nName = reader.GetString(nt.Name);
        if (!nestedSeen.Add(nName)) continue;
        bool isUnion = (nt.Attributes & System.Reflection.TypeAttributes.ExplicitLayout) != 0;
        nestedTypes.Add((nh, isUnion));
        // Recurse: nested types may themselves contain nested anonymous
        // unions/structs (rare, but the metadata permits it).
        CollectNested(nh);
    }
}
foreach (var sh in structs) CollectNested(sh);
foreach (var uh in unions)  CollectNested(uh);

// ----- Pass 2.6: discover cross-namespace enum references ---------------
// Walk every field type / parameter type we'll emit. If a referenced name
// matches an enum in *any* namespace, we owe it a typedef so the cdef
// block resolves cleanly. (Enums in this namespace are already in
// `enums`; cross-namespace ones live only in `allEnumsByName`.)
var referencedNames = new HashSet<string>();
var refProvider     = new CTypeProvider(reader, null);
void NoteFieldRefs(TypeDefinitionHandle th)
{
    var t = reader.GetTypeDefinition(th);
    foreach (var fh in t.GetFields())
    {
        var f = reader.GetFieldDefinition(fh);
        string sig;
        try { sig = f.DecodeSignature(refProvider, null); }
        catch { continue; }
        foreach (var tok in ExtractIdentifiers(sig)) referencedNames.Add(tok);
    }
}
void NoteMethodRefs(MethodDefinitionHandle mh)
{
    var m = reader.GetMethodDefinition(mh);
    MethodSignature<string> sig;
    try { sig = m.DecodeSignature(refProvider, null); }
    catch { return; }
    foreach (var tok in ExtractIdentifiers(sig.ReturnType)) referencedNames.Add(tok);
    foreach (var pt in sig.ParameterTypes)
        foreach (var tok in ExtractIdentifiers(pt)) referencedNames.Add(tok);
}
foreach (var sh in structs)          NoteFieldRefs(sh);
foreach (var uh in unions)           NoteFieldRefs(uh);
foreach (var (nh, _) in nestedTypes) NoteFieldRefs(nh);
foreach (var mh in pinvokes)         NoteMethodRefs(mh);
// Delegate Invoke signatures reference types too (callback parameters
// often include cross-namespace structs like GENERIC_MAPPING *).
foreach (var dh in delegates)
{
    var dt = reader.GetTypeDefinition(dh);
    foreach (var mh in dt.GetMethods())
    {
        var m = reader.GetMethodDefinition(mh);
        if (reader.GetString(m.Name) == "Invoke") NoteMethodRefs(mh);
    }
}
// Same for COM interface methods. Walk the inheritance chain so methods
// inherited from base interfaces in other namespaces also count as
// references (mirrors the EmitInterface vtable walk below).
void NoteInterfaceChain(TypeDefinitionHandle ih, HashSet<TypeDefinitionHandle> seen)
{
    if (!seen.Add(ih)) return;
    var it = reader.GetTypeDefinition(ih);
    foreach (var iih in it.GetInterfaceImplementations())
    {
        var imp = reader.GetInterfaceImplementation(iih);
        if (imp.Interface.Kind == HandleKind.TypeReference)
        {
            var tr = reader.GetTypeReference((TypeReferenceHandle)imp.Interface);
            var bName = reader.GetString(tr.Name);
            var bNs   = reader.GetString(tr.Namespace);
            if (bName == "IUnknown") continue;
            foreach (var probe in reader.TypeDefinitions)
            {
                var pt = reader.GetTypeDefinition(probe);
                if (reader.GetString(pt.Name) == bName &&
                    reader.GetString(pt.Namespace) == bNs)
                {
                    NoteInterfaceChain(probe, seen);
                    break;
                }
            }
        }
        else if (imp.Interface.Kind == HandleKind.TypeDefinition)
        {
            NoteInterfaceChain((TypeDefinitionHandle)imp.Interface, seen);
        }
    }
    foreach (var mh in it.GetMethods()) NoteMethodRefs(mh);
}
foreach (var ih in interfaces) NoteInterfaceChain(ih, new HashSet<TypeDefinitionHandle>());

// Enums in this namespace that are actually referenced get cdef typedefs.
// (Unreferenced ones still appear in the return table for constant access
// but don't need to bloat the cdef block.)
var inNsEnumNames = new HashSet<string>(
    enums.Select(eh => reader.GetString(reader.GetTypeDefinition(eh).Name)));
var crossNsEnumTypedefs = new List<(string Name, string Underlying)>();
var inNsDelegateNames   = new HashSet<string>(
    delegates.Select(dh => reader.GetString(reader.GetTypeDefinition(dh).Name)));
var crossNsDelegates    = new List<TypeDefinitionHandle>();
var inNsStructNames     = new HashSet<string>(
    structs.Concat(unions).Select(h => reader.GetString(reader.GetTypeDefinition(h).Name)));
var inNsHandleNames     = new HashSet<string>(handleAliases.Keys);
var inNsInterfaceNames  = new HashSet<string>(
    interfaces.Select(h => reader.GetString(reader.GetTypeDefinition(h).Name)));
// Names the CTypeProvider already remaps to a primitive / standard
// typedef, or that are already defined by windows/init.lua + the FFI
// runtime's built-in Win32 type table -- never emit a duplicate
// definition for these.
var primitiveAliases    = new HashSet<string>(StringComparer.Ordinal)
{
    // CTypeProvider remaps these to the names below.
    "BOOL", "BOOLEAN", "HRESULT", "NTSTATUS", "HANDLE",
    "PSTR", "PCSTR", "PWSTR", "PCWSTR", "GUID", "Guid", "GUID_W",
    // Primitive aliases emitted in the preamble / by the FFI runtime.
    "CHAR", "BYTE", "WORD", "DWORD", "ULONG", "LONG", "LONGLONG",
    "ULONGLONG", "WCHAR", "UCHAR", "USHORT", "UINT", "INT", "SHORT",
    "UINT_PTR", "LPSTR", "LPCSTR", "LPWSTR", "LPCWSTR", "LPVOID",
    "PVOID", "LPCVOID", "LPDWORD",
    // Common structs / pointer typedefs already defined by
    // windows/init.lua. Re-emitting them would compile (cdef accepts
    // compatible re-registration) but is noise; skip them.
    "FILETIME", "SYSTEMTIME", "OVERLAPPED", "SECURITY_ATTRIBUTES",
    "STARTUPINFOW", "STARTUPINFOA", "PROCESS_INFORMATION",
    "MEMORY_BASIC_INFORMATION", "POINT", "RECT", "MSG", "LARGE_INTEGER",
    "HMODULE", "HINSTANCE", "HWND", "HKEY", "FARPROC",
};
// Cross-namespace struct/handle pulls. Single-Value structs become
// `typedef void *Name;` (opaque handle); multi-field structs become a
// forward-declared opaque tag (only safe to use as a pointer, which is
// the only way other namespaces typically expose them anyway).
var crossNsHandleTypedefs = new List<string>();
var crossNsOpaqueStructs  = new List<string>();
foreach (var nm in referencedNames)
{
    if (inNsEnumNames.Contains(nm) || inNsDelegateNames.Contains(nm) ||
        inNsStructNames.Contains(nm) || inNsHandleNames.Contains(nm) ||
        inNsInterfaceNames.Contains(nm) || nestedSeen.Contains(nm) ||
        primitiveAliases.Contains(nm)) continue;
    if (allEnumsByName.TryGetValue(nm, out var info))
    {
        crossNsEnumTypedefs.Add((nm, info.Underlying));
        continue;
    }
    if (allDelegatesByName.TryGetValue(nm, out var dh))
    {
        crossNsDelegates.Add(dh);
        continue;
    }
    if (allStructsByName.TryGetValue(nm, out var sh))
    {
        var st = reader.GetTypeDefinition(sh);
        var fields = st.GetFields();
        bool isHandleLike = false;
        if (fields.Count == 1)
        {
            var f0 = reader.GetFieldDefinition(fields.First());
            if (reader.GetString(f0.Name) == "Value")
            {
                try
                {
                    var fsig = f0.DecodeSignature(refProvider, null);
                    if (fsig == "void *" || fsig == "IntPtr") isHandleLike = true;
                }
                catch { }
            }
        }
        if (isHandleLike) crossNsHandleTypedefs.Add(nm);
        else              crossNsOpaqueStructs .Add(nm);
        continue;
    }
    if (allInterfaceNames.Contains(nm))
    {
        // Cross-namespace COM interface: forward-decl as an opaque
        // struct so signatures like `IEnumConnectionPoints *` parse.
        crossNsOpaqueStructs.Add(nm);
    }
}
crossNsEnumTypedefs.Sort((a, b) => string.CompareOrdinal(a.Name, b.Name));
crossNsDelegates.Sort((a, b) => string.CompareOrdinal(
    reader.GetString(reader.GetTypeDefinition(a).Name),
    reader.GetString(reader.GetTypeDefinition(b).Name)));
crossNsHandleTypedefs.Sort(StringComparer.Ordinal);
crossNsOpaqueStructs.Sort(StringComparer.Ordinal);

// ----- Pass 3: emit the .lua --------------------------------------------
var sb = new StringBuilder();
string niceNs = nsArg.StartsWith("Windows.Win32.") ? nsArg.Substring("Windows.Win32.".Length) : nsArg;

sb.AppendLine($"-- AUTO-GENERATED by tools/winmd-gen (via gen-windows-package.ps1)");
sb.AppendLine($"-- Namespace: {nsArg}");
sb.AppendLine($"-- Counts: {structs.Count} structs, {unions.Count} unions, " +
              $"{enums.Count} enums, {interfaces.Count} COM interfaces, " +
              $"{pinvokes.Count} functions, {constants.Count} constants, " +
              $"{handleAliases.Count} handle typedefs, " +
              $"{nestedTypes.Count} nested unions/structs, " +
              $"{delegates.Count + crossNsDelegates.Count} delegates");
sb.AppendLine("--");
sb.AppendLine("local W = require \"windows\"");
sb.AppendLine();
sb.AppendLine("ffi.cdef[[");

// Primitive Win32 typedef preamble. The runtime (src/ffi/win_types.c)
// pre-registers BYTE/WORD/DWORD/WCHAR/etc., but a few standard names
// (CHAR, SHORT, LONGLONG) aren't always there, and win32metadata happily
// references them. Emit them up front so every cdef block is self-
// sufficient regardless of what the runtime already knows.
sb.AppendLine("/* primitive Win32 typedefs (idempotent vs. runtime built-ins) */");
sb.AppendLine("typedef char               CHAR;");
sb.AppendLine();
// GUID_W mirrors REFGUID/GUID. Some sub-packages reference it through
// COM vtables or struct fields without pulling in windows.com, so we
// emit a private definition whenever the namespace's surface needs it.
if (referencedNames.Contains("GUID_W") || interfaces.Count > 0)
{
    sb.AppendLine("typedef struct _winmdgen_GUID_W {");
    sb.AppendLine("    DWORD Data1; WORD Data2; WORD Data3; BYTE Data4[8];");
    sb.AppendLine("} GUID_W;");
    sb.AppendLine();
}

// Emit handle typedefs (other types may reference them).
foreach (var kv in handleAliases.OrderBy(k => k.Key))
{
    sb.AppendLine($"typedef {kv.Value} {kv.Key};");
}
// Cross-namespace single-Value structs become opaque pointers too --
// PSECURITY_DESCRIPTOR, HSTRING, etc. live in Security/etc. but
// FileSystem fields reference them by name.
foreach (var nm in crossNsHandleTypedefs)
{
    sb.AppendLine($"typedef void *{nm};");
}
sb.AppendLine();

// Typedef same-namespace enums as their underlying integer type. Without
// this, struct fields like `POWER_REQUEST_CONTEXT_FLAGS Flags;` (in
// REASON_CONTEXT) would refer to an undefined identifier inside the
// cdef block -- the enum members live in the Lua return table, not the
// cdef. Cross-namespace enums get the same treatment further down.
if (enums.Count > 0)
{
    sb.AppendLine("/* enum typedefs (members live in the return table below) */");
    foreach (var eh in enums.OrderBy(h => reader.GetString(reader.GetTypeDefinition(h).Name)))
    {
        var et   = reader.GetTypeDefinition(eh);
        var name = reader.GetString(et.Name);
        var und  = GetEnumUnderlyingC(reader, et);
        sb.AppendLine($"typedef {und} {name};");
    }
    sb.AppendLine();
}
if (crossNsEnumTypedefs.Count > 0)
{
    sb.AppendLine("/* cross-namespace enum typedefs */");
    foreach (var (name, und) in crossNsEnumTypedefs)
    {
        sb.AppendLine($"typedef {und} {name};");
    }
    sb.AppendLine();
}

// Forward-declare struct + union + interface tags so cross-references work.
// (Must come BEFORE delegate typedefs so a callback signature like
// `void (*FOO)(MyStruct *)` can resolve MyStruct.)
foreach (var sh in structs)
{
    var name = reader.GetString(reader.GetTypeDefinition(sh).Name);
    sb.AppendLine($"typedef struct _{name} {name};");
}
foreach (var uh in unions)
{
    var name = reader.GetString(reader.GetTypeDefinition(uh).Name);
    sb.AppendLine($"typedef union _{name} {name};");
}
// Nested anonymous unions/structs: forward-declare under their own
// generated name (e.g. `_Reason_e__Union`). The metadata uses the
// fully-qualified name as-is when emitting the parent's field type,
// so we keep the leading underscore.
foreach (var (nh, isUnion) in nestedTypes)
{
    var name = reader.GetString(reader.GetTypeDefinition(nh).Name);
    var kw   = isUnion ? "union" : "struct";
    sb.AppendLine($"typedef {kw} _{name}_tag {name};");
}
foreach (var ih in interfaces)
{
    var name = reader.GetString(reader.GetTypeDefinition(ih).Name);
    sb.AppendLine($"typedef struct {name} {name};");
    sb.AppendLine($"typedef struct {name}Vtbl {name}Vtbl;");
}
// Cross-namespace opaque structs: forward-declared only. We don't pull
// in the full layout because the FileSystem surface only uses these
// behind a pointer (PRIVILEGE_SET *, GENERIC_MAPPING *, etc.), and a
// full chase would explode the cdef block.
foreach (var nm in crossNsOpaqueStructs)
{
    sb.AppendLine($"typedef struct _{nm}_opaque {nm};");
}
sb.AppendLine();

// Delegate (callback) typedefs. win32metadata models LPTHREAD_START_ROUTINE
// etc. as .NET MulticastDelegate types; the Invoke method carries the C
// signature. Emit each as a function-pointer typedef so struct fields
// like `PLOG_TAIL_ADVANCE_CALLBACK AdvanceTailCallback` resolve cleanly.
if (delegates.Count > 0 || crossNsDelegates.Count > 0)
{
    sb.AppendLine("/* callback (function-pointer) typedefs */");
    var delegateTp = new CTypeProvider(reader, handleAliases);
    foreach (var dh in delegates)        EmitDelegate(sb, reader, dh, delegateTp);
    foreach (var dh in crossNsDelegates) EmitDelegate(sb, reader, dh, delegateTp);
    sb.AppendLine();
}

var typeProvider = new CTypeProvider(reader, handleAliases);

// Emit nested-type bodies BEFORE the parents that reference them.
foreach (var (nh, isUnion) in nestedTypes)
{
    EmitNested(sb, reader, nh, typeProvider, isUnion);
}

// Emit struct definitions.
foreach (var sh in structs)
{
    EmitRecord(sb, reader, sh, typeProvider, isUnion: false);
}
foreach (var uh in unions)
{
    EmitRecord(sb, reader, uh, typeProvider, isUnion: true);
}

// Emit COM interfaces as vtable structs + the wrapper struct holding
// the vtable pointer. Phase 3 v4. Each interface gets:
//   typedef struct <Name>Vtbl {
//       HRESULT (__stdcall *QueryInterface)(<Name> *This, GUID *riid, void **ppvObject);
//       ULONG   (__stdcall *AddRef)(<Name> *This);
//       ULONG   (__stdcall *Release)(<Name> *This);
//       <return> (__stdcall *<Method>)(<Name> *This, <args>);
//       ...
//   } <Name>Vtbl;
//   typedef struct <Name> { <Name>Vtbl *lpVtbl; } <Name>;
// The vtable includes inherited methods (walking base interfaces) so
// calling pInterface->lpVtbl->Method(...) matches the runtime layout.
if (interfaces.Count > 0)
{
    sb.AppendLine("/* ===== COM interfaces ===== */");
}
foreach (var ih in interfaces)
{
    EmitInterface(sb, reader, ih, typeProvider);
}

// Emit P/Invoke function declarations.
sb.AppendLine($"/* {niceNs} -- {pinvokes.Count} functions */");
foreach (var mh in pinvokes)
{
    EmitPInvoke(sb, reader, mh, typeProvider);
}

sb.AppendLine("]]");
sb.AppendLine();

// Emit constants + enums in the return table.
sb.AppendLine("return {");
foreach (var ch in constants.OrderBy(h =>
    reader.GetString(reader.GetFieldDefinition(h).Name)))
{
    EmitConstant(sb, reader, ch);
}
foreach (var eh in enums.OrderBy(h =>
    reader.GetString(reader.GetTypeDefinition(h).Name)))
{
    EmitEnumMembers(sb, reader, eh);
}
sb.AppendLine("}");

File.WriteAllText(outFile, sb.ToString());
Console.WriteLine($"[+] wrote {outFile}: {structs.Count} structs / {unions.Count} unions / {enums.Count} enums / {pinvokes.Count} functions / {constants.Count} constants");
return 0;

// ============================================================================

static void EmitRecord(StringBuilder sb, MetadataReader reader,
                       TypeDefinitionHandle th, CTypeProvider tp, bool isUnion)
{
    var t    = reader.GetTypeDefinition(th);
    var name = reader.GetString(t.Name);
    var kw   = isUnion ? "union" : "struct";
    sb.AppendLine($"{kw} _{name} {{");
    foreach (var fh in t.GetFields())
    {
        var f     = reader.GetFieldDefinition(fh);
        var fname = reader.GetString(f.Name);
        string ftype;
        try { ftype = f.DecodeSignature(tp, null); }
        catch { ftype = "/* undecoded */ void *"; }
        sb.AppendLine($"    {ftype} {fname};");
    }
    sb.AppendLine($"}};");
}

// Emit a .NET MulticastDelegate as a C function-pointer typedef. The
// Invoke method carries the call signature in the metadata; we wrap it
// as `typedef <ret> (*<Name>)(<args>);` so struct fields and parameter
// types can reference the delegate by its name.
static void EmitDelegate(StringBuilder sb, MetadataReader reader,
                         TypeDefinitionHandle th, CTypeProvider tp)
{
    var t    = reader.GetTypeDefinition(th);
    var name = reader.GetString(t.Name);
    MethodDefinitionHandle invokeH = default;
    foreach (var mh in t.GetMethods())
    {
        var m = reader.GetMethodDefinition(mh);
        if (reader.GetString(m.Name) == "Invoke") { invokeH = mh; break; }
    }
    if (invokeH.IsNil)
    {
        sb.AppendLine($"typedef void *{name};");
        return;
    }
    var im = reader.GetMethodDefinition(invokeH);
    MethodSignature<string> sig;
    try { sig = im.DecodeSignature(tp, null); }
    catch { sb.AppendLine($"typedef void *{name};"); return; }
    var args = sig.ParameterTypes.Length == 0
        ? "void"
        : string.Join(", ", sig.ParameterTypes);
    sb.AppendLine($"typedef {sig.ReturnType} (*{name})({args});");
}

// Nested anonymous unions/structs use a `_<name>_tag` tag so the
// forward-declared typedef can resolve to them. The visible name
// (`_uChar_e__Union`, `_Reason_e__Union`, ...) matches what the parent
// struct's field type prints.
static void EmitNested(StringBuilder sb, MetadataReader reader,
                       TypeDefinitionHandle th, CTypeProvider tp, bool isUnion)
{
    var t    = reader.GetTypeDefinition(th);
    var name = reader.GetString(t.Name);
    var kw   = isUnion ? "union" : "struct";
    sb.AppendLine($"{kw} _{name}_tag {{");
    foreach (var fh in t.GetFields())
    {
        var f     = reader.GetFieldDefinition(fh);
        var fname = reader.GetString(f.Name);
        string ftype;
        try { ftype = f.DecodeSignature(tp, null); }
        catch { ftype = "/* undecoded */ void *"; }
        sb.AppendLine($"    {ftype} {fname};");
    }
    sb.AppendLine($"}};");
}

// Read the enum's `value__` field and return the C type to use for a
// `typedef <C-type> <EnumName>;`. Win32 enums are uniformly UInt32 or
// Int32; the few outliers (UInt64 LIBRARY_LOAD_FLAGS-style) round-trip
// to ULONGLONG which the runtime knows about.
static string GetEnumUnderlyingC(MetadataReader reader, TypeDefinition t)
{
    foreach (var fh in t.GetFields())
    {
        var f = reader.GetFieldDefinition(fh);
        if (reader.GetString(f.Name) != "value__") continue;
        var blob = reader.GetBlobReader(f.Signature);
        blob.ReadByte();              // field-sig prolog
        var code = (SignatureTypeCode)blob.ReadByte();
        return code switch
        {
            SignatureTypeCode.SByte  => "char",
            SignatureTypeCode.Byte   => "BYTE",
            SignatureTypeCode.Int16  => "short",
            SignatureTypeCode.UInt16 => "WORD",
            SignatureTypeCode.Int32  => "LONG",
            SignatureTypeCode.UInt32 => "DWORD",
            SignatureTypeCode.Int64  => "LONGLONG",
            SignatureTypeCode.UInt64 => "ULONGLONG",
            _                        => "DWORD",
        };
    }
    return "DWORD";
}

// Walk a C type string and yield the identifiers it references (skips
// reserved words like `const`, `struct`, `unsigned`, `void`, ...).
static IEnumerable<string> ExtractIdentifiers(string s)
{
    if (string.IsNullOrEmpty(s)) yield break;
    var sb = new StringBuilder();
    for (int i = 0; i <= s.Length; i++)
    {
        char c = i < s.Length ? s[i] : ' ';
        bool isIdChar = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                        (c >= '0' && c <= '9') || c == '_';
        if (isIdChar) { sb.Append(c); continue; }
        if (sb.Length > 0)
        {
            var tok = sb.ToString();
            sb.Clear();
            if (tok.Length > 0 && !char.IsDigit(tok[0]) && !CTypeKeywords.All.Contains(tok))
                yield return tok;
        }
    }
}


static void EmitInterface(StringBuilder sb, MetadataReader reader,
                          TypeDefinitionHandle th, CTypeProvider tp)
{
    var t    = reader.GetTypeDefinition(th);
    var name = reader.GetString(t.Name);
    sb.AppendLine($"struct {name}Vtbl {{");

    // Walk base interfaces (depth-first, deduped) and emit their methods
    // FIRST. The vtable layout requires inherited slots to come before
    // the current interface's own slots. IUnknown's QI/AddRef/Release
    // are reached via this chain when the interface inherits IUnknown
    // directly or transitively.
    var emitted = new HashSet<string>();
    void EmitChain(TypeDefinitionHandle ih)
    {
        var t = reader.GetTypeDefinition(ih);
        // Walk base interfaces first
        foreach (var iih in t.GetInterfaceImplementations())
        {
            var imp = reader.GetInterfaceImplementation(iih);
            if (imp.Interface.Kind == HandleKind.TypeReference)
            {
                var tr = reader.GetTypeReference((TypeReferenceHandle)imp.Interface);
                // Try to look up by name in this assembly's TypeDefinitions
                var ifaceName = reader.GetString(tr.Name);
                var ifaceNs   = reader.GetString(tr.Namespace);
                if (ifaceName == "IUnknown")
                {
                    // Emit the canonical three IUnknown slots.
                    if (emitted.Add("QueryInterface"))
                        sb.AppendLine($"    HRESULT (__stdcall *QueryInterface)({reader.GetString(reader.GetTypeDefinition(th).Name)} *This, GUID_W *riid, void **ppvObject);");
                    if (emitted.Add("AddRef"))
                        sb.AppendLine($"    ULONG (__stdcall *AddRef)({reader.GetString(reader.GetTypeDefinition(th).Name)} *This);");
                    if (emitted.Add("Release"))
                        sb.AppendLine($"    ULONG (__stdcall *Release)({reader.GetString(reader.GetTypeDefinition(th).Name)} *This);");
                    continue;
                }
                // Try to find the inherited interface in this assembly's
                // TypeDefinitions and emit its methods.
                TypeDefinitionHandle? found = null;
                foreach (var probe in reader.TypeDefinitions)
                {
                    var pt = reader.GetTypeDefinition(probe);
                    if (reader.GetString(pt.Name) == ifaceName &&
                        reader.GetString(pt.Namespace) == ifaceNs)
                    {
                        found = probe; break;
                    }
                }
                if (found != null) EmitChain(found.Value);
            }
            else if (imp.Interface.Kind == HandleKind.TypeDefinition)
            {
                EmitChain((TypeDefinitionHandle)imp.Interface);
            }
        }
        // Then emit this interface's own methods
        foreach (var mh in t.GetMethods())
        {
            var m     = reader.GetMethodDefinition(mh);
            var mname = reader.GetString(m.Name);
            if (!emitted.Add(mname)) continue;
            MethodSignature<string> sig;
            try { sig = m.DecodeSignature(tp, null); }
            catch { sb.AppendLine($"    /* undecoded */ void *{mname};"); continue; }
            var paramHandles = m.GetParameters();
            var paramNames   = new List<string>();
            foreach (var ph in paramHandles)
            {
                var p = reader.GetParameter(ph);
                if (p.SequenceNumber == 0) continue;
                paramNames.Add(reader.GetString(p.Name));
            }
            var args = new List<string>();
            args.Add($"{reader.GetString(reader.GetTypeDefinition(th).Name)} *This");
            for (int i = 0; i < sig.ParameterTypes.Length; i++)
            {
                var ty = sig.ParameterTypes[i];
                var nm = i < paramNames.Count ? paramNames[i] : $"_p{i}";
                args.Add($"{ty} {nm}");
            }
            sb.AppendLine($"    {sig.ReturnType} (__stdcall *{mname})({string.Join(", ", args)});");
        }
    }
    EmitChain(th);
    sb.AppendLine($"}};");
    sb.AppendLine($"struct {name} {{ {name}Vtbl *lpVtbl; }};");
}

static void EmitPInvoke(StringBuilder sb, MetadataReader reader,
                        MethodDefinitionHandle mh, CTypeProvider tp)
{
    var m     = reader.GetMethodDefinition(mh);
    var name  = reader.GetString(m.Name);
    MethodSignature<string> sig;
    try { sig = m.DecodeSignature(tp, null); }
    catch { sb.AppendLine($"/* undecoded */ void {name}();"); return; }

    var paramHandles = m.GetParameters();
    var paramNames   = new List<string>();
    foreach (var ph in paramHandles)
    {
        var p = reader.GetParameter(ph);
        if (p.SequenceNumber == 0) continue;   // return parameter
        paramNames.Add(reader.GetString(p.Name));
    }
    var args = new List<string>();
    for (int i = 0; i < sig.ParameterTypes.Length; i++)
    {
        var t = sig.ParameterTypes[i];
        var n = i < paramNames.Count ? paramNames[i] : $"_p{i}";
        args.Add($"{t} {n}");
    }
    sb.AppendLine($"{sig.ReturnType} {name}({string.Join(", ", args)});");
}

static void EmitConstant(StringBuilder sb, MetadataReader reader, FieldDefinitionHandle ch)
{
    var f     = reader.GetFieldDefinition(ch);
    var fname = reader.GetString(f.Name);
    var cdh   = f.GetDefaultValue();
    if (cdh.IsNil) return;
    var c    = reader.GetConstant(cdh);
    var blob = reader.GetBlobReader(c.Value);
    string value;
    try
    {
        value = c.TypeCode switch
        {
            ConstantTypeCode.Boolean => blob.ReadBoolean() ? "true" : "false",
            ConstantTypeCode.Char    => ((int)blob.ReadChar()).ToString(),
            ConstantTypeCode.SByte   => blob.ReadSByte().ToString(),
            ConstantTypeCode.Byte    => blob.ReadByte().ToString(),
            ConstantTypeCode.Int16   => blob.ReadInt16().ToString(),
            ConstantTypeCode.UInt16  => blob.ReadUInt16().ToString(),
            ConstantTypeCode.Int32   => blob.ReadInt32().ToString(),
            ConstantTypeCode.UInt32  => "0x" + blob.ReadUInt32().ToString("X8"),
            ConstantTypeCode.Int64   => blob.ReadInt64().ToString(),
            ConstantTypeCode.UInt64  => "0x" + blob.ReadUInt64().ToString("X16"),
            ConstantTypeCode.Single  => blob.ReadSingle().ToString("G"),
            ConstantTypeCode.Double  => blob.ReadDouble().ToString("G"),
            ConstantTypeCode.String  => "\"" + EscapeLua(blob.ReadUTF16(blob.RemainingBytes)) + "\"",
            _ => "nil"
        };
    }
    catch { value = "nil"; }
    sb.AppendLine($"    {fname} = {value},");
}

static void EmitEnumMembers(StringBuilder sb, MetadataReader reader, TypeDefinitionHandle eh)
{
    var t = reader.GetTypeDefinition(eh);
    var enumName = reader.GetString(t.Name);
    sb.AppendLine($"    -- enum {enumName}");
    foreach (var fh in t.GetFields())
    {
        var f = reader.GetFieldDefinition(fh);
        // Skip the special "value__" field that holds the enum's underlying type.
        var fname = reader.GetString(f.Name);
        if (fname == "value__") continue;
        var cdh = f.GetDefaultValue();
        if (cdh.IsNil) continue;
        var c    = reader.GetConstant(cdh);
        var blob = reader.GetBlobReader(c.Value);
        string value;
        try
        {
            value = c.TypeCode switch
            {
                ConstantTypeCode.Int32  => blob.ReadInt32().ToString(),
                ConstantTypeCode.UInt32 => "0x" + blob.ReadUInt32().ToString("X8"),
                ConstantTypeCode.Int64  => blob.ReadInt64().ToString(),
                ConstantTypeCode.UInt64 => "0x" + blob.ReadUInt64().ToString("X16"),
                _ => "0"
            };
        }
        catch { value = "0"; }
        sb.AppendLine($"    {enumName}_{fname} = {value},");
    }
}

static string EscapeLua(string s) => s.Replace("\\", "\\\\").Replace("\"", "\\\"");

// ============================================================================
// Reserved C words to ignore when walking a type string for identifiers.
static class CTypeKeywords
{
    public static readonly HashSet<string> All = new(StringComparer.Ordinal)
    {
        "char", "short", "int", "long", "signed", "unsigned", "void",
        "float", "double", "const", "volatile", "struct", "union", "enum",
        "static", "extern", "inline", "__stdcall", "__cdecl",
    };
}

// ============================================================================
// CTypeProvider -- translates winmd type signatures to CLua C types.

class CTypeProvider : ISignatureTypeProvider<string, object?>
{
    private readonly MetadataReader _reader;
    private readonly Dictionary<string, string>? _handleAliases;

    public CTypeProvider(MetadataReader reader, Dictionary<string, string>? handleAliases)
    {
        _reader = reader;
        _handleAliases = handleAliases;
    }

    public string GetPrimitiveType(PrimitiveTypeCode typeCode) => typeCode switch
    {
        PrimitiveTypeCode.Boolean => "BOOL",
        PrimitiveTypeCode.Char    => "WCHAR",
        PrimitiveTypeCode.SByte   => "char",
        PrimitiveTypeCode.Byte    => "BYTE",
        PrimitiveTypeCode.Int16   => "short",
        PrimitiveTypeCode.UInt16  => "WORD",
        PrimitiveTypeCode.Int32   => "LONG",
        PrimitiveTypeCode.UInt32  => "DWORD",
        PrimitiveTypeCode.Int64   => "LONGLONG",
        PrimitiveTypeCode.UInt64  => "ULONGLONG",
        PrimitiveTypeCode.IntPtr  => "void *",
        PrimitiveTypeCode.UIntPtr => "void *",
        PrimitiveTypeCode.Single  => "float",
        PrimitiveTypeCode.Double  => "double",
        PrimitiveTypeCode.String  => "LPCWSTR",
        PrimitiveTypeCode.Object  => "void *",
        PrimitiveTypeCode.Void    => "void",
        _ => "void *"
    };

    public string GetTypeFromDefinition(MetadataReader reader, TypeDefinitionHandle handle, byte rawTypeKind)
    {
        var t = reader.GetTypeDefinition(handle);
        return reader.GetString(t.Name);
    }

    public string GetTypeFromReference(MetadataReader reader, TypeReferenceHandle handle, byte rawTypeKind)
    {
        var t = reader.GetTypeReference(handle);
        var name = reader.GetString(t.Name);
        // Foundation.* handle wrappers all collapse to opaque pointers
        // unless the caller (this generator) added an explicit typedef.
        return name switch
        {
            "BOOL"     => "BOOL",
            "BOOLEAN"  => "BYTE",
            "HRESULT"  => "HRESULT",
            "NTSTATUS" => "NTSTATUS",
            "HANDLE"   => "HANDLE",
            "PSTR"     => "LPSTR",
            "PCSTR"    => "LPCSTR",
            "PWSTR"    => "LPWSTR",
            "PCWSTR"   => "LPCWSTR",
            "GUID"     => "GUID_W",
            "Guid"     => "GUID_W",   // System.Guid (BCL primitive used by winmd)
            _          => name,
        };
    }

    public string GetPointerType(string elementType)        => elementType + " *";
    public string GetArrayType(string elementType, ArrayShape shape) => elementType + " *";
    public string GetSZArrayType(string elementType)        => elementType + " *";
    public string GetByReferenceType(string elementType)    => elementType + " *";

    /* Function-pointer typedefs. winmd uses these for callback
       parameters (LPTHREAD_START_ROUTINE, WNDPROC, PIO_APC_ROUTINE
       etc.). Phase 3 v3: emit a proper C function-pointer type
       inline -- "RetType (*)(Arg1, Arg2, ...)" -- so the FFI sees
       the real signature instead of an opaque void *. The cdef
       grammar accepts this anywhere a type is expected, including
       as a struct field type or a function parameter. */
    public string GetFunctionPointerType(MethodSignature<string> signature)
    {
        var ps = signature.ParameterTypes.Length == 0
            ? "void"
            : string.Join(", ", signature.ParameterTypes);
        return $"{signature.ReturnType} (*)({ps})";
    }

    public string GetGenericInstantiation(string genericType, ImmutableArray<string> typeArguments) => genericType;
    public string GetGenericMethodParameter(object? genericContext, int index) => "void *";
    public string GetGenericTypeParameter(object? genericContext, int index)   => "void *";
    public string GetModifiedType(string modifier, string unmodifiedType, bool isRequired) => unmodifiedType;
    public string GetPinnedType(string elementType)         => elementType;
    public string GetTypeFromSpecification(MetadataReader reader, object? genericContext, TypeSpecificationHandle handle, byte rawTypeKind) => "void *";
}
