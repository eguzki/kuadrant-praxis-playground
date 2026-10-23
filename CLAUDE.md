# kuadrant-praxis-playground

A local **kind**-based environment to compare / test **token rate limiting** on two
AI gateways sharing one upstream:

1. **Kuadrant control plane + Istio**, with **one Istio-managed gateway** (pass-through
   for now — no rate-limit policy attached yet).
2. **Praxis AI gateway** (`praxis-proxy/ai`) enforcing token rate limiting **natively**
   via its experimental `token_rate_limit` filter.
3. A **shared upstream** (`llm-d-inference-sim` + MockServer) fronted by both gateways.

Everything is installed via **Helm charts** (Kuadrant, Istio, cert-manager) on a kind
cluster, mirroring the official Kuadrant 1.6.0 install path.

## Current scope (as built)

- Token rate limiting is enforced **only on the Praxis gateway** (user decision).
  The Istio gateway is up and routes to the shared upstream but has no
  `TokenRateLimitPolicy` yet. Kuadrant's `TokenRateLimitPolicy` is the natural next
  step for parity (see "Next steps").
- Praxis AI is built **from local source** (not the prebuilt ghcr image) because the
  `token-rate-limit-filter` is an **experimental** cargo feature excluded from
  default/release/prebuilt builds.

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
- `ingress-gateway` — the single Istio-managed gateway (`ingress-gateway`)
- `praxis-gateway` — the Praxis AI gateway
- `llm` — shared upstream (`llm-d-inference-sim`, `mock-llm`)

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
