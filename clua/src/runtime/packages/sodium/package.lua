return {
    name        = "sodium",
    version     = "1.0",
    description = "libsodium modern cryptography bindings via libsodium.dll. Sub-namespaces: sodium.box (X25519 + XSalsa20-Poly1305 public-key authenticated encryption with keypair / encrypt / decrypt / seal / seal_open), sodium.sign (Ed25519 detached signatures), sodium.secretbox (XSalsa20-Poly1305 symmetric), sodium.aead (ChaCha20-Poly1305 + XChaCha20-Poly1305 AEAD), sodium.hash (BLAKE2b generichash + SHA-256/512), sodium.pwhash (Argon2id / Argon2i password hashing with str + str_verify), sodium.kx (X25519 key exchange yielding rx + tx session keys), sodium.utils (randombytes, hex2bin, bin2hex, constant-time memcmp). Auto-calls sodium_init() on first use. Loads libsodium.dll lazily from $CLUA_SODIUM_DLL or common names.",
    license     = "MIT (bindings), ISC (libsodium upstream)",
    main        = "init.lua",
    modules     = {
        ["sodium"] = "init.lua",
    },
    requires        = {},
    requires_native = {
        { dll = "libsodium.dll", mode_default = "embed", env_var = "CLUA_SODIUM_DLL" },
    },
}
