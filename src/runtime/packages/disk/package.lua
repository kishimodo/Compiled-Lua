return {
    name        = "disk",
    version     = "1.0",
    description = "Disk volume information, free space, geometry and SMART. Uses GetLogicalDriveStringsW + GetVolumeInformationW + GetDiskFreeSpaceExW + GetDriveTypeW for volumes, DeviceIoControl(IOCTL_DISK_GET_DRIVE_GEOMETRY_EX) for physical geometry, and SMART_RCV_DRIVE_DATA (best effort, usually admin-only) for attributes.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["disk"] = "init.lua",
    },
    requires        = { "windows" },
    requires_native = {},
}
