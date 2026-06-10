return {
    name        = "dns",
    version     = "0.1",
    description = "DNS resolver. Two paths: (1) system resolver via Windows DnsQuery_W (dnsapi.dll) for the fast common case, (2) pure protocol implementation that builds DNS queries, sends them via UDP/TCP/DoH/DoT, and parses RR types A / AAAA / MX / TXT / CNAME / SRV / PTR / NS / SOA / CAA. DNS-over-HTTPS via `http`, DNS-over-TLS via `tls_client`, plain DNS via `socket`.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["dns"] = "init.lua",
    },
    requires        = { "windows", "socket", "tls_client", "http" },
    requires_native = {},
}
