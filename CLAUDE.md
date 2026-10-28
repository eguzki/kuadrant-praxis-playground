# kuadrant-praxis-playground

A local **kind** environment to **live-validate the Kuadrant/Praxis token-rate-limiting
feature-gap findings** from [praxis-proxy/policy#200](https://github.com/praxis-proxy/policy/issues/200)
against proposal `00121`'s **M1–M7** acceptance tests. It stands up **one AI gateway per
rate-limiting offering** over a shared upstream, so each predicted score can be confirmed or
corrected on a real deployment.

Everything is installed via **Helm** (Kuadrant, Istio, cert-manager) on a kind cluster,
mirroring the Kuadrant 1.6.0 install path. A **static-JWKS JWT issuer** mints per-tier
(`gold`/`silver`/`enterprise`) tokens for the tiered tests.

## Offerings (the six compared)

| Col | ns / gateway | What | Layer |
|---|---|---|---|
| **P1** | `praxis-p1` | core `rate_limit` filter (request-count) | Praxis data plane (`HttpFilter`) |
| **P2** | `praxis-p2` | `token_rate_limit` filter (token, native) | Praxis data plane (`HttpFilter`) |
| **P3** | `praxis-p3` | `quota/limitador` plugin (token, **standalone** Limitador over HTTP) | Praxis PPE plugin |
| **P4** | `praxis-p4` | `ratelimit/limitador` plugin (request-count, **embedded** Limitador) | Praxis PPE plugin |
| **K-TRLP** | Istio gw | Kuadrant `TokenRateLimitPolicy` (token) | Kuadrant |
| **K-RLP** | Istio gw | Kuadrant `RateLimitPolicy` (request-count) | Kuadrant |

Data-plane filters (P1/P2) see the request body directly; PPE plugins (P3/P4) operate on CMF
messages (body/model reaches them only via `cmf.llm_input`, not the bodyless `http.request`
hook). See the comparison doc (gist) for the full per-criterion analysis.

## Live-validation status (running log in `findings.md`)

- **P2 — LIVE VERIFIED: M1–M7 (all).** Confirmations: **M3** reserved estimate tracks body
  `max_tokens` (`estimation.strategy: max_tokens` → 100/2000/absent reserve 100/2000/50),
  **M4** weighted reconcile (gpt-4o 3000 / cached 2000 / completion 500 → `actual=1700`,
  cached weight 0.1), **M5** compound `(model, tier)` keys, **M6** 429 +
  `X-RateLimit-*-Tokens` (**on 429 only**), **M2** reserve→reconcile, **M7** `praxis_trl_*`
  metrics + accounting logs. Model match via `model_to_header`→`X-Model` works at admission.
  Caveats: enterprise exemption is **approximated** (huge-capacity rule; `token_rate_limit`
  has no native "exempt" action); `x-tier` is currently a **client header**, not yet a
  verified-JWT claim.
- **P1** — deployed; #200 predicts M1 🟡, M5 ❌, M6 ✅, M7 🟡, S1 🟡; M2/M3/M4 N/A. Live
  confirmation pending.
- **P3, P4, K-TRLP, K-RLP** — not yet deployed/exercised (source-build spike for P3/P4).

## How it's built

- Praxis AI is built **from local source** (not the prebuilt ghcr image) because
  `token-rate-limit-filter` is an **experimental** cargo feature excluded from prebuilt builds.
  P3/P4 additionally need `experimental-quota` / `experimental-ratelimit` (policy engine).

## Layout

```
Makefile                      # convenience targets (make help)
scripts/
  lib.sh                      # shared versions, namespaces, helpers (source of truth for config)
  00-create-cluster.sh        # kind cluster
  01-install-istio.sh         # Gateway API CRDs + cert-manager + Istio (base+istiod) via helm
  02-install-kuadrant.sh      # kuadrant-operator helm chart + Kuadrant CR
  03-deploy-upstream.sh       # shared upstream (inference-sim + mockserver) in ns `llm`
  04-deploy-istio-gateway.sh  # Istio Gateway + HTTPRoute to upstream
  05-build-praxis-image.sh    # docker build praxis-ai (experimental features) + kind load
  06-deploy-praxis.sh         # Praxis AI gateway Deployment/Service/ConfigMap
  setup.sh                    # runs 00..06 in order (idempotent)
  cleanup.sh                  # delete kind cluster
config/
  kind/kind-config.yaml
  istio/istio-gateway.yaml
  kuadrant/kuadrant-cr.yaml
  upstream/{namespace,llm-d-inference-sim,mockserver,istio-httproute}.yaml
  upstream/mockserver-expectations.json
  praxis/{configmap,deployment,service}.yaml
test/
  port-forward.sh             # port-forward praxis|istio gateway to localhost:8080
  test-token-rate-limit.sh    # hammer praxis /v1/chat/completions, watch 200 -> 429
```

## Quick start

```sh
make setup                      # full build (step 05 Rust compile is the slow part)
# then, in two terminals:
./test/port-forward.sh praxis   # -> http://localhost:8080
./test/test-token-rate-limit.sh # 200s then 429s
make cleanup                    # tear down
```

Individual steps: `make cluster | deps | kuadrant | upstream | istio-gateway | praxis-image | praxis`.

## Pinned versions (override via env; see `scripts/lib.sh`)

| Component | Version | How |
|---|---|---|
| kind node | `v1.35.0` | kind |
| Gateway API | `v1.4.1` | kubectl standard-install (Kuadrant's version) |
| cert-manager | `v1.16.1` | jetstack helm chart |
| Istio (base + istiod) | `1.29.1` | istio-release helm charts |
| Kuadrant operator | `1.6.0` | `kuadrant/kuadrant-operator` helm chart |
| llm-d-inference-sim | `ghcr.io/llm-d/llm-d-inference-sim:v0.1.1` | Deployment (matches wasm-shim#437) |
| MockServer | `mockserver/mockserver:8.0.0` | Deployment; native `httpLlmResponse` LLM mocking |
| Praxis AI | `praxis-ai:dev` | built from source; cloned into `.cache/praxis-ai` (or `PRAXIS_AI_SRC`) |
| Container engine | `docker` | kind provider + builds |

## Namespaces

- `kuadrant-system` — Kuadrant operator + Kuadrant CR (Limitador, Authorino)
- `istio-system` — Istio
- `cert-manager` — cert-manager
- `ingress-gateway` — the single Istio-managed gateway (hosts the Kuadrant K-TRLP/K-RLP policies)
- `praxis-p1` … `praxis-p4` — one namespace per Praxis offering, each a Deployment+Service
  named `praxis-ai` (+ ConfigMap). Port-forward map: p1→8081, p2→8082, p3→8083, p4→8084,
  istio→8080 (override `LOCAL_PORT=`).
- `jwt-issuer` — static-JWKS issuer; per-tier JWTs land in `.cache/tokens/{gold,silver,enterprise,notier}.jwt`
- `llm` — shared upstream (`llm-d-inference-sim`, `mock-llm` multi-model mockserver)

## Request routing (both gateways)

| Path | Backend | Shape |
|---|---|---|
| `POST /v1/chat/completions` | `llm-d-inference-sim.llm:8000` | OpenAI (real token usage) |
| `GET /v1/models` | `llm-d-inference-sim.llm:8000` | OpenAI model list |
| `POST /v1/messages` | `mock-llm.llm:1080` | Anthropic |
| `POST /v1beta/models/<m>:generateContent` | `mock-llm.llm:1080` | Gemini |

The **token rate limiting test path is `/v1/chat/completions` -> inference-sim**, because
that backend returns `usage.total_tokens`, which Praxis `token_count` (provider: openai)
reconciles against the `token_rate_limit` reservation.

## Praxis token rate limiting (how it works here)

`config/praxis/configmap.yaml` filter chain: `router -> token_rate_limit -> token_count ->
access_log -> load_balancer`. The `token_rate_limit` filter reserves `reserved_tokens` per
request at admission from a sliding-window budget, then reconciles against actual usage from
the response. Playground values (small on purpose, easy to trip):

```
window: 1m   capacity: 200   reserved_tokens: 50   key: global   algorithm: sliding_window
```

The inference-sim reports ~20 tokens/response, so **~8 requests/min** are admitted before
HTTP 429: each reserves 50 at admission, then reconciles down to the real ~20, so a 9th
request can't get its 50-token headroom. 429 responses carry `X-RateLimit-*-Tokens` headers
(`Limit=200`, `Remaining=0`, `Reset` counting down the window). To change the limit, edit
the ConfigMap and re-run `make praxis` (it restarts the deployment).

Verified working: 8×`200` (each with real `usage.total_tokens`) then `429`.

## Key facts / gotchas (learned while building)

- **Praxis metrics need an `admin` block bound to `0.0.0.0`.** The Prometheus recorder is
  only installed when `admin.address`/`admin.metrics_address` is set; `/metrics` (incl. all
  `praxis_trl_*`) is absent otherwise, and the default `127.0.0.1:9901` is unreachable via
  `kubectl port-forward` — use `admin.metrics_address: "0.0.0.0:9901"` (P2 configmap does).
- **MockServer rejects JSON comment keys.** `mockserver:8.0.0` validates the init JSON
  strictly (`additionalProperties: false`); a `"//": "..."` key anywhere makes it reject the
  **entire** file → 0 expectations → every request 404/502. Keep
  `config/upstream/mockserver-expectations.json` comment-free.
- **`token-rate-limit-filter` is experimental.** Build with
  `PRAXIS_AI_FEATURES=full,token-rate-limit-filter` (set in `lib.sh`). Prebuilt
  `ghcr.io/praxis-proxy/ai` images do NOT include it. `scripts/05` clones the Praxis AI
  source into the gitignored `.cache/praxis-ai` (override `PRAXIS_AI_SRC` for an existing
  checkout; `PRAXIS_AI_REPO` / `PRAXIS_AI_REF` to change what is cloned).
- **Praxis AI is config-driven**, deployed as plain Deployment+ConfigMap+Service. The
  `praxis-proxy/operator` (Gateway-API GatewayClass `praxis`) exists but is intentionally
  **not used** yet. Switching to it later would need Gateway API **v1.5.1** (vs Kuadrant's
  v1.4.1) — a potential conflict to resolve.
- Praxis container: `ENTRYPOINT ["praxis-ai"]`, config via `-c`, data port `8080`,
  admin/observability `9901`. Probes use TCP `8080`.
- **Praxis refuses to dial private/reserved IPs by default.** Cluster Service IPs are
  private, so the `load_balancer` upstream needs `insecure_options.allow_private_upstreams:
  true` or every proxied request fails with **502** (`ConnectError ... resolved to
  private/reserved IP`). Note the `token_rate_limit` reservation still fires on a 502 (and
  is NOT reconciled, since no usage is reported), which looked like "rate limiting works but
  returns 502" until the upstream was fixed. `allow_private_endpoints` (from the upstream
  examples) is a different key and does NOT cover the upstream dial.
- **Istio gateway `Programmed=False` in kind is normal** — no LoadBalancer means the Service
  external address stays pending (`AddressNotAssigned`). The data plane still works; wait on
  the `ingress-gateway-istio` Deployment, not the gateway's `Programmed` condition.
- **`kubectl wait` can't read HTTPRoute conditions** (they live under `status.parents[]`);
  poll `.status.parents[0].conditions[?(@.type=="Accepted")].status` instead.
- **MockServer 8.0.0 natively supports `httpLlmResponse`** (LLM response mocking with
  `provider`/`usage`/`streamingPhysics`). The expectations here are adapted from
  Kuadrant/wasm-shim#437 `utils/multi_llm_provider/` with the `Host`-header matchers
  **removed** (in-cluster routing doesn't preserve those `*.nip.io` hostnames).
- `llm-d-inference-sim:v0.1.1` args: `--model mock --port 8000 --mode echo`. Newer tags
  exist (up to v0.10.1) if needed.
- Istio installed via helm (`istio/base` + `istio/istiod`) auto-creates the `istio`
  GatewayClass and auto-provisions the gateway data plane for a `gatewayClassName: istio`
  Gateway.
- Cross-namespace HTTPRoute: `llm-route` lives in `llm` (same ns as backend, no
  ReferenceGrant) and attaches to the gateway in `ingress-gateway` via `parentRef`
  (gateway listener allows routes `from: All`).
- **podman caveat:** `scripts/05` uses `kind load docker-image`. With podman, image loading
  differs (`kind load image-archive`). Scripts default to docker.
- No MetalLB: gateway access is via `kubectl port-forward` (not a LoadBalancer IP).

## Next steps / ideas

- Add a Kuadrant `TokenRateLimitPolicy` on the Istio gateway's HTTPRoute for a true
  side-by-side comparison (Limitador-backed vs Praxis-native).
- Shared/distributed Praxis budget across replicas via a `backend: {kind: valkey, ...}`
  under the `token_rate_limit` filter.
- Per-provider `token_count` (currently fixed to `openai`), so Anthropic/Gemini usage is
  reconciled too.

## Reference sources

- Kuadrant operator: <https://github.com/Kuadrant/kuadrant-operator> (`make/*.mk` for the
  local-setup patterns this playground borrows from)
- Praxis AI: <https://github.com/praxis-proxy/ai> (examples in `examples/configs/`, esp.
  `token-rate-limit*.yaml`)
- Praxis policy engine: <https://github.com/praxis-proxy/policy>
- Praxis core (`router`/`load_balancer` filters): <https://github.com/praxis-proxy/praxis>
- Praxis operator (not used yet): <https://github.com/praxis-proxy/operator>
- Upstream mock reference: Kuadrant/wasm-shim#437 `utils/multi_llm_provider/`
