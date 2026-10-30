#!/usr/bin/env bash
# Deploy the standalone Limitador that offering P3 (quota/limitador) meters
# against, into the `llm` namespace. Idempotent.
#   scripts/08-deploy-limitador-standalone.sh
source "$(dirname "$0")/lib.sh"

require kubectl

log "Ensuring upstream namespace '${UPSTREAM_NAMESPACE}'"
kc apply -f "${CONFIG_DIR}/upstream/namespace.yaml"

log "Deploying standalone Limitador (HTTP /check + /report on :8080)"
kc apply -f "${CONFIG_DIR}/upstream/limitador-standalone.yaml"

log "Waiting for limitador-standalone to be ready"
kc -n "${UPSTREAM_NAMESPACE}" rollout status deployment/limitador-standalone --timeout=180s

log "Standalone Limitador ready: http://limitador-standalone.${UPSTREAM_NAMESPACE}.svc.cluster.local:8080"
