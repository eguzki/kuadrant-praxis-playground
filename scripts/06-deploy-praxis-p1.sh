#!/usr/bin/env bash
# Deploy offering P1 -- Praxis core `rate_limit` filter (request-count).
# Namespace: praxis-p1. Image: praxis-ai:dev (scripts/05). Upstream: scripts/03.
#   scripts/06-deploy-praxis-p1.sh
source "$(dirname "$0")/lib.sh"

require kubectl

ns="${PRAXIS_P1_NAMESPACE}"
dir="${CONFIG_DIR}/praxis/p1"

log "Deploying Praxis offering P1 (rate_limit) into '${ns}'"
kc apply -f "${dir}/deployment.yaml"   # creates namespace + deployment
kc apply -f "${dir}/configmap.yaml"
kc apply -f "${dir}/service.yaml"

kc -n "${ns}" rollout restart deployment/praxis-ai
log "Waiting for P1 to be ready"
kc -n "${ns}" rollout status deployment/praxis-ai --timeout=300s

log "P1 ready. Access it with: test/port-forward.sh p1   (-> http://localhost:8081)"
