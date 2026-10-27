# kuadrant-praxis-playground

Local [kind](https://kind.sigs.k8s.io/) environment to **live-validate the Kuadrant↔Praxis
token-rate-limiting feature-gap findings** from
[praxis-proxy/policy#200](https://github.com/praxis-proxy/policy/issues/200): it stands up
**one AI gateway per rate-limiting offering** over a shared upstream, and (work in progress)
implements the proposal `00121` **M1–M7** acceptance tests so each predicted score can be
confirmed or corrected against a real deployment.

- A **shared upstream** in namespace `llm` — [`llm-d-inference-sim`](https://github.com/llm-d/llm-d-inference-sim)
  (OpenAI, real token usage) + MockServer serving body-matched **multi-model** OpenAI responses
  (`gpt-4o` / `gpt-4o-mini`, with cached-token usage), an embeddings path, and Anthropic/Gemini shapes.
- A **static-JWKS JWT issuer** that mints per-tier (`gold`/`silver`/`enterprise`) test tokens for
  the tiered acceptance tests.
- Kuadrant + Istio installed via Helm on the kind cluster.

## Offerings

| Col | Gateway | What | Status |
|---|---|---|---|
| **P1** | `praxis-p1` | Praxis core `rate_limit` filter (request-count) | ✅ deployed |
| **P2** | `praxis-p2` | Praxis `token_rate_limit` filter (token, native) | ✅ deployed |
| **P3** | `praxis-p3` | PPE `quota/limitador` plugin (token, standalone Limitador) | ⏳ planned (source-build spike) |
| **P4** | `praxis-p4` | PPE `ratelimit/limitador` plugin (request-count, embedded) | ⏳ planned (source-build spike) |
| **K-TRLP** | Istio gateway | Kuadrant `TokenRateLimitPolicy` | ⏳ planned |
| **K-RLP** | Istio gateway | Kuadrant `RateLimitPolicy` | ⏳ planned |

Each Praxis offering runs in its **own namespace** (`praxis-p1` … `praxis-p4`) with a
Deployment+Service named `praxis-ai`, and gets a **dedicated local port** when port-forwarded.

## Prerequisites

`docker`, `kind`, `helm`, `kubectl`, `git`, `openssl`. Praxis AI is built from source (cloned
automatically), so a working Docker build environment is needed.

## Quick start

```sh
make setup                        # cluster -> deps -> kuadrant -> upstream -> jwt-issuer -> gateways

# in separate terminals (one port per gateway):
./test/port-forward.sh p2         # P2 token_rate_limit -> http://localhost:8082
./test/test-token-rate-limit.sh   # ~Nx HTTP 200, then HTTP 429 with X-RateLimit-*-Tokens headers

./test/port-forward.sh p1         # P1 rate_limit       -> http://localhost:8081
./test/port-forward.sh istio      # Istio gateway       -> http://localhost:8080
```

Port map: `p1`→8081, `p2`→8082, `p3`→8083, `p4`→8084, `istio`→8080 (override with `LOCAL_PORT=`).

The per-tier JWTs are written to `.cache/tokens/{gold,silver,enterprise,notier}.jwt`; send one with
`-H "Authorization: Bearer $(cat .cache/tokens/gold.jwt)"` and (for P2's current config) an
`-H 'x-tier: gold'` header.

## Make targets

```
make help           # list targets
make setup          # full setup
make cluster        # kind cluster
make deps           # Gateway API + cert-manager + Istio (helm)
make kuadrant       # Kuadrant operator + CR (helm)
make upstream       # shared upstream (inference-sim + multi-model mockserver)
make jwt-issuer     # static-JWKS JWT issuer + mint per-tier test tokens
make istio-gateway  # Istio gateway + HTTPRoute
make praxis-image   # build Praxis AI image (token-rate-limit-filter) + load into kind
make praxis         # deploy P1 + P2 gateways
make praxis-p1      # deploy P1 (rate_limit)        -> ns praxis-p1, port 8081
make praxis-p2      # deploy P2 (token_rate_limit)  -> ns praxis-p2, port 8082
make test           # token rate limit test (needs: port-forward p2)
make cleanup        # delete the kind cluster
```

Each step has a matching script in `scripts/` and is idempotent, so you can re-run any one
on its own.

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
  praxis/{p1,p2,...}/ # one dir per offering: configmap + deployment + service
  istio/ kuadrant/    # Istio gateway, Kuadrant CR (+ policies, planned)
test/                 # port-forward + token rate limit test (acceptance harness planned)
CLAUDE.md             # detailed design notes, pinned versions, gotchas, next steps
```

See [`CLAUDE.md`](CLAUDE.md) for the full design, routing table, and known gotchas.
