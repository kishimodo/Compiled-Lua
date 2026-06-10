return {
    name        = "smtp",
    version     = "0.1",
    description = "SMTP submission client (RFC 5321 + RFC 5322 message format). PLAIN / LOGIN auth, STARTTLS upgrade via `tls_client`, MIME multipart construction with text/html alternatives and attachments. Drives the conversation synchronously over `socket` and turns it into a single send(opts) call.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["smtp"] = "init.lua",
    },
    requires        = { "socket", "tls_client" },
    requires_native = {},
}
