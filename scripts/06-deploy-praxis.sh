#!/usr/bin/env bash
# Deploy the Praxis AI gateway (ConfigMap + Deployment + Service) into the
# praxis-gateway namespace. Requires the image built by scripts/05 and the
# shared upstream from scripts/03.
source "$(dirname "$0")/lib.sh"

require kubectl

log "Deploying Praxis AI gateway into '${PRAXIS_NAMESPACE}'"
kc apply -f "${CONFIG_DIR}/praxis/deployment.yaml"   # creates namespace + deployment
kc apply -f "${CONFIG_DIR}/praxis/configmap.yaml"
kc apply -f "${CONFIG_DIR}/praxis/service.yaml"

# Re-apply the deployment last so it picks up the configmap, then restart to be safe.
kc -n "${PRAXIS_NAMESPACE}" rollout restart deployment/praxis-ai

log "Waiting for the Praxis AI gateway to be ready"
kc -n "${PRAXIS_NAMESPACE}" rollout status deployment/praxis-ai --timeout=300s

log "Praxis gateway ready. Access it with: test/port-forward.sh praxis"
