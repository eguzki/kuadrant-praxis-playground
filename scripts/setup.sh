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
"${SCRIPT_DIR}/04-deploy-istio-gateway.sh"
"${SCRIPT_DIR}/05-build-praxis-image.sh"
"${SCRIPT_DIR}/06-deploy-praxis.sh"

log "=== setup complete ==="
cat <<EOF

Next steps:
  # Port-forward a gateway, then run the token rate limit test:
  ./test/port-forward.sh praxis        # -> http://localhost:8080  (Praxis AI gateway)
  ./test/port-forward.sh istio         # -> http://localhost:8080  (Istio gateway, pass-through)

  ./test/test-token-rate-limit.sh      # hammers the Praxis gateway, shows 200 -> 429

Tear down:
  ./scripts/cleanup.sh
EOF
