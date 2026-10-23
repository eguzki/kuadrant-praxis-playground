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
PRAXIS_AI_FEATURES="${PRAXIS_AI_FEATURES:-full,token-rate-limit-filter}"

CONTAINER_ENGINE="${CONTAINER_ENGINE:-docker}"

# ---------------------------------------------------------------------------
# Namespaces
# ---------------------------------------------------------------------------
KUADRANT_NAMESPACE="${KUADRANT_NAMESPACE:-kuadrant-system}"
ISTIO_NAMESPACE="${ISTIO_NAMESPACE:-istio-system}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
GATEWAY_NAMESPACE="${GATEWAY_NAMESPACE:-ingress-gateway}"
PRAXIS_NAMESPACE="${PRAXIS_NAMESPACE:-praxis-gateway}"
UPSTREAM_NAMESPACE="${UPSTREAM_NAMESPACE:-llm}"

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
