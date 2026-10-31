#!/usr/bin/env bash
# Deploy the static-JWKS JWT test issuer into the `llm` namespace and mint the
# per-tier test tokens. Idempotent. Requires the upstream namespace (scripts/03).
#
#   scripts/deploy-jwt-issuer.sh
#
# Tokens are written to ${CACHE_DIR}/tokens/{gold,silver,enterprise,basic,notier}.jwt
# and the signing key stays local in ${CACHE_DIR}/jwt (gitignored).
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/lib-jwt.sh"

require kubectl openssl

log "Generating RSA keypair, JWKS, and test tokens"
jwt_mint_all

log "Ensuring upstream namespace '${UPSTREAM_NAMESPACE}' exists"
kc apply -f "${CONFIG_DIR}/upstream/namespace.yaml"

log "Publishing JWKS ConfigMap 'jwt-issuer-jwks'"
kc -n "${UPSTREAM_NAMESPACE}" create configmap jwt-issuer-jwks \
  --from-file=jwks.json="${JWT_JWKS_FILE}" \
  --dry-run=client -o yaml | kc apply -f -

log "Deploying jwt-issuer (static JWKS server)"
kc apply -f "${CONFIG_DIR}/upstream/jwt-issuer.yaml"

log "Waiting for jwt-issuer to be ready"
kc -n "${UPSTREAM_NAMESPACE}" rollout status deployment/jwt-issuer --timeout=180s

log "JWT issuer ready. JWKS: ${JWT_JWKS_URL}"
log "  tokens: ${JWT_TOKENS_DIR}/{gold,silver,enterprise,basic,notier}.jwt"
