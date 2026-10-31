#!/usr/bin/env bash
# Build the P4 Praxis AI image (praxis-ai:ratelimit) from source with the PPE
# `ratelimit/limitador` plugin (embedded, request-count) enabled.
#
# Why this is more involved than P3 (quota):
#   The ratelimit plugin exists only on the unmerged PR praxis-proxy/policy#178,
#   which sits on the policy engine's 0.5.0 line. But praxis-ai pins the PUBLISHED
#   core praxis-proxy* 0.7.5, and that core requires praxis-policy ^0.4.1 and its
#   `policy` filter reads `RawInboundToken.source_header` -- a field 0.5.0 removed
#   (now `source: Credential`). No published OR main core consumes policy 0.5.0.
#   So to get the plugin we must:
#     (a) vendor BOTH the policy PR source AND the core source into the build,
#     (b) [patch.crates-io] the whole praxis-policy* AND praxis-proxy* families to
#         those local copies,
#     (c) relabel the vendored engine 0.5.0 -> 0.4.1 so it satisfies core's ^0.4.1,
#     (d) forward-port core's `policy` filter to the 0.5.0 RawInboundToken API
#         (map Credential::Header{name} back to the old source_header; skip the
#         new cookie/query-param sources). This is the ONLY core code change the
#         0.4->0.5 delta requires (verified: 3 compile errors, all in one fn).
#
# BEST-EFFORT SPIKE: if upstream changes shift that delta, the build fails -- the
# finding (core cannot consume policy 0.5.0 without this forward-port) stands.
#
# The praxis-ai Containerfile copies source explicitly (no `COPY . .`) and builds
# in docker, so both vendored trees live INSIDE the context (vendor-core,
# vendor-policy) and a generated Containerfile.p4 copies them before the build.
#
# Reuses the praxis-ai checkout from scripts/05 (PRAXIS_AI_SRC); resets the files
# it overlays first, so it is reproducible and independent of P3's overlay.
source "$(dirname "$0")/lib.sh"

require "${CONTAINER_ENGINE}" kind git python3

VENDOR_POLICY="${PRAXIS_AI_SRC}/vendor-policy"
VENDOR_CORE="${PRAXIS_AI_SRC}/vendor-core"
CONTAINERFILE_P4="${PRAXIS_AI_SRC}/Containerfile.p4"

# ---------------------------------------------------------------------------
# 1. praxis-ai source + reset overlay files
# ---------------------------------------------------------------------------
if [ ! -d "${PRAXIS_AI_SRC}" ]; then
  log "Cloning ${PRAXIS_AI_REPO} (ref ${PRAXIS_AI_REF}) into ${PRAXIS_AI_SRC}"
  mkdir -p "$(dirname "${PRAXIS_AI_SRC}")"
  git clone --depth 1 --branch "${PRAXIS_AI_REF}" "${PRAXIS_AI_REPO}" "${PRAXIS_AI_SRC}"
fi
log "Resetting praxis-ai overlay files to pristine (Cargo.toml, server/Cargo.toml)"
git -C "${PRAXIS_AI_SRC}" checkout -- Cargo.toml server/Cargo.toml 2>/dev/null || true

# ---------------------------------------------------------------------------
# 2. Vendor the PR #178 policy workspace; relabel 0.5.0 -> 0.4.1
# ---------------------------------------------------------------------------
log "Fetching P4 policy source (PR #178) into ${VENDOR_POLICY}"
rm -rf "${VENDOR_POLICY}"
if git clone --depth 1 --branch "${PRAXIS_POLICY_P4_REF}" "${PRAXIS_POLICY_P4_REPO}" "${VENDOR_POLICY}" 2>/dev/null; then
  log "Cloned fork ${PRAXIS_POLICY_P4_REPO} (${PRAXIS_POLICY_P4_REF})"
else
  warn "Fork clone failed; falling back to ${PRAXIS_POLICY_P4_PR_REF} from ${PRAXIS_POLICY_REPO}"
  git init -q "${VENDOR_POLICY}"
  git -C "${VENDOR_POLICY}" remote add origin "${PRAXIS_POLICY_REPO}"
  git -C "${VENDOR_POLICY}" fetch --depth 1 origin "${PRAXIS_POLICY_P4_PR_REF}"
  git -C "${VENDOR_POLICY}" checkout -q FETCH_HEAD
fi
rm -rf "${VENDOR_POLICY}/.git" "${VENDOR_POLICY}/target"

log "Relabelling vendored praxis-policy* version 0.5.0 -> 0.4.1 (satisfies core ^0.4.1)"
python3 -I - "${VENDOR_POLICY}/Cargo.toml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
# Every 0.5.0 in the PR root Cargo.toml is a praxis-policy* version pin (workspace
# version + 7 path-dep pins); members inherit via version.workspace=true.
n = s.count('"0.5.0"'); open(p, "w").write(s.replace('"0.5.0"', '"0.4.1"'))
print(f"relabelled {n} version string(s)")
PY

# ---------------------------------------------------------------------------
# 3. Vendor core @ the pinned tag; forward-port its policy filter to 0.5.0
# ---------------------------------------------------------------------------
log "Fetching core (${PRAXIS_CORE_REF}) into ${VENDOR_CORE}"
rm -rf "${VENDOR_CORE}"
git clone --depth 1 --branch "${PRAXIS_CORE_REF}" "${PRAXIS_CORE_REPO}" "${VENDOR_CORE}"
rm -rf "${VENDOR_CORE}/.git" "${VENDOR_CORE}/target"

log "Forward-porting core policy filter to the praxis-policy 0.5.0 RawInboundToken API (idempotent)"
python3 -I - "${VENDOR_CORE}/crates/filter/src/builtins/http/security/policy/filter.rs" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
changed = False
# (a) bring Credential into scope
old_use = 'extensions::{LLMExtension, LlmRequestDocument, MetaExtension},'
new_use = 'extensions::{Credential, LLMExtension, LlmRequestDocument, MetaExtension},'
if old_use in s:
    s = s.replace(old_use, new_use, 1); changed = True
# (b) map source_header -> Credential::Header{name}; skip cookie/query sources
old_loop = '''        for inbound in raw.inbound_tokens.values() {
            let normalized = inbound.source_header.to_ascii_lowercase();
            if attached_outbound.contains(&normalized) {
                continue;
            }
            if let Ok(n) = http::header::HeaderName::try_from(inbound.source_header.as_str()) {
                ctx.request_headers_to_remove.push(n);
            } else {
                tracing::warn!(
                    target: "policy.filter",
                    header = %inbound.source_header,
                    "inbound source_header is not a valid HTTP header name; cannot strip",
                );
            }'''
new_loop = '''        for inbound in raw.inbound_tokens.values() {
            // [playground P4 overlay] praxis-policy 0.5.0 replaced the inbound
            // token's `source_header: String` with `source: Credential`. Only a
            // header-sourced credential has an inbound header to strip, so map
            // `Credential::Header { name }` back to the old `source_header` and
            // skip the new cookie / query-param sources (which 0.4.1 could not
            // represent and which this strip step never handled).
            let Credential::Header { name: source_header } = &inbound.source else {
                continue;
            };
            let normalized = source_header.to_ascii_lowercase();
            if attached_outbound.contains(&normalized) {
                continue;
            }
            if let Ok(n) = http::header::HeaderName::try_from(source_header.as_str()) {
                ctx.request_headers_to_remove.push(n);
            } else {
                tracing::warn!(
                    target: "policy.filter",
                    header = %source_header,
                    "inbound source_header is not a valid HTTP header name; cannot strip",
                );
            }'''
if old_loop in s:
    s = s.replace(old_loop, new_loop, 1); changed = True
open(p, "w").write(s)
if changed:
    print("core filter.rs forward-port applied")
elif 'Credential::Header { name: source_header }' in s:
    print("core filter.rs forward-port already present")
else:
    sys.exit("ERROR: core filter.rs did not match the expected 0.7.5 source; "
             "the 0.4->0.5 delta may have shifted -- re-verify the forward-port")
PY

# ---------------------------------------------------------------------------
# 4. Overlay praxis-ai server/Cargo.toml: direct praxis-policy dep + feature
# ---------------------------------------------------------------------------
log "Applying experimental-ratelimit overlay to server/Cargo.toml (idempotent)"
python3 -I - "${PRAXIS_AI_SRC}/server/Cargo.toml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read(); changed = False
if "experimental-ratelimit" not in s:
    s = s.replace(
        'experimental = ["praxis-ai-filters/experimental"]',
        'experimental = ["praxis-ai-filters/experimental"]\n'
        '# [playground overlay] P4: enable the PPE ratelimit/limitador plugin.\n'
        'experimental-ratelimit = ["policy-engine", "dep:praxis-policy", "praxis-policy/experimental-ratelimit"]',
        1); changed = True
if "praxis-policy = {" not in s:
    s = s.replace(
        'praxis-core = { workspace = true }',
        'praxis-core = { workspace = true }\n'
        '# [playground overlay] P4: direct praxis-policy dep; [patch] (root Cargo.toml)\n'
        '# redirects it to the vendored PR #178 source so experimental-ratelimit builds.\n'
        'praxis-policy = { version = "=0.4.1", optional = true, default-features = false }',
        1); changed = True
open(p, "w").write(s)
print("server overlay applied" if changed else "server overlay already present")
PY

# ---------------------------------------------------------------------------
# 5. Overlay praxis-ai root Cargo.toml: exclude vendor dirs + [patch.crates-io]
# ---------------------------------------------------------------------------
log "Applying [patch.crates-io] overlay to root Cargo.toml (idempotent)"
python3 -I - "${PRAXIS_AI_SRC}/Cargo.toml" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
if 'exclude' not in s.split('[workspace.package]')[0]:
    s = s.replace('resolver = "3"',
                  'resolver = "3"\nexclude = ["vendor-core", "vendor-policy"]', 1)
if '[patch.crates-io]' not in s:
    patch = '''
# [playground overlay] P4: redirect the praxis-proxy* (core) and praxis-policy*
# (engine) families to the vendored sources. core = tag v0.7.5 with the policy
# filter forward-ported to the 0.5.0 engine; engine = PR #178 (0.5.0) relabelled
# to 0.4.1 so it satisfies core's ^0.4.1.
[patch.crates-io]
praxis-proxy = { path = "vendor-core/crates/server" }
praxis-proxy-core = { path = "vendor-core/crates/core" }
praxis-proxy-filter = { path = "vendor-core/crates/filter" }
praxis-proxy-protocol = { path = "vendor-core/crates/protocol" }
praxis-proxy-tls = { path = "vendor-core/crates/tls" }
praxis-policy = { path = "vendor-policy/crates/ppe" }
praxis-policy-core = { path = "vendor-policy/crates/ppe-core" }
praxis-policy-orchestration = { path = "vendor-policy/crates/ppe-orchestration" }
praxis-policy-apl-core = { path = "vendor-policy/crates/ppe-apl-core" }
praxis-policy-apl-cmf = { path = "vendor-policy/crates/ppe-apl-cmf" }
praxis-policy-apl-runtime = { path = "vendor-policy/crates/ppe-apl-runtime" }
praxis-policy-builtins = { path = "vendor-policy/crates/builtins" }
'''
    s = s.rstrip() + "\n" + patch
open(p, "w").write(s)
print("root overlay applied")
PY

# ---------------------------------------------------------------------------
# 6. Generate Containerfile.p4 (= Containerfile + COPY vendor-core/vendor-policy)
# ---------------------------------------------------------------------------
log "Generating ${CONTAINERFILE_P4} (copies both vendored trees before the cache build)"
python3 -I - "${PRAXIS_AI_SRC}/Containerfile" "${CONTAINERFILE_P4}" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()
anchor = "COPY Cargo.toml Cargo.lock ./"
if anchor not in s:
    sys.exit("Containerfile layout changed: anchor not found")
# [patch] path deps must exist before the first (dependency-cache) cargo build.
s = s.replace(anchor,
              anchor + "\n# [playground overlay] P4: vendored core + PR #178 policy for [patch].\n"
              "COPY vendor-core ./vendor-core\n"
              "COPY vendor-policy ./vendor-policy", 1)
open(dst, "w").write(s)
print("Containerfile.p4 written")
PY

# ---------------------------------------------------------------------------
# 7. Build + load
# ---------------------------------------------------------------------------
PRAXIS_AI_FEATURES_P4="${PRAXIS_AI_FEATURES_P4:-full,experimental-ratelimit}"
log "Building ${PRAXIS_AI_IMAGE_RATELIMIT} from ${PRAXIS_AI_SRC} (features: ${PRAXIS_AI_FEATURES_P4})"
# --provenance=false: plain single-platform image so `kind load` updates the tag.
"${CONTAINER_ENGINE}" build \
  --provenance=false \
  -t "${PRAXIS_AI_IMAGE_RATELIMIT}" \
  --build-arg "PRAXIS_AI_FEATURES=${PRAXIS_AI_FEATURES_P4}" \
  -f "${CONTAINERFILE_P4}" \
  "${PRAXIS_AI_SRC}"

log "Loading ${PRAXIS_AI_IMAGE_RATELIMIT} into kind cluster '${KIND_CLUSTER_NAME}'"
KIND_EXPERIMENTAL_PROVIDER="${CONTAINER_ENGINE}" kind load docker-image "${PRAXIS_AI_IMAGE_RATELIMIT}" --name "${KIND_CLUSTER_NAME}"

log "P4 image ready: ${PRAXIS_AI_IMAGE_RATELIMIT}"
