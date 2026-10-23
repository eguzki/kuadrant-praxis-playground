#!/usr/bin/env bash
# Create (or recreate) the kind cluster used by the playground.
source "$(dirname "$0")/lib.sh"

require kind kubectl "${CONTAINER_ENGINE}"

if kind get clusters 2>/dev/null | grep -qx "${KIND_CLUSTER_NAME}"; then
  log "kind cluster '${KIND_CLUSTER_NAME}' already exists; skipping create (use scripts/cleanup.sh to delete)"
else
  log "Creating kind cluster '${KIND_CLUSTER_NAME}' (node image ${KIND_NODE_IMAGE})"
  KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_ENGINE}" kind create cluster \
    --name "${KIND_CLUSTER_NAME}" \
    --image "${KIND_NODE_IMAGE}" \
    --config "${CONFIG_DIR}/kind/kind-config.yaml"
fi

kc cluster-info
log "Cluster ready. kube-context: $(kctx)"
