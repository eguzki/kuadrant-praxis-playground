#!/usr/bin/env bash
# Deploy the shared upstream backends (llm-d-inference-sim + MockServer) into
# the `llm` namespace. Shared by both the Istio gateway and the Praxis gateway.
source "$(dirname "$0")/lib.sh"

require kubectl

log "Creating upstream namespace '${UPSTREAM_NAMESPACE}'"
kc apply -f "${CONFIG_DIR}/upstream/namespace.yaml"

log "Creating MockServer expectations ConfigMap"
kc -n "${UPSTREAM_NAMESPACE}" create configmap mockserver-expectations \
  --from-file=expectations.json="${CONFIG_DIR}/upstream/mockserver-expectations.json" \
  --dry-run=client -o yaml | kc apply -f -

log "Deploying llm-d-inference-sim (OpenAI-compatible, returns token usage)"
kc apply -f "${CONFIG_DIR}/upstream/llm-d-inference-sim.yaml"

log "Deploying MockServer (Anthropic/Gemini shapes)"
kc apply -f "${CONFIG_DIR}/upstream/mockserver.yaml"

log "Waiting for upstream deployments"
kc -n "${UPSTREAM_NAMESPACE}" rollout status deployment/llm-d-inference-sim --timeout=300s
kc -n "${UPSTREAM_NAMESPACE}" rollout status deployment/mock-llm --timeout=300s

log "Shared upstream ready in namespace '${UPSTREAM_NAMESPACE}'"
