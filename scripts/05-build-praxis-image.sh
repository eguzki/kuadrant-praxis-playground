#!/usr/bin/env bash
# Build the Praxis AI gateway image from local source WITH the experimental
# token-rate-limit-filter enabled, then load it into the kind cluster.
#
# The prebuilt ghcr.io/praxis-proxy/ai images exclude experimental filters,
# so token rate limiting requires a source build (PRAXIS_AI_FEATURES).
source "$(dirname "$0")/lib.sh"

require "${CONTAINER_ENGINE}" kind git

# If PRAXIS_AI_SRC points at an existing checkout, build that. Otherwise clone
# the Praxis AI repo into the gitignored scratch dir (${CACHE_DIR}).
if [ ! -d "${PRAXIS_AI_SRC}" ]; then
  log "Cloning ${PRAXIS_AI_REPO} (ref ${PRAXIS_AI_REF}) into ${PRAXIS_AI_SRC}"
  mkdir -p "$(dirname "${PRAXIS_AI_SRC}")"
  git clone --depth 1 --branch "${PRAXIS_AI_REF}" "${PRAXIS_AI_REPO}" "${PRAXIS_AI_SRC}"
elif [ -d "${PRAXIS_AI_SRC}/.git" ] && [ "${PRAXIS_AI_SRC}" = "${CACHE_DIR}/praxis-ai" ]; then
  log "Updating existing clone at ${PRAXIS_AI_SRC} to ${PRAXIS_AI_REF}"
  git -C "${PRAXIS_AI_SRC}" fetch --depth 1 origin "${PRAXIS_AI_REF}"
  git -C "${PRAXIS_AI_SRC}" checkout -q FETCH_HEAD
else
  log "Using existing Praxis AI source at ${PRAXIS_AI_SRC}"
fi

log "Building ${PRAXIS_AI_IMAGE} from ${PRAXIS_AI_SRC}"
log "  features: ${PRAXIS_AI_FEATURES}"
"${CONTAINER_ENGINE}" build \
  -t "${PRAXIS_AI_IMAGE}" \
  --build-arg "PRAXIS_AI_FEATURES=${PRAXIS_AI_FEATURES}" \
  -f "${PRAXIS_AI_SRC}/Containerfile" \
  "${PRAXIS_AI_SRC}"

log "Loading ${PRAXIS_AI_IMAGE} into kind cluster '${KIND_CLUSTER_NAME}'"
KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_ENGINE}" kind load docker-image "${PRAXIS_AI_IMAGE}" --name "${KIND_CLUSTER_NAME}"

log "Praxis AI image ready in the cluster"
