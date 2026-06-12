/*
** protoblob_format.h — the serialized ProtoInit blob format (LCPB v1).
**
** Shared between the compiler-side serializer (src/codegen/protoblob_emit.c)
** and the runtime-side deserializer (src/runtime/protoinit_rt.c). The blob
** replaces the generated ProtoInit C of M0: instead of emitting C that gcc
** must compile at user-build time, aotc serializes every reachable Proto's
** constants/upvalues/debug-info/code into this byte format, the COFF writer
** places it in .rdata as `luac_protoblob` next to a relocated function-pointer
** table `luac_fn_table`, and LuacProgram_BuildEntry (protoinit_rt.c, compiled
** once into the runtime archive) reconstructs the Protos at startup.
**
** The deserializer's ALLOCATION ORDER deliberately mirrors the old generated
** C exactly (field-for-field, luaS_newlstr/luaM_newvector call-for-call) so
** heap/GC behavior of compiled programs is unchanged.
**
** Layout (all little-endian, counts before payloads, no alignment padding —
** the reader uses memcpy):
**
**   header:
**     u32 magic   = LCPB_MAGIC
**     u32 version = LCPB_VERSION
**     u32 total_len            (whole blob, bounds-checks every read)
**     u32 nfuncs
**     u32 entry_idx
**   u32 func_off[nfuncs]       (record offsets from blob start)
**   u8  is_root[nfuncs]        (1 = not nested under another Proto's p[])
**   per-function records (at func_off[i]):
**     u8  numparams, u8 is_vararg, u8 maxstacksize, u8 has_source
**     i32 linedefined, i32 lastlinedefined
**     [u32 srclen + bytes]                       (if has_source)
**     u32 sizelineinfo  + raw ls_byte bytes
**     u32 sizeabslineinfo + { i32 pc, i32 line }[]
**     u32 sizek + entries: u8 tag, then
**         LCPB_K_INT: i64 (lua_Integer bits)   LCPB_K_FLT: f64 (raw bits)
**         LCPB_K_STR: u32 len + bytes           (nil/false/true: no payload)
**     u32 sizeupvalues + { u8 instack, u8 idx, u8 kind, u8 has_name
**                          [u32 len + bytes] }[]
**     u32 sizep + u32 child_idx[]               (recursive build by index)
**     u32 sizecode + raw Instruction bytes (sizecode * 4)
**     u32 sizelocvars + { i32 startpc, i32 endpc, u8 has_name
**                         [u32 len + bytes] }[]
**     u8  has_module_name [u32 len + bytes]     (preload registration name)
*/
#ifndef LUAC_PROTOBLOB_FORMAT_H
#define LUAC_PROTOBLOB_FORMAT_H

#define LCPB_MAGIC   0x4250434Cu   /* "LCPB" read as little-endian u32 */
#define LCPB_VERSION 1u

enum {
    LCPB_K_NIL   = 0,
    LCPB_K_FALSE = 1,
    LCPB_K_TRUE  = 2,
    LCPB_K_INT   = 3,
    LCPB_K_FLT   = 4,
    LCPB_K_STR   = 5
};

/* Symbols the COFF writer defines in the user object: */
#define LCPB_SYM_BLOB     "luac_protoblob"
#define LCPB_SYM_FNTABLE  "luac_fn_table"

#endif /* LUAC_PROTOBLOB_FORMAT_H */
