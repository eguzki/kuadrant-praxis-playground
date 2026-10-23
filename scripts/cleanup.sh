#!/usr/bin/env bash
# Delete the kind cluster (removes everything). Add --image to also remove the
# locally-built Praxis image.
source "$(dirname "$0")/lib.sh"

require kind

log "Deleting kind cluster '${KIND_CLUSTER_NAME}'"
KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_ENGINE}" kind delete cluster --name "${KIND_CLUSTER_NAME}" || true

if [ "${1:-}" = "--image" ]; then
  log "Removing local image ${PRAXIS_AI_IMAGE}"
  "${CONTAINER_ENGINE}" rmi "${PRAXIS_AI_IMAGE}" 2>/dev/null || true
fi

log "Cleanup done"
