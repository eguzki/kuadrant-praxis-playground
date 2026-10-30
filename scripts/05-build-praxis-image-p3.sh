#!/usr/bin/env bash
# Build the P3 Praxis AI image (praxis-ai:quota) from source with the PPE
# `quota/limitador` plugin enabled.
#
# The experimental-quota feature lives on the praxis-policy (0.4.1) crate and is
# NOT forwarded by praxis-core / praxis-ai. We enable it by Cargo feature
# unification: a small overlay adds a direct `praxis-policy` dep + an
# `experimental-quota` feature to the server crate. No praxis-core fork or
# [patch] is needed -- the core `policy` filter already installs a proxy-backed
# HTTP transport (PolicyHttpTransport) for PPE plugins.
#
# Reuses the same source checkout as scripts/05 (PRAXIS_AI_SRC). Re-running
# scripts/05 resets that tree (git checkout), so re-run THIS script afterward to
# re-apply the overlay before a P3 build.
source "$(dirname "$0")/lib.sh"

require "${CONTAINER_ENGINE}" kind git python3

if [ ! -d "${PRAXIS_AI_SRC}" ]; then
  log "Cloning ${PRAXIS_AI_REPO} (ref ${PRAXIS_AI_REF}) into ${PRAXIS_AI_SRC}"
  mkdir -p "$(dirname "${PRAXIS_AI_SRC}")"
  git clone --depth 1 --branch "${PRAXIS_AI_REF}" "${PRAXIS_AI_REPO}" "${PRAXIS_AI_SRC}"
fi

log "Applying experimental-quota overlay to server/Cargo.toml (idempotent)"
python3 -I - "${PRAXIS_AI_SRC}/server/Cargo.toml" <<'PY'
import sys
p = sys.argv[1]
s = open(p).read()
changed = False
if "experimental-quota" not in s:
    s = s.replace(
        'experimental = ["praxis-ai-filters/experimental"]',
        'experimental = ["praxis-ai-filters/experimental"]\n'
        '# [playground overlay] P3: enable the PPE quota/limitador plugin.\n'
        'experimental-quota = ["policy-engine", "dep:praxis-policy", "praxis-policy/experimental-quota"]',
        1)
    changed = True
if "praxis-policy = {" not in s:
    s = s.replace(
        'praxis-core = { workspace = true }',
        'praxis-core = { workspace = true }\n'
        '# [playground overlay] P3: same praxis-policy core pins; experimental-quota unifies on.\n'
        'praxis-policy = { version = "=0.4.1", optional = true, default-features = false }',
        1)
    changed = True
open(p, "w").write(s)
print("overlay applied" if changed else "overlay already present")
PY

PRAXIS_AI_FEATURES_P3="${PRAXIS_AI_FEATURES_P3:-full,experimental-quota}"
log "Building ${PRAXIS_AI_IMAGE_QUOTA} from ${PRAXIS_AI_SRC} (features: ${PRAXIS_AI_FEATURES_P3})"
# --provenance=false: emit a plain single-platform image, not a buildx manifest
# list. `kind load` does not reliably update an existing tag from a manifest-list
# image, so a rebuilt image would otherwise not reach the node.
"${CONTAINER_ENGINE}" build \
  --provenance=false \
  -t "${PRAXIS_AI_IMAGE_QUOTA}" \
  --build-arg "PRAXIS_AI_FEATURES=${PRAXIS_AI_FEATURES_P3}" \
  -f "${PRAXIS_AI_SRC}/Containerfile" \
  "${PRAXIS_AI_SRC}"

log "Loading ${PRAXIS_AI_IMAGE_QUOTA} into kind cluster '${KIND_CLUSTER_NAME}'"
KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_ENGINE}" kind load docker-image "${PRAXIS_AI_IMAGE_QUOTA}" --name "${KIND_CLUSTER_NAME}"

log "P3 image ready: ${PRAXIS_AI_IMAGE_QUOTA}"
