#!/usr/bin/env bash
# Install Kuadrant prerequisites via Helm/kubectl:
#   - cert-manager          (helm, jetstack)
#   - Gateway API CRDs      (kubectl, standard channel)
#   - Istio base + istiod   (helm, istio-release charts)
# This is the documented Kuadrant 1.6.0 dependency install path.
source "$(dirname "$0")/lib.sh"

require helm kubectl

log "Installing Gateway API CRDs ${GATEWAY_API_VERSION}"
kc apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

log "Installing cert-manager ${CERT_MANAGER_VERSION}"
helm repo add jetstack https://charts.jetstack.io --force-update >/dev/null
helm --kube-context "$(kctx)" upgrade --install cert-manager jetstack/cert-manager \
  --namespace "${CERT_MANAGER_NAMESPACE}" \
  --create-namespace \
  --version "${CERT_MANAGER_VERSION}" \
  --set crds.enabled=true \
  --wait

log "Installing Istio ${ISTIO_VERSION} (base + istiod) via Helm"
helm repo add istio https://istio-release.storage.googleapis.com/charts --force-update >/dev/null
helm --kube-context "$(kctx)" upgrade --install istio-base istio/base \
  --set defaultRevision=default \
  --namespace "${ISTIO_NAMESPACE}" \
  --create-namespace \
  --version "${ISTIO_VERSION}" \
  --wait
helm --kube-context "$(kctx)" upgrade --install istiod istio/istiod \
  --namespace "${ISTIO_NAMESPACE}" \
  --version "${ISTIO_VERSION}" \
  --wait

log "Waiting for istiod to be ready"
kc -n "${ISTIO_NAMESPACE}" rollout status deployment/istiod --timeout=300s

log "Verifying the 'istio' GatewayClass is registered"
kc get gatewayclass istio || warn "istio GatewayClass not found yet; it is created by istiod once Gateway API CRDs exist"
