#!/usr/bin/env bash
# Port-forward a gateway to localhost:8080 (foreground; Ctrl-C to stop).
#   ./test/port-forward.sh praxis   # Praxis AI gateway (praxis-gateway ns)
#   ./test/port-forward.sh istio    # Istio-managed gateway (ingress-gateway ns)
source "$(dirname "$0")/../scripts/lib.sh"

require kubectl

target="${1:-praxis}"
local_port="${LOCAL_PORT:-8080}"

case "${target}" in
  praxis)
    log "Port-forwarding Praxis AI gateway -> http://localhost:${local_port}"
    kc -n "${PRAXIS_NAMESPACE}" port-forward svc/praxis-ai "${local_port}:8080"
    ;;
  istio)
    svc="$(kc -n "${GATEWAY_NAMESPACE}" get svc -l gateway.networking.k8s.io/gateway-name=ingress-gateway -o name | head -1)"
    if [ -z "${svc}" ]; then
      err "Istio gateway service not found in ${GATEWAY_NAMESPACE}"
      exit 1
    fi
    log "Port-forwarding Istio gateway (${svc}) -> http://localhost:${local_port}"
    kc -n "${GATEWAY_NAMESPACE}" port-forward "${svc}" "${local_port}:80"
    ;;
  *)
    err "unknown target '${target}' (use: praxis | istio)"
    exit 1
    ;;
esac
