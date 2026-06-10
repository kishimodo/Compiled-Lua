return {
    name        = "email_validate",
    version     = "1.0",
    description = "Email address validation. Practical RFC 5322 subset (local-part chars, dot rules, length caps, domain labels with hyphen rules, IDNA-ish), optional DNS MX lookup via the `dns` package, disposable-email detection against a curated provider list, and plus-addressing parsing (gmail-style local+tag@domain). `parse()` returns {local, plus_tag, domain}; `normalize()` lowercases and strips +tag for gmail-family domains.",
    license     = "MIT",
    main        = "init.lua",
    modules     = {
        ["email_validate"] = "init.lua",
    },
    requires        = { "dns" },
    requires_native = {},
}
