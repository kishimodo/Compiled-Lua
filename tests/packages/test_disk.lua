-- tests/packages/test_disk.lua : volume / physical-drive enumeration, SMART.
-- Determinism: drive letters, sizes, serials and SMART data vary per host, so
-- we assert structural invariants (shape, type, enum membership) and arithmetic
-- relationships (free <= total) rather than fixed values. The C: volume exists
-- on every Windows host and is "fixed", which gives us one concrete anchor.
local ok_req, disk = pcall(require, "disk")
if not ok_req then
    print("[~] SKIP test_disk (" .. tostring(disk) .. ")")
    os.exit(0)
end

local fails = 0
local function ok(c, m) if not c then fails = fails + 1; print("[-] FAIL test_disk: " .. tostring(m)) end end

ok(type(disk.volumes) == "function",        "volumes is a function")
ok(type(disk.free_space) == "function",     "free_space is a function")
ok(type(disk.drive_type) == "function",     "drive_type is a function")
ok(type(disk.physical_drives) == "function","physical_drives is a function")
ok(type(disk.smart) == "function",          "smart is a function")

-- ===== drive_type ==========================================================
local VALID_TYPES = {
    unknown=true, no_root=true, removable=true, fixed=true,
    network=true, cdrom=true, ramdisk=true,
}
local ct = disk.drive_type("C:\\")
ok(VALID_TYPES[ct],                         "drive_type('C:\\') is a known enum value")
ok(ct == "fixed",                           "drive_type('C:\\') is 'fixed'")
-- A bogus path returns a benign enum ("unknown"/"no_root"), never throws.
local bogus = disk.drive_type("Q:\\")
ok(VALID_TYPES[bogus],                       "drive_type(bogus) returns a valid enum, no throw")

-- ===== free_space ==========================================================
local fs = disk.free_space("C:\\")
ok(type(fs) == "table",                     "free_space('C:\\') returns a table")
ok(type(fs.total_bytes) == "number" and fs.total_bytes > 0, "C: total_bytes > 0")
ok(type(fs.free_bytes) == "number",         "C: free_bytes is a number")
ok(type(fs.available_bytes) == "number",    "C: available_bytes is a number")
ok(fs.free_bytes >= 0,                      "C: free_bytes non-negative")
ok(fs.free_bytes <= fs.total_bytes,         "C: free <= total")
ok(fs.available_bytes <= fs.total_bytes,    "C: available <= total")

-- ===== volumes =============================================================
local vols = disk.volumes()
ok(type(vols) == "table",                   "volumes() returns a table")
ok(#vols >= 1,                              "at least one volume present")
-- Locate the C: volume and validate its shape.
local cvol
for _, v in ipairs(vols) do
    ok(type(v.root) == "string" and #v.root >= 2, "volume has a root path string")
    ok(VALID_TYPES[v.drive_type],           "volume drive_type is a valid enum")
    if v.root:upper():sub(1,2) == "C:" then cvol = v end
end
ok(cvol ~= nil,                             "C: volume found in volumes()")
if cvol then
    ok(cvol.drive_type == "fixed",          "C: volume reports 'fixed'")
    if cvol.total_gb ~= nil then
        ok(cvol.total_gb > 0,               "C: total_gb > 0")
        ok(cvol.free_gb <= cvol.total_gb,   "C: free_gb <= total_gb")
        -- fs_type should be present for a fixed mounted volume.
        ok(type(cvol.fs_type) == "string",  "C: fs_type is a string")
        ok(type(cvol.serial) == "string" and #cvol.serial == 8,
                                            "C: serial is 8 hex chars")
        ok(cvol.serial:match("^%x+$") ~= nil, "C: serial is hex")
    end
end

-- ===== physical_drives (best-effort; needs no admin for geometry) ==========
local pds = disk.physical_drives()
ok(type(pds) == "table",                    "physical_drives() returns a table")
local pd_ok = true
for _, d in ipairs(pds) do
    if type(d.index) ~= "number" then pd_ok = false end
    if d.size_gb ~= nil and (type(d.size_gb) ~= "number" or d.size_gb <= 0) then pd_ok = false end
    if d.sector_size ~= nil and (type(d.sector_size) ~= "number" or d.sector_size <= 0) then pd_ok = false end
end
ok(pd_ok,                                   "physical drives have valid index/size/sector fields")

-- ===== smart (admin-only; just assert nil-or-table, never throws) ==========
local sm_ok, sm = pcall(disk.smart, 0)
ok(sm_ok,                                   "smart(0) does not throw")
if sm_ok then
    ok(sm == nil or type(sm) == "table",    "smart(0) returns nil or a table")
    if type(sm) == "table" then
        ok(type(sm.attributes) == "table",  "smart.attributes is a table when present")
        ok(sm.health == "ok" or sm.health == "failing", "smart.health is a known value")
    end
end

if fails == 0 then print("[+] PASS test_disk") os.exit(0) else os.exit(1) end
