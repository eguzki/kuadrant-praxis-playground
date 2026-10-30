#!/usr/bin/env bash
# Deploy offering P3 -- Praxis PPE quota/limitador plugin (token, standalone
# Limitador). Namespace: praxis-p3. Image: praxis-ai:quota (scripts/05-...-p3).
# Requires: the standalone Limitador (scripts/08), the JWT issuer
# (scripts/deploy-jwt-issuer.sh), and the shared upstream (scripts/03).
#   scripts/06-deploy-praxis-p3.sh
source "$(dirname "$0")/lib.sh"

require kubectl

ns="${PRAXIS_P3_NAMESPACE}"
dir="${CONFIG_DIR}/praxis/p3"

log "Deploying Praxis offering P3 (quota/limitador) into '${ns}'"
kc apply -f "${dir}/deployment.yaml"   # creates namespace + deployment
kc apply -f "${dir}/configmap.yaml"
kc apply -f "${dir}/service.yaml"

kc -n "${ns}" rollout restart deployment/praxis-ai
log "Waiting for P3 to be ready"
kc -n "${ns}" rollout status deployment/praxis-ai --timeout=300s

log "P3 ready. Access it with: test/port-forward.sh p3   (-> http://localhost:8083)"
