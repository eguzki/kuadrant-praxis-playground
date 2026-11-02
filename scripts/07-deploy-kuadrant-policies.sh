#!/usr/bin/env bash
# Deploy the Kuadrant K-TRLP arm on the Istio gateway's HTTPRoute (llm-route):
#   - AuthPolicy (JWT via static JWKS)        config/kuadrant/authpolicy.yaml
#   - TokenRateLimitPolicy (tiered tokens)    config/kuadrant/tokenratelimitpolicy.yaml
#
# Requires: Kuadrant (scripts/02), the Istio gateway + HTTPRoute (scripts/04),
# the shared upstream (scripts/03), and the JWT issuer (scripts/deploy-jwt-issuer).
#   scripts/07-deploy-kuadrant-policies.sh
source "$(dirname "$0")/lib.sh"

require kubectl

dir="${CONFIG_DIR}/kuadrant"

log "Applying AuthPolicy (JWT) + TokenRateLimitPolicy to llm-route"
kc apply -f "${dir}/authpolicy.yaml"
kc apply -f "${dir}/tokenratelimitpolicy.yaml"

# Both policies report readiness via their `Enforced` condition (Kuadrant sets it
# once the wasm/auth config is programmed into the gateway).
for pol in "authpolicy/llm-jwt" "tokenratelimitpolicy/llm-tokens"; do
  log "Waiting for ${pol} to be Enforced"
  kc -n "${UPSTREAM_NAMESPACE}" wait "${pol}" --for=condition=Enforced --timeout=120s 2>&1 || \
    warn "${pol} not Enforced yet; check: kc -n ${UPSTREAM_NAMESPACE} describe ${pol}"
done

log "K-TRLP ready. Port-forward the gateway (test/port-forward.sh istio) and run test/test-k-trlp.sh"
