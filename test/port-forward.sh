#!/usr/bin/env bash
# Port-forward a gateway to a dedicated localhost port (foreground; Ctrl-C to
# stop). One port per gateway, so several can run at once in separate terminals:
#
#   ./test/port-forward.sh p1      # P1 rate_limit          -> http://localhost:8081
#   ./test/port-forward.sh p2      # P2 token_rate_limit    -> http://localhost:8082
#   ./test/port-forward.sh p3      # P3 quota/limitador     -> http://localhost:8083
#   ./test/port-forward.sh p4      # P4 ratelimit/limitador -> http://localhost:8084
#   ./test/port-forward.sh istio   # Istio gateway          -> http://localhost:8080
#
# Override the local port with LOCAL_PORT=... if a port is taken.
source "$(dirname "$0")/../scripts/lib.sh"

require kubectl

target="${1:-p2}"

case "${target}" in
  p1|p2|p3|p4)
    ns="praxis-${target}"
    default_port="80${target#p}"   # p1->8081 p2->8082 p3->8083 p4->8084
    local_port="${LOCAL_PORT:-${default_port}}"
    log "Port-forwarding Praxis ${target} (${ns}) -> http://localhost:${local_port}"
    kc -n "${ns}" port-forward svc/praxis-ai "${local_port}:8080"
    ;;
  istio)
    local_port="${LOCAL_PORT:-8080}"
    svc="$(kc -n "${GATEWAY_NAMESPACE}" get svc -l gateway.networking.k8s.io/gateway-name=ingress-gateway -o name | head -1)"
    if [ -z "${svc}" ]; then
      err "Istio gateway service not found in ${GATEWAY_NAMESPACE}"
      exit 1
    fi
    log "Port-forwarding Istio gateway (${svc}) -> http://localhost:${local_port}"
    kc -n "${GATEWAY_NAMESPACE}" port-forward "${svc}" "${local_port}:80"
    ;;
  *)
    err "unknown target '${target}' (use: p1 | p2 | p3 | p4 | istio)"
    exit 1
    ;;
esac
