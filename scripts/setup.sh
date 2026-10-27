#!/usr/bin/env bash
# Full playground setup, in order. Each step is idempotent and can also be run
# on its own. The Praxis image build (step 05) is the slow part (Rust compile).
source "$(dirname "$0")/lib.sh"

log "=== kuadrant-praxis-playground setup ==="
log "cluster=${KIND_CLUSTER_NAME} kuadrant=${KUADRANT_VERSION} istio=${ISTIO_VERSION} engine=${CONTAINER_ENGINE}"

"${SCRIPT_DIR}/00-create-cluster.sh"
"${SCRIPT_DIR}/01-install-istio.sh"
"${SCRIPT_DIR}/02-install-kuadrant.sh"
"${SCRIPT_DIR}/03-deploy-upstream.sh"
"${SCRIPT_DIR}/deploy-jwt-issuer.sh"
"${SCRIPT_DIR}/04-deploy-istio-gateway.sh"
"${SCRIPT_DIR}/05-build-praxis-image.sh"
"${SCRIPT_DIR}/06-deploy-praxis-p1.sh"
"${SCRIPT_DIR}/06-deploy-praxis-p2.sh"
# P3/P4 (PPE plugins) and the Kuadrant policy arm are added in later phases.

log "=== setup complete ==="
cat <<EOF

Next steps:
  # Port-forward a gateway (one local port each), then send requests:
  ./test/port-forward.sh p1            # -> http://localhost:8081  (P1 rate_limit)
  ./test/port-forward.sh p2            # -> http://localhost:8082  (P2 token_rate_limit)
  ./test/port-forward.sh istio         # -> http://localhost:8080  (Istio gateway)

  BASE_URL=http://localhost:8082 ./test/test-token-rate-limit.sh   # P2: 200 -> 429

Tear down:
  ./scripts/cleanup.sh
EOF
