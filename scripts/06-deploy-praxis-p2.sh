#!/usr/bin/env bash
# Deploy offering P2 -- Praxis `token_rate_limit` filter (token, native).
# Namespace: praxis-p2. Image: praxis-ai:dev (scripts/05). Upstream: scripts/03.
#   scripts/06-deploy-praxis-p2.sh
source "$(dirname "$0")/lib.sh"

require kubectl

ns="${PRAXIS_P2_NAMESPACE}"
dir="${CONFIG_DIR}/praxis/p2"

log "Deploying Praxis offering P2 (token_rate_limit) into '${ns}'"
kc apply -f "${dir}/deployment.yaml"   # creates namespace + deployment
kc apply -f "${dir}/configmap.yaml"
kc apply -f "${dir}/service.yaml"

kc -n "${ns}" rollout restart deployment/praxis-ai
log "Waiting for P2 to be ready"
kc -n "${ns}" rollout status deployment/praxis-ai --timeout=300s

log "P2 ready. Access it with: test/port-forward.sh p2   (-> http://localhost:8082)"
