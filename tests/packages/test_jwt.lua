-- Regression test for the builtin `jwt` package (HS256 verifier correctness).
--
-- jwt.encode(claims, key, algo)       -> token
-- jwt.decode(token, key, algo, opts?) -> claims | (nil, err)
--
-- The verifier is the security-critical surface, so the assertions below all
-- pin known-correct behavior: a good token verifies, and every tampered /
-- mismatched / downgraded variant is REJECTED (decode returns nil + err).

local ok_req, jwt = pcall(require, "jwt")
if not ok_req then print("[~] SKIP test_jwt") os.exit(0) end

local fails = 0
local function ok(c, m)
    if not c then fails = fails + 1; print("[-] FAIL test_jwt: " .. tostring(m)) end
end

local KEY  = "super-secret-hs256-key"
local ALGO = "HS256"

-- Use far-future exp / past iat so claim-time checks never interfere with the
-- signature-correctness checks we actually care about here.
local claims = {
    sub  = "user-42",
    name = "Ada Lovelace",
    role = "admin",
    iat  = 1000000000,   -- 2001-09-09, comfortably in the past
    exp  = 4102444800,   -- 2100-01-01, comfortably in the future
}

-- ===== 1. Valid HS256 round-trip recovers the claims =====================
local token = jwt.encode(claims, KEY, ALGO)
ok(type(token) == "string", "encode should return a string token")

-- A JWT is exactly three base64url segments joined by dots.
local dots = select(2, token:gsub("%.", ""))
ok(dots == 2, "token should have exactly two '.' separators, got " .. tostring(dots))

local decoded, derr = jwt.decode(token, KEY, ALGO)
ok(decoded ~= nil, "valid token should decode, got err=" .. tostring(derr))
if decoded then
    ok(decoded.sub  == "user-42",      "sub claim should round-trip")
    ok(decoded.name == "Ada Lovelace", "name claim should round-trip")
    ok(decoded.role == "admin",        "role claim should round-trip")
    ok(decoded.iat  == 1000000000,     "iat claim should round-trip")
    ok(decoded.exp  == 4102444800,     "exp claim should round-trip")
end

-- jwt.verify is documented as an alias of jwt.decode.
ok(jwt.verify == jwt.decode, "jwt.verify should be an alias of jwt.decode")

-- ===== 2. Header alg must match the expected algorithm ===================
-- Token was minted as HS256; asking the verifier to expect HS512 must fail
-- on the alg mismatch (never silently accept the header's own claim).
local d2, e2 = jwt.decode(token, KEY, "HS512")
ok(d2 == nil, "alg-mismatch token must be rejected")
ok(e2 ~= nil, "alg-mismatch rejection should return an error message")

-- ===== 3. alg "none" must be rejected unless explicitly allowed ==========
-- Classic JWT downgrade attack: re-sign the claims with alg "none".
local none_token = jwt.encode(claims, KEY, "none")
local d3, e3 = jwt.decode(none_token, KEY, "none")
ok(d3 == nil, "'none' algorithm must be rejected by default")
ok(e3 ~= nil, "'none' rejection should return an error message")
-- And when explicitly allowed it must decode (proves the rejection above was
-- the 'none' guard, not some unrelated failure).
local d3b = jwt.decode(none_token, KEY, "none", { allow_none = true })
ok(d3b ~= nil and d3b.sub == "user-42", "'none' should decode only with allow_none")

-- ===== 4. Empty / stripped signature must be rejected ====================
-- Take the valid token and drop its signature segment (keep the trailing dot).
local h, p = token:match("^([^%.]+)%.([^%.]+)%.")
ok(h ~= nil and p ~= nil, "should be able to split header.payload")
local stripped = h .. "." .. p .. "."
local d4, e4 = jwt.decode(stripped, KEY, ALGO)
ok(d4 == nil, "stripped-signature token must be rejected")
ok(e4 ~= nil, "stripped-signature rejection should return an error message")

-- ===== 5. Tampered payload must be rejected ==============================
-- Re-encode the payload with an escalated claim but keep the original HS256
-- signature -- the MAC no longer covers the new payload, so it must fail.
local forged_payload = jwt.b64url_encode('{"sub":"user-42","role":"superadmin"}')
local orig_sig = token:match("%.([^%.]+)$")
ok(orig_sig ~= nil, "should be able to extract the original signature")
local tampered = h .. "." .. forged_payload .. "." .. orig_sig
local d5, e5 = jwt.decode(tampered, KEY, ALGO)
ok(d5 == nil, "tampered-payload token must be rejected")
ok(e5 ~= nil, "tampered-payload rejection should return an error message")

-- ===== 6. Wrong key must be rejected ====================================
local d6, e6 = jwt.decode(token, "the-wrong-key", ALGO)
ok(d6 == nil, "token verified with the wrong key must be rejected")
ok(e6 ~= nil, "wrong-key rejection should return an error message")

if fails == 0 then print("[+] PASS test_jwt") os.exit(0) else os.exit(1) end
