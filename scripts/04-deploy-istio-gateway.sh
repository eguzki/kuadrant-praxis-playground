#!/usr/bin/env bash
# Deploy the single Istio-managed gateway and attach the HTTPRoute to the
# shared upstream. Requires the upstream (scripts/03) to exist.
source "$(dirname "$0")/lib.sh"

require kubectl

log "Deploying the Istio-managed gateway in '${GATEWAY_NAMESPACE}'"
kc apply -f "${CONFIG_DIR}/istio/istio-gateway.yaml"

log "Waiting for the gateway to be Programmed (Istio auto-provisions the data plane)"
kc -n "${GATEWAY_NAMESPACE}" wait gateway/ingress-gateway --for=condition=Programmed --timeout=300s

log "Attaching HTTPRoute (ingress-gateway -> shared upstream)"
kc apply -f "${CONFIG_DIR}/upstream/istio-httproute.yaml"
kc -n "${UPSTREAM_NAMESPACE}" wait httproute/llm-route --for=condition=Accepted --timeout=120s || \
  warn "HTTPRoute not Accepted yet; check: kubectl -n ${UPSTREAM_NAMESPACE} get httproute llm-route -o yaml"

log "Istio gateway ready. Access it with: test/port-forward.sh istio"
