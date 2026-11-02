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

## Live-validation findings (issue #200)

Per-offering results from exercising the gateways on the kind cluster. Feeds the M1–M7 scoring
in the issue comment. (M1 = limited-vs-exempt + default; M5 = multiple budgets + keys.) The
**per-criterion acceptance procedures + the Observed results matrix** live in
[`docs/acceptance-tests.md`](docs/acceptance-tests.md); this section is the narrative detail.

### P2 — `token_rate_limit` (native) — LIVE VERIFIED: M1–M7 (all)

Config: `config/praxis/p2/configmap.yaml` (upstream = MockServer, model-varied usage).
- **M1** limited/exempt/default via tiered `rules` + a catch-all. **M2** reserve→reconcile
  (`tokens_reserved_total` → `tokens_reconciled_total`). **M3** estimation tracks body
  `max_tokens` (`strategy: max_tokens` → `max_tokens:100/2000/absent` reserve `100/2000/50`).
  **M4** weighted reconcile (gpt-4o 3000/cached 2000/completion 500 → `actual=1700` with
  `cached_input: 0.1`, not raw 3500). **M5** compound `(model, tier)` keys — `premium`
  (gold+gpt-4o) / `gold-basic` / `silver-basic` discriminate by both. **M6** 429 +
  `X-RateLimit-*-Tokens` (**on 429 only**, not on 200s). **M7** `praxis_trl_*` metrics +
  accounting logs (`praxis_ai::token_rate_limit::accounting`).
- **Model match via `model_to_header`→`X-Model` works at admission** (an earlier "model-match
  fails" note was a non-reproducible config-iteration artifact).
- Caveats: enterprise exemption is **approximated** (huge-capacity rule — `token_rate_limit`
  has no native "exempt"/skip action, unlike the PPE/APL layer); `x-tier` is a **client
  header**, not yet a verified-JWT claim.

### P1 — core `rate_limit` (request-count)

Deployed. #200 predicts **M1 🟡, M5 ❌, M6 ✅, M7 🟡, S1 🟡 (shadow); M2/M3/M4 N/A** (not
token-denominated). Live confirmation pending.

### P3 — PPE `quota/limitador` (token, standalone Limitador) — LIVE, ENFORCES (per-tier)

Config: `config/praxis/p3/configmap.yaml` (policy doc: `identity/jwt` + `quota/limitador`) +
`config/upstream/limitador-standalone.yaml`. Image: `praxis-ai:quota`.
- **Build ✅ (no fork):** `experimental-quota` lives on `praxis-policy` 0.4.1 (the version
  core pins as `ppe`); a server-crate Cargo overlay enables it by **feature unification** —
  no `[patch]`, no core fork, no host-transport code (the core `policy` filter already
  installs `PolicyHttpTransport` and `set_http_transport`s it).
- **Deploy ✅:** `identity/jwt` verifies the issuer's RS256 JWT via JWKS-over-http
  (`jwks_url` + `insecure_http: true`, `capabilities: [perform_http]`); the quota debit needs
  the policy filter's **`body_access: read_write`**; quota HTTP to Limitador needs
  `allow_private_idp: true`.
- **Enforces end-to-end ✅** via a **three-layer** design:
  - **Layer 1 — APL (M1):** `llm:"*"` route with `pre_invocation`/`post_invocation` steps
    `when: claim.tier != "enterprise" → run(token-quota)`. Enterprise is **truly exempt**
    (plugin never dispatched). `pre_invocation`→`cmf.llm_input` (check), `post_invocation`→
    `cmf.llm_output` (debit) — **both** are needed (two handlers on two hooks).
  - **Layer 2 — plugin:** `identity_claim: tier` (P3 can send one descriptor), so the budget
    keys on the tier claim (exposed to APL via `claims: {include: [tier]}`).
  - **Layer 3 — Limitador limits:** per-tier budgets selected by CEL **`descriptors[0]["tier"]`**
    conditions (gold/silver + a default; enterprise matches no limit). Live: gold `200 200 403`,
    silver `200 200 403`, enterprise `200×5`.
- **Debit verified by instrumentation:** `QuotaReport` fires `/report` with the parsed
  `total_tokens` every request. An earlier "debit never lands / no identity at `cmf.llm_output`"
  conclusion was **wrong** — the debit always fired; the budget just wasn't enforcing because of
  **Limitador config** (see gotchas: explicit `memory` storage + `descriptors[0][...]` CEL).
- Caveats vs #200: **M2 ❌** soft cap (check probes delta=1, debit after — not a reservation);
  **M6 ❌** over-budget denial is **403, not 429**, with no `X-RateLimit-*`/`Retry-After` (PPE
  has no response-header injection); keys on **tier** (one descriptor) so it's per-tier, not
  per-user; **M7 🟡** `tracing` logs only, no metrics.

### P4 — PPE `ratelimit/limitador` (request-count, embedded Limitador) — LIVE, ENFORCES (per-tier)

Config: `config/praxis/p4/configmap.yaml` (policy doc: `identity/jwt` + `ratelimit/limitador`).
Image: `praxis-ai:ratelimit`. The plugin is on the policy engine's **0.5.0** line (PR
praxis-proxy/policy#178 is **merged**, so the build sources it from policy `main`).
- **Merged-design shift (vs the pre-merge PR):** the plugin no longer rides `http.request`/APL. It
  runs at the **new engine hooks `ratelimit.pre_identity` / `ratelimit.post_identity`** (host-invoked
  around identity resolution), is selected by a **`rate_limits:` list** (like `authentication:`
  selects identity resolvers), and **"cannot run from an APL `run(name)` step."**
- **Build ✅ (forward-ported core):** praxis-ai pins published core `praxis-proxy*` **0.7.5**, which
  requires `praxis-policy ^0.4.1`, reads `RawInboundToken.source_header` (removed in 0.5.0 →
  `source: Credential`), **and does not invoke the new rate-limit hooks** — no released *or* `main`
  core does (tracked by **praxis-proxy/praxis#1478**). So `scripts/05-build-praxis-image-p4.sh`
  vendors both the engine (policy `main`) and core `v0.7.5`, `[patch]`es both families, relabels the
  engine 0.5.0→0.4.1, and patches core's `policy` filter three ways: **(A)** import shim, **(B)**
  `source_header` → `Credential::Header` (compile), **(C)** a **minimal #1478 host implementation
  (post-identity subset)** — invoke `ratelimit.post_identity` after the header-phase
  `identity.resolve`, gated by `has_hooks_for`, denying with the violation's HTTP status. (Pre-identity
  + client-address + MCP site are the rest of #1478, omitted — P4's limits key on tier/subject.) The
  merged plugin also refuses a `panic=abort` build, so the overlay flips `[profile.release]` to
  `panic = "unwind"`. All patches live in the build script (reproducible from a clean clone).
- **Enforces end-to-end ✅.** Limitador is **embedded, in-process** (no standalone pod; counters
  per-replica, reset on restart):
  - Plugin declares `hooks: [ratelimit.post_identity]`; `global.rate_limits: [p4-ratelimit]` wires it
    in. `bindings` expose PPE attrs as flat CEL vars (`tier: claim.tier`, `subject_id`,
    `http_method`); `limits[]` carry CEL `conditions` over the bound vars with `variables: [tier]` as
    the budget key (M5).
  - **M1 exemption is via conditions, not a when-gate:** gold/silver/default all exclude
    `enterprise`, so no limit matches enterprise → unmetered. (No APL route/`when` block.)
  - Live: gold `200×5→429`, silver `200×2→429`, basic `200×3→429` (default catch-all), enterprise
    `200×6` (exempt), notier `400` (missing `tier` claim → `ratelimit.missing_attribute`, denies
    **before** counting), unauthenticated → `401`. **M5 independence confirmed** — per-tier counters
    are separate (each tier trips its own distinct limit).
- Scores vs #200: **M1 🟡** (limits by **claim/`tier`** + path, enterprise-exempt + default — but
  `ratelimit.post_identity` is **pre-body**, so it **cannot key on the request-body `model`**; model
  is a valid M1 dimension, so partial), **M5 🟡** (multiple per-tier request budgets + per-tier keys,
  but **no model-keyed budgets** for the same reason), **M6 🟡** (over-budget is **429** — better than
  P3's 403 — but the minimal host wiring maps only the status, no `X-RateLimit-*`/`Retry-After`; full
  #1478 would add them), **M7 🟡** (`tracing` only, no metrics), **M2/M3/M4 N/A** (request-count around
  identity, pre-body → no tokens, no body-`model`).

### K-TRLP — Kuadrant `TokenRateLimitPolicy` (token, Istio gateway) — LIVE, ENFORCES (per-tier)

Config: `config/kuadrant/{authpolicy,tokenratelimitpolicy}.yaml` + the Kuadrant CR
(`config/kuadrant/kuadrant-cr.yaml`, **`spec.tokenRateLimiting.mode: Reservation`**). Deployed by
`scripts/07-deploy-kuadrant-policies.sh` onto the shared Istio gateway's HTTPRoute (`llm-route`).
Kuadrant 1.6.0: `TokenRateLimitPolicy` is `kuadrant.io/v1alpha1`, `AuthPolicy` is `kuadrant.io/v1`.
- **Auth ✅ (reuses the same tokens):** `AuthPolicy` verifies the RS256 JWT via **`jwksUrl`** —
  Authorino's direct-JWKS mode, **no OIDC discovery** — so the static issuer pod and the existing
  per-tier tokens work unchanged (no `iss`/discovery doc needed). No token → **401**.
- **Reserve → reconcile (M2) ✅ — this is the point of K-TRLP.** In **Reservation** mode each limit
  reserves an **estimate** (`reservation.amount`, non-zero — 0 short-circuits to Optimistic) on
  request arrival, then commits the **actual** `usage.total_tokens` extracted from the (non-streaming)
  response and **releases the over-reservation**. Per-tier budgets keyed per user
  (`counters: auth.identity.sub`), gated by the claim (`when: auth.identity.tier == ...`). Playground
  values: `reservation.amount: 10` (a deliberate over-estimate vs the echo backend's ~4
  `total_tokens`/req), budgets gold 22 / silver 14 / default 18 tok/60s. Live:
  gold `200×4→429`, silver `200×2→429`, basic `200×3→429`, enterprise `200×6` (no limit matches →
  unmetered, M1 exemption via conditions), notier metered under the default bucket, no-token `401`.
  That gold admits **4** (not `22/10 ≈ 2`) is the proof the reconcile releases the over-reservation —
  committed usage (~4/req), not the reserved 10, accrues.
- **M3 estimation 🟡 — static, not body-derived.** `reservation.amount` can be a literal or a CEL
  expression, but it **cannot read the request body's `max_tokens`** (Envoy can't read the request
  body at the wasm phase here — CONNLINK-1608), so the estimate is a fixed / claim-derived value, not
  a per-request body estimate (contrast P2, which reads body `max_tokens` natively).
- **Three config lessons (all fixed in-repo, see gotchas):** (1) Reservation needs a non-zero
  `reservation.amount`. (2) Authorino does **not** surface JWT claims to the rate-limit wasm unless
  exported via `AuthPolicy.response.success.filters` → each property becomes `auth.identity.<name>`;
  without it the `auth.identity.tier` predicate raises a wasm `NoSuchKey` EvaluationError ("Failed to
  apply predicates") → fail-open. (3) A token with **no `tier` claim** (`notier`) also NoSuchKey's
  unless the filter supplies a fallback — `tier: {expression: 'has(auth.identity.tier) ?
  string(auth.identity.tier) : "none"'}` routes it into the default bucket. *(An earlier detour used
  Optimistic mode as a workaround; it was a mis-diagnosis of lesson (2)/(3), not a real Reservation
  limitation — Reservation works once claims + fallback + amount are set.)*
- Scores vs #200: **M1 🟡** (limits by **claim/`tier`** + path, enterprise-exempt + default — but
  **cannot key on the request-body `model`**: CONNLINK-1608, body unreadable at the wasm phase; model
  is a valid M1 dimension, so partial), **M2 ✅** (reserve→reconcile, demonstrated), **M3 🟡** (static
  estimate, no body `max_tokens`), **M5 🟡** (multiple per-tier token budgets + per-user keys, but
  **no model-keyed budgets** for the same reason), **M6 🟡** (over-budget is **429** but **no**
  `X-RateLimit-*`/`Retry-After` headers by default), **M7** Kuadrant/Limitador metrics + Istio
  telemetry (not re-scraped here). *(K-RLP dropped by decision.)*

### Not yet exercised

- Open: verified-JWT-claim → `x-tier` wiring on P2 (currently a client header).

## How it's built

- Praxis AI is built **from local source** (not the prebuilt ghcr image) because
  `token-rate-limit-filter` is an **experimental** cargo feature excluded from prebuilt builds.
  P3/P4 additionally need `experimental-quota` / `experimental-ratelimit` (policy engine).
- **P3** enables its feature by **unification on the published `praxis-policy` 0.4.1** — no fork, no
  `[patch]`. **P4** is heavier: its plugin lives on the engine's **0.5.0** line (policy `main`, merged
  PR #178) and runs at new host-invoked hooks the pinned core 0.7.5 neither compiles against nor
  invokes, so the P4 build **vendors + `[patch]`es both the engine (policy `main`) and core `v0.7.5`,
  forward-ports core's `policy` filter to the 0.5.0 API, and adds the #1478 post-identity host wiring**
  (plus `panic = "unwind"`; see the P4 finding above). Three source trees (`.cache/praxis-ai`,
  `…/vendor-core`, `…/vendor-policy`), all driven by
  `scripts/05-build-praxis-image-p4.sh`.

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
  setup.sh                    # one-command full stack: cluster -> infra -> P1-P4 -> K-TRLP (idempotent; P3/P4 spikes best-effort)
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
- **Standalone Limitador (P3) needs explicit storage + `descriptors[0][...]` CEL.** Run
  `limitador-server <limits-file> memory` — with no `STORAGE` arg the limits load but are
  never counted/enforced. And a limit's `conditions`/`variables` are CEL over the request's
  descriptor list: reference an entry as **`descriptors[0]["tier"]`** (a bare `tier`, or an
  empty `conditions: []` with `variables: [tier]`, does NOT match or count). The
  `quota/limitador` plugin sends one descriptor keyed on its `identity_claim`.
- **Embedded Limitador (P4) uses BARE CEL vars, not `descriptors[0][...]`.** The
  `ratelimit/limitador` plugin runs an in-process `limitador::RateLimiter` over a flat CEL context
  built from its `bindings` (PPE attr → variable name), so `conditions`/`variables` reference the
  bound names directly (e.g. `tier == 'gold'`, `variables: [tier]`) — the standalone HTTP
  descriptor form does NOT apply here. A bound attribute that is **missing or non-string denies**
  the request (so a token with no `tier` claim is denied, not defaulted). Over-budget denial is
  **429** (vs the `quota/limitador` 403). No standalone Limitador pod; counters are per-replica and
  reset on restart.
- **K-TRLP enforcement silently fails open unless three things are set** (symptom: all `200`, no
  `429`, `wasm log kuadrant-wasm-shim … Failed to apply predicates` in the gateway `istio-proxy`
  logs). (1) **Reservation mode needs a non-zero `reservation.amount`** per limit — the default `0`
  short-circuits to Optimistic (no reserve→reconcile, i.e. no M2/M3). (2) Authorino does **not**
  expose JWT claims to the rate-limit wasm; add `AuthPolicy.rules.response.success.filters` with
  `json.properties` so each becomes `auth.identity.<name>` for the TRLP `when`/`counters` — otherwise
  `auth.identity.tier` is `NoSuchKey` and the predicate errors. (3) A token **missing the claim**
  (`notier`) also errors unless the property has a fallback (`expression: 'has(auth.identity.tier) ?
  string(auth.identity.tier) : "none"'`). Diagnose with the `istio-proxy` wasm log above; note
  Limitador's committed `/counters/<ns>` stays `[]` under Reservation (reservations are tracked
  separately), so an empty `/counters` is not by itself proof of non-enforcement — check the `429`s.
- **Authorino can verify a JWT from a static JWKS without OIDC** via `jwt.jwksUrl` (no
  `/.well-known/openid-configuration` needed), so the playground's static-JWKS issuer and the same
  per-tier tokens work for the Kuadrant arm unchanged (no `iss`/discovery-doc gymnastics).
- **502 with no Praxis error log = the upstream returned 502** (Praxis passes it through; not
  necessarily the private-IP dial guard). Enable `runtime.log_overrides` for
  `pingora_core`/`pingora_proxy` at `debug` to see the real upstream response.
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
