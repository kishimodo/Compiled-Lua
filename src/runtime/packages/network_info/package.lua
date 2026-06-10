return {
    name        = "network_info",
    version     = "1.0",
    description = "Network adapter / IP / routing / ARP enumeration via iphlpapi. GetAdaptersAddresses for adapter detail (IPs, gateway, DNS, DHCP, link speed, MTU), GetIpForwardTable2 for the routing table, GetIpNetTable2 for the ARP / neighbor cache.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["network_info"] = "init.lua",
    },
    requires        = { "windows", "windows.network" },
    requires_native = {},
}
