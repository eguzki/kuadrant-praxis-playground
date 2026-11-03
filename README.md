# kuadrant-praxis-playground

Local [kind](https://kind.sigs.k8s.io/) environment to **live-validate the Kuadrant↔Praxis
token-rate-limiting feature-gap findings** from
[praxis-proxy/policy#200](https://github.com/praxis-proxy/policy/issues/200): it stands up
**one AI gateway per rate-limiting offering** over a shared upstream, and implements the
proposal `00121` **M1–M7** acceptance tests so each predicted score can be confirmed or
corrected against a real deployment.

- A **shared upstream** in namespace `llm`: [`llm-d-inference-sim`](https://github.com/llm-d/llm-d-inference-sim)
  (OpenAI, real token usage) + MockServer serving body-matched **multi-model** OpenAI responses
  (`gpt-4o` / `gpt-4o-mini`, with cached-token usage), an embeddings path, and Anthropic/Gemini shapes.
- A **static-JWKS JWT issuer** that mints per-tier (`gold`/`silver`/`enterprise`/`basic`, plus a
  `notier` no-claim token) test tokens for the tiered acceptance tests.
- Kuadrant + Istio installed via Helm on the kind cluster.

## Offerings

Five rate-limiting offerings are compared, in three groups (a sixth, Kuadrant's `RateLimitPolicy`,
was dropped by decision since K-TRLP alone gives the Kuadrant-side comparison):

- **P1, P2: native Praxis data-plane filters** (`HttpFilter`s inline in the proxy
  pipeline, with direct request/response and body access). **P1** is the request-count
  core `rate_limit` builtin; **P2** is the token-denominated `token_rate_limit` filter
  (the primary tokenomics offering).
- **P3, P4: Praxis Policy Engine (PPE) plugins** (operate on normalized CMF messages
  / PPE hooks, not raw HTTP). **P3** (`quota/limitador`) does token quota against a
  **standalone** Limitador over HTTP; **P4** (`ratelimit/limitador`) does request-count
  with an **embedded** Limitador, built from source with a forward-ported core (see
  [`CLAUDE.md`](CLAUDE.md) for why).
- **K-TRLP: a Kuadrant policy** on the Istio gateway, `TokenRateLimitPolicy` (token).

| Col | Gateway | What | Status |
|---|---|---|---|
| **P1** | `praxis-p1` | Praxis core `rate_limit` filter (request-count) | ✅ deployed |
| **P2** | `praxis-p2` | Praxis `token_rate_limit` filter (token, native) | ✅ live, M1–M7 all verified |
| **P3** | `praxis-p3` | PPE `quota/limitador` plugin (token, standalone Limitador) | ✅ live, enforces per-tier |
| **P4** | `praxis-p4` | PPE `ratelimit/limitador` plugin (request-count, embedded) | ✅ live, enforces per-tier |
| **K-TRLP** | Istio gateway | Kuadrant `TokenRateLimitPolicy` (reserve → reconcile) | ✅ live, enforces per-tier |

Each Praxis offering runs in its **own namespace** (`praxis-p1` … `praxis-p4`) with a
Deployment+Service named `praxis-ai`, and gets a **dedicated local port** when port-forwarded.
See [`CLAUDE.md`](CLAUDE.md)'s "Live-validation findings" section for the full per-offering
M1–M7 scores, and [`docs/acceptance-tests.md`](docs/acceptance-tests.md) for the per-criterion
procedures and the observed-results matrix.

## Prerequisites

`docker`, `kind`, `helm`, `kubectl`, `git`, `openssl`. Praxis AI is built from source (cloned
automatically), so a working Docker build environment is needed. The P3/P4 image builds also
need `python3` (used by the build scripts to apply source overlays/patches).

## Quick start

```sh
make setup                        # cluster -> istio -> kuadrant -> upstream -> P1-P4 -> K-TRLP
                                   # (P3/P4 are from-source spikes; setup warns and continues
                                   #  if a spike build fails on your host, see scripts/setup.sh)

# in separate terminals (one port per gateway):
./test/port-forward.sh p2         # P2 token_rate_limit    -> http://localhost:8082
./test/test-token-rate-limit.sh   # ~Nx HTTP 200, then HTTP 429 with X-RateLimit-*-Tokens headers

./test/port-forward.sh p4         # P4 ratelimit/limitador -> http://localhost:8084
./test/test-p4-ratelimit.sh       # per-tier 200 -> 429, enterprise exempt, notier denied

./test/port-forward.sh istio      # K-TRLP (Istio gateway) -> http://localhost:8080
./test/test-k-trlp.sh             # per-tier 200 -> 429 (reserve -> reconcile), enterprise exempt

./test/port-forward.sh p1         # P1 rate_limit          -> http://localhost:8081
./test/port-forward.sh p3         # P3 quota/limitador     -> http://localhost:8083
```

Port map: `p1`→8081, `p2`→8082, `p3`→8083, `p4`→8084, `istio`→8080 (override with `LOCAL_PORT=`).

The per-tier JWTs are written to `.cache/tokens/{gold,silver,enterprise,basic,notier}.jwt`; send
one with `-H "Authorization: Bearer $(cat .cache/tokens/gold.jwt)"` (P2's current config also
wants an `-H 'x-tier: gold'` client header alongside the JWT).

## Make targets

```
make help              # list targets
make setup             # full setup (all six offerings, best-effort for the P3/P4 spikes)
make cluster           # kind cluster
make deps              # Gateway API + cert-manager + Istio (helm)
make kuadrant          # Kuadrant operator + CR (helm)
make upstream          # shared upstream (inference-sim + multi-model mockserver)
make jwt-issuer        # static-JWKS JWT issuer + mint per-tier test tokens
make istio-gateway     # Istio gateway + HTTPRoute
make praxis-image      # build Praxis AI image (token-rate-limit-filter) + load into kind
make praxis            # deploy P1 + P2 gateways
make praxis-p1         # deploy P1 (rate_limit)          -> ns praxis-p1, port 8081
make praxis-p2         # deploy P2 (token_rate_limit)    -> ns praxis-p2, port 8082
make limitador         # deploy the standalone Limitador (for P3) into ns llm
make praxis-image-p3   # build the P3 image (praxis-ai:quota) + load into kind
make praxis-p3         # deploy P3 (quota/limitador)     -> ns praxis-p3, port 8083
make praxis-image-p4   # build the P4 image (praxis-ai:ratelimit) + load into kind
make praxis-p4         # deploy P4 (ratelimit/limitador) -> ns praxis-p4, port 8084
make kuadrant-policies # deploy K-TRLP (AuthPolicy + TokenRateLimitPolicy) on the Istio gateway
make test              # token rate limit test (needs: port-forward p2)
make cleanup           # delete the kind cluster
```

Each step has a matching script in `scripts/` and is idempotent, so you can re-run any one
on its own. The P3/P4 image builds (`05-build-praxis-image-p{3,4}.sh`) are the slow, best-effort
parts: they vendor and patch additional source trees (see [`CLAUDE.md`](CLAUDE.md) for why).

## Tear down

```sh
./scripts/cleanup.sh            # delete the kind cluster (everything)
./scripts/cleanup.sh --image    # also remove the local praxis-ai:dev image
```

## Configuration

Versions, image tags, namespaces, and JWT settings live in [`scripts/lib.sh`](scripts/lib.sh)
and can be overridden via environment variables, e.g.:

```sh
KUADRANT_VERSION=1.6.0 ISTIO_VERSION=1.29.1 ./scripts/setup.sh
PRAXIS_AI_SRC=/path/to/ai ./scripts/05-build-praxis-image.sh   # build an existing checkout
```

## Layout

```
Makefile              # convenience targets
scripts/              # numbered setup steps + per-offering deploy scripts + lib.sh / lib-jwt.sh
config/
  upstream/           # shared upstream, multi-model mockserver expectations, jwt-issuer
  praxis/{p1..p4}/    # one dir per offering: configmap + deployment + service
  istio/              # Istio gateway
  kuadrant/           # Kuadrant CR + K-TRLP policies (authpolicy, tokenratelimitpolicy)
test/                 # port-forward + per-offering exercise scripts (P2, P4, K-TRLP)
docs/
  acceptance-tests.md # per-criterion M1-M7 procedures + the observed-results matrix
CLAUDE.md             # detailed design notes, pinned versions, gotchas, live-validation findings
```

See [`CLAUDE.md`](CLAUDE.md) for the full design, routing table, and known gotchas.
