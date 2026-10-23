#!/usr/bin/env bash
# Deploy the single Istio-managed gateway and attach the HTTPRoute to the
# shared upstream. Requires the upstream (scripts/03) to exist.
source "$(dirname "$0")/lib.sh"

require kubectl

log "Deploying the Istio-managed gateway in '${GATEWAY_NAMESPACE}'"
kc apply -f "${CONFIG_DIR}/istio/istio-gateway.yaml"

# Istio auto-provisions a Deployment named "<gateway>-istio". We wait on that
# becoming Available rather than the gateway's Programmed condition: in kind
# there is no LoadBalancer, so the gateway Service external address stays
# pending (Programmed=False with AddressNotAssigned) even though the data plane
# is fully functional and reachable via port-forward.
log "Waiting for the gateway data plane (Istio auto-provisions it)"
kc -n "${GATEWAY_NAMESPACE}" wait deployment/ingress-gateway-istio \
  --for=create --timeout=120s 2>/dev/null || true
kc -n "${GATEWAY_NAMESPACE}" rollout status deployment/ingress-gateway-istio --timeout=300s
kc -n "${GATEWAY_NAMESPACE}" get gateway ingress-gateway -o \
  'jsonpath={range .status.conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}' || true
warn "External address is expected to be <pending> in kind (no LoadBalancer); use port-forward."

log "Attaching HTTPRoute (ingress-gateway -> shared upstream)"
kc apply -f "${CONFIG_DIR}/upstream/istio-httproute.yaml"
# HTTPRoute conditions live under status.parents[], which `kubectl wait` can't
# read, so poll the per-parent Accepted condition directly.
for _ in $(seq 1 24); do
  accepted="$(kc -n "${UPSTREAM_NAMESPACE}" get httproute llm-route \
    -o 'jsonpath={.status.parents[0].conditions[?(@.type=="Accepted")].status}' 2>/dev/null || true)"
  [ "${accepted}" = "True" ] && break
  sleep 5
done
kc -n "${UPSTREAM_NAMESPACE}" get httproute llm-route -o \
  'jsonpath={range .status.parents[0].conditions[*]}{.type}={.status} ({.reason}){"\n"}{end}' || true
[ "${accepted:-}" = "True" ] || warn "HTTPRoute not Accepted yet; check: kubectl -n ${UPSTREAM_NAMESPACE} get httproute llm-route -o yaml"

log "Istio gateway ready. Access it with: test/port-forward.sh istio"
