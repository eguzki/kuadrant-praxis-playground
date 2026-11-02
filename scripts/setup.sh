#!/usr/bin/env bash
# Full playground setup, in order — stands up all six rate-limiting offerings over
# the shared upstream. Each step is idempotent and can also be run on its own.
#
# The slow part is the Praxis image builds (05*, Rust compile): THREE of them —
# praxis-ai:dev (P1+P2), :quota (P3), :ratelimit (P4). The P3/P4 builds are
# from-source PPE-plugin spikes (vendored/patched engine + core); they are run
# best-effort here, so a build that fails on a given host warns and setup
# continues with the rest (the base playground still comes up).
source "$(dirname "$0")/lib.sh"

# Best-effort wrapper for the PPE-plugin spikes (P3/P4): warn and keep going on
# failure instead of aborting the whole setup (set -e is from lib.sh).
run_spike() {
  local desc="$1"; shift
  if "$@"; then
    return 0
  fi
  warn "spike step failed (continuing): ${desc}"
  return 0
}

log "=== kuadrant-praxis-playground setup ==="
log "cluster=${KIND_CLUSTER_NAME} kuadrant=${KUADRANT_VERSION} istio=${ISTIO_VERSION} engine=${CONTAINER_ENGINE}"

# --- cluster + shared infra --------------------------------------------------
"${SCRIPT_DIR}/00-create-cluster.sh"
"${SCRIPT_DIR}/01-install-istio.sh"
"${SCRIPT_DIR}/02-install-kuadrant.sh"
"${SCRIPT_DIR}/03-deploy-upstream.sh"
"${SCRIPT_DIR}/deploy-jwt-issuer.sh"
"${SCRIPT_DIR}/04-deploy-istio-gateway.sh"

# --- P1 + P2 (base image praxis-ai:dev) --------------------------------------
"${SCRIPT_DIR}/05-build-praxis-image.sh"
"${SCRIPT_DIR}/06-deploy-praxis-p1.sh"
"${SCRIPT_DIR}/06-deploy-praxis-p2.sh"

# --- P3 quota/limitador (PPE spike; token, standalone Limitador) -------------
run_spike "P3 image (praxis-ai:quota)"       "${SCRIPT_DIR}/05-build-praxis-image-p3.sh"
"${SCRIPT_DIR}/08-deploy-limitador-standalone.sh"
run_spike "P3 deploy (quota/limitador)"      "${SCRIPT_DIR}/06-deploy-praxis-p3.sh"

# --- P4 ratelimit/limitador (PPE spike; request-count, embedded + #1478 host) -
run_spike "P4 image (praxis-ai:ratelimit)"   "${SCRIPT_DIR}/05-build-praxis-image-p4.sh"
run_spike "P4 deploy (ratelimit/limitador)"  "${SCRIPT_DIR}/06-deploy-praxis-p4.sh"

# --- Kuadrant arm: K-TRLP (AuthPolicy + TokenRateLimitPolicy) -----------------
"${SCRIPT_DIR}/07-deploy-kuadrant-policies.sh"

log "=== setup complete ==="
cat <<EOF

All offerings over the shared upstream (ns llm). Port-forward one per terminal,
then send requests with a per-tier token from .cache/tokens/:

  # Praxis offerings (one local port each):
  ./test/port-forward.sh p1            # -> http://localhost:8081  P1 rate_limit (request-count)
  ./test/port-forward.sh p2            # -> http://localhost:8082  P2 token_rate_limit (native)
  ./test/port-forward.sh p3            # -> http://localhost:8083  P3 quota/limitador (standalone)
  ./test/port-forward.sh p4            # -> http://localhost:8084  P4 ratelimit/limitador (embedded)
  # Kuadrant arm on the Istio gateway:
  ./test/port-forward.sh istio         # -> http://localhost:8080  K-TRLP TokenRateLimitPolicy

  # Exercises (watch 200 -> 429):
  BASE_URL=http://localhost:8082 ./test/test-token-rate-limit.sh   # P2
  ./test/test-p4-ratelimit.sh                                      # P4 (needs p4 forward)
  ./test/test-k-trlp.sh                                            # K-TRLP (needs istio forward)

See CLAUDE.md "Live-validation findings (issue #200)" for the per-offering M1-M7 results.

Tear down:
  ./scripts/cleanup.sh
EOF
