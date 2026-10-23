#!/usr/bin/env bash
# Install the Kuadrant Operator (control plane) via Helm and bootstrap the
# Kuadrant CR (Limitador + Authorino).
source "$(dirname "$0")/lib.sh"

require helm kubectl

log "Installing Kuadrant Operator ${KUADRANT_VERSION} via Helm"
helm repo add kuadrant https://kuadrant.io/helm-charts/ --force-update >/dev/null
helm --kube-context "$(kctx)" upgrade --install kuadrant-operator kuadrant/kuadrant-operator \
  --version "${KUADRANT_VERSION}" \
  --namespace "${KUADRANT_NAMESPACE}" \
  --create-namespace \
  --wait

log "Waiting for the Kuadrant operator deployments"
kc -n "${KUADRANT_NAMESPACE}" wait --for=condition=Available deployments --all --timeout=300s

log "Applying the Kuadrant CR (bootstraps Limitador + Authorino)"
kc apply -f "${CONFIG_DIR}/kuadrant/kuadrant-cr.yaml"

log "Waiting for Kuadrant to become Ready"
kc -n "${KUADRANT_NAMESPACE}" wait kuadrant/kuadrant --for=condition=Ready --timeout=300s || \
  warn "Kuadrant not Ready yet; check: kubectl -n ${KUADRANT_NAMESPACE} get kuadrant kuadrant -o yaml"
