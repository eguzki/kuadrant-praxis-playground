#!/usr/bin/env bash
# Deploy offering P4 -- Praxis PPE ratelimit/limitador plugin (request-count,
# embedded in-memory Limitador). Namespace: praxis-p4. Image: praxis-ai:ratelimit
# (scripts/05-build-praxis-image-p4.sh).
# Requires: the JWT issuer (scripts/deploy-jwt-issuer.sh) and the shared upstream
# (scripts/03). No standalone Limitador is needed (counters are in-process).
#   scripts/06-deploy-praxis-p4.sh
source "$(dirname "$0")/lib.sh"

require kubectl

ns="${PRAXIS_P4_NAMESPACE}"
dir="${CONFIG_DIR}/praxis/p4"

log "Deploying Praxis offering P4 (ratelimit/limitador) into '${ns}'"
kc apply -f "${dir}/deployment.yaml"   # creates namespace + deployment
kc apply -f "${dir}/configmap.yaml"
kc apply -f "${dir}/service.yaml"

kc -n "${ns}" rollout restart deployment/praxis-ai
log "Waiting for P4 to be ready"
kc -n "${ns}" rollout status deployment/praxis-ai --timeout=300s

log "P4 ready. Access it with: test/port-forward.sh p4   (-> http://localhost:8084)"
