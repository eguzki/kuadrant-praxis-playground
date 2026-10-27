#!/usr/bin/env bash
# JWT test-issuer helpers (static JWKS, RS256) for the acceptance tests.
#
# Generates an RSA keypair + a JWKS document and mints long-lived test tokens
# carrying a `tier` claim (gold / silver / enterprise) plus one with no tier.
# Everything is written under ${CACHE_DIR} (gitignored). Pure openssl — no
# python/pyjwt/step dependency.
#
# Source AFTER lib.sh:
#   source "$(dirname "$0")/lib.sh"
#   source "$(dirname "$0")/lib-jwt.sh"

# Guard: requires lib.sh variables.
: "${CACHE_DIR:?lib-jwt.sh requires lib.sh to be sourced first}"

JWT_DIR="${CACHE_DIR}/jwt"
JWT_TOKENS_DIR="${CACHE_DIR}/tokens"
JWT_PRIV_KEY="${JWT_DIR}/priv.pem"
JWT_JWKS_FILE="${JWT_DIR}/jwks.json"

# base64url (no padding), reading stdin.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Convert a hex string (stdin) to raw bytes on stdout (no xxd dependency).
# Command substitution strips the trailing newline before printf %b emits bytes,
# so no spurious 0x0a byte ends up in the output.
_hex_to_bin() {
  local hex escaped
  hex="$(cat)"
  escaped="$(printf '%s' "${hex}" | sed 's/../\\x&/g')"
  printf '%b' "${escaped}"
}

# Generate the RSA keypair + JWKS if not already present.
jwt_ensure_keys() {
  require openssl
  if [ -f "${JWT_PRIV_KEY}" ] && [ -f "${JWT_JWKS_FILE}" ]; then
    return 0
  fi
  mkdir -p "${JWT_DIR}"
  log "Generating RSA test keypair at ${JWT_PRIV_KEY}"
  openssl genrsa -out "${JWT_PRIV_KEY}" 2048 2>/dev/null

  # RSA public modulus -> base64url(n); exponent is F4 (65537) => "AQAB".
  local modulus_hex n
  modulus_hex="$(openssl rsa -in "${JWT_PRIV_KEY}" -noout -modulus 2>/dev/null | sed 's/^Modulus=//')"
  n="$(printf '%s' "${modulus_hex}" | _hex_to_bin | b64url)"

  log "Writing JWKS to ${JWT_JWKS_FILE} (kid=${JWT_KID})"
  cat > "${JWT_JWKS_FILE}" <<EOF
{
  "keys": [
    {
      "kty": "RSA",
      "use": "sig",
      "alg": "RS256",
      "kid": "${JWT_KID}",
      "n": "${n}",
      "e": "AQAB"
    }
  ]
}
EOF
}

# jwt_mint <sub> [tier]
# Prints a signed RS256 JWT. Omit tier to mint a token with no `tier` claim.
jwt_mint() {
  local sub="$1" tier="${2:-}"
  local header payload signing_input sig iat exp
  iat="$(date +%s)"
  exp="$((iat + 315360000))" # +10 years

  header="$(printf '{"alg":"RS256","typ":"JWT","kid":"%s"}' "${JWT_KID}" | b64url)"
  if [ -n "${tier}" ]; then
    payload="$(printf '{"iss":"%s","sub":"%s","aud":"%s","tier":"%s","iat":%s,"exp":%s}' \
      "${JWT_ISSUER}" "${sub}" "${JWT_AUDIENCE}" "${tier}" "${iat}" "${exp}" | b64url)"
  else
    payload="$(printf '{"iss":"%s","sub":"%s","aud":"%s","iat":%s,"exp":%s}' \
      "${JWT_ISSUER}" "${sub}" "${JWT_AUDIENCE}" "${iat}" "${exp}" | b64url)"
  fi
  signing_input="${header}.${payload}"
  sig="$(printf '%s' "${signing_input}" | openssl dgst -sha256 -sign "${JWT_PRIV_KEY}" -binary | b64url)"
  printf '%s.%s' "${signing_input}" "${sig}"
}

# Mint the standard set of test tokens into ${JWT_TOKENS_DIR}.
jwt_mint_all() {
  jwt_ensure_keys
  mkdir -p "${JWT_TOKENS_DIR}"
  jwt_mint "user-gold"       "gold"       > "${JWT_TOKENS_DIR}/gold.jwt"
  jwt_mint "user-silver"     "silver"     > "${JWT_TOKENS_DIR}/silver.jwt"
  jwt_mint "user-enterprise" "enterprise" > "${JWT_TOKENS_DIR}/enterprise.jwt"
  jwt_mint "user-notier"                  > "${JWT_TOKENS_DIR}/notier.jwt"
  log "Minted test tokens in ${JWT_TOKENS_DIR}: gold, silver, enterprise, notier"
}

# Convenience: echo a token for a tier (gold|silver|enterprise|notier), minting
# the set first if needed.
jwt_token() {
  local which="$1"
  [ -f "${JWT_TOKENS_DIR}/${which}.jwt" ] || jwt_mint_all >&2
  cat "${JWT_TOKENS_DIR}/${which}.jwt"
}
