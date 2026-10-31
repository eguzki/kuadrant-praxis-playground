#!/usr/bin/env bash
# Shared config and helpers for the kuadrant-praxis-playground setup scripts.
# Source this from every script: `source "$(dirname "$0")/lib.sh"`

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_DIR="${ROOT_DIR}/config"

# ---------------------------------------------------------------------------
# Versions (override via environment)
# ---------------------------------------------------------------------------
KIND_CLUSTER_NAME="${KIND_CLUSTER_NAME:-kuadrant-praxis}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-mirror.gcr.io/kindest/node:v1.35.0}"

GATEWAY_API_VERSION="${GATEWAY_API_VERSION:-v1.4.1}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.1}"
ISTIO_VERSION="${ISTIO_VERSION:-1.29.1}"
KUADRANT_VERSION="${KUADRANT_VERSION:-1.6.0}"

# Upstream images (match Kuadrant/wasm-shim#437 multi_llm_provider setup)
INFERENCE_SIM_IMAGE="${INFERENCE_SIM_IMAGE:-ghcr.io/llm-d/llm-d-inference-sim:v0.1.1}"
MOCKSERVER_IMAGE="${MOCKSERVER_IMAGE:-mockserver/mockserver:8.0.0}"

# Praxis AI (built from source).
# By default the source is cloned into a gitignored scratch dir under the repo.
# Point PRAXIS_AI_SRC at an existing checkout to build that instead (no clone).
CACHE_DIR="${CACHE_DIR:-${ROOT_DIR}/.cache}"
PRAXIS_AI_REPO="${PRAXIS_AI_REPO:-https://github.com/praxis-proxy/ai.git}"
PRAXIS_AI_REF="${PRAXIS_AI_REF:-main}"
PRAXIS_AI_SRC="${PRAXIS_AI_SRC:-${CACHE_DIR}/praxis-ai}"
PRAXIS_AI_IMAGE="${PRAXIS_AI_IMAGE:-praxis-ai:dev}"
# token-rate-limit-filter is an EXPERIMENTAL feature, excluded from default/prebuilt builds.
# The base image (praxis-ai:dev) serves offerings P1 (rate_limit) and P2 (token_rate_limit).
PRAXIS_AI_FEATURES="${PRAXIS_AI_FEATURES:-full,token-rate-limit-filter}"

# Offering-specific image variants (built from source by scripts/05; see the
# per-offering build overlays). These PPE-plugin builds are BEST-EFFORT spikes:
# the experimental features are not forwarded by praxis-core/ai, so the build
# patches praxis-core + praxis-policy in via [patch.crates-io].
#   P3: praxis-ai:quota      -> PPE quota/limitador plugin (feature experimental-quota)
#   P4: praxis-ai:ratelimit  -> PPE ratelimit/limitador plugin (feature experimental-ratelimit)
PRAXIS_AI_IMAGE_QUOTA="${PRAXIS_AI_IMAGE_QUOTA:-praxis-ai:quota}"
PRAXIS_AI_IMAGE_RATELIMIT="${PRAXIS_AI_IMAGE_RATELIMIT:-praxis-ai:ratelimit}"

# Praxis core + policy sources for the P3/P4 from-source builds (see lib.sh notes).
# P3 (quota/limitador) is merged on praxis-proxy/policy main.
# P4 (ratelimit/limitador) lives only in OPEN PR #178 on praxis-proxy/policy,
# authored from the fork maleck13/ppe-policy (branch proposal/limitador-plugin).
PRAXIS_CORE_REPO="${PRAXIS_CORE_REPO:-https://github.com/praxis-proxy/praxis.git}"
# P4 pins core to the exact tag praxis-ai depends on (published praxis-proxy*
# 0.7.5), then forward-ports its `policy` filter to the 0.5.0 engine API. Using
# the tag (not main) keeps the praxis-ai<->core API stable so only the
# engine-facing delta needs patching.
PRAXIS_CORE_REF="${PRAXIS_CORE_REF:-v0.7.5}"
PRAXIS_POLICY_REPO="${PRAXIS_POLICY_REPO:-https://github.com/praxis-proxy/policy.git}"
PRAXIS_POLICY_REF="${PRAXIS_POLICY_REF:-main}"
# P4 source: the fork repo is `ppe-policy` (NOT `policy` -- that name 404s). If
# the fork ever disappears, scripts/05-...-p4 falls back to fetching the PR head
# ref (PRAXIS_POLICY_P4_PR_REF) from the base repo PRAXIS_POLICY_REPO, which keeps
# the branch alive as refs/pull/178/head for as long as the PR is open.
PRAXIS_POLICY_P4_REPO="${PRAXIS_POLICY_P4_REPO:-https://github.com/maleck13/ppe-policy.git}"
PRAXIS_POLICY_P4_REF="${PRAXIS_POLICY_P4_REF:-proposal/limitador-plugin}"
PRAXIS_POLICY_P4_PR_REF="${PRAXIS_POLICY_P4_PR_REF:-pull/178/head}"

# Standalone Limitador (P3 backs onto this over HTTP).
LIMITADOR_IMAGE="${LIMITADOR_IMAGE:-quay.io/kuadrant/limitador:latest}"

CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"

# ---------------------------------------------------------------------------
# JWT test issuer (static JWKS). Tiered acceptance tests (M1 override, M5 keys)
# need JWTs carrying a `tier` claim. Keys/JWKS/tokens are generated into
# ${CACHE_DIR}/jwt and ${CACHE_DIR}/tokens by scripts/lib-jwt.sh (gitignored).
# ---------------------------------------------------------------------------
JWT_ISSUER="${JWT_ISSUER:-https://jwt-issuer.praxis.local}"
JWT_AUDIENCE="${JWT_AUDIENCE:-praxis-playground}"
JWT_KID="${JWT_KID:-praxis-playground}"
# In-cluster JWKS URL (served by the jwt-issuer pod in the upstream namespace).
JWT_JWKS_URL="${JWT_JWKS_URL:-http://jwt-issuer.llm.svc.cluster.local:8080/.well-known/jwks.json}"

# ---------------------------------------------------------------------------
# Namespaces
# ---------------------------------------------------------------------------
KUADRANT_NAMESPACE="${KUADRANT_NAMESPACE:-kuadrant-system}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-ingress-gateway}"
UPSTREAM_NAMESPACE="${UPSTREAM_NAMESPACE:-llm}"

# One namespace per Praxis offering gateway (user decision). Each holds a
# Deployment+Service named `praxis-ai`. Port-forward map (one local port each,
# see test/port-forward.sh): p1->8081 p2->8082 p3->8083 p4->8084 (istio->8080).
PRAXIS_P1_NAMESPACE="${PRAXIS_P1_NAMESPACE:-praxis-p1}"
PRAXIS_P2_NAMESPACE="${PRAXIS_P2_NAMESPACE:-praxis-p2}"
PRAXIS_P3_NAMESPACE="${PRAXIS_P3_NAMESPACE:-praxis-p3}"
PRAXIS_P4_NAMESPACE="${PRAXIS_P4_NAMESPACE:-praxis-p4}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; }

require() {
  local missing=0
  for t in "$@"; do
    if ! command -v "$t" >/dev/null 2>&1; then
      err "required tool not found: $t"
      missing=1
    fi
  done
  [ "$missing" -eq 0 ] || exit 1
}

kctx() { echo "kind-${KIND_CLUSTER_NAME}"; }

kc() { kubectl --context "$(kctx)" "$@"; }
