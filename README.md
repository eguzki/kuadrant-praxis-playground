# kuadrant-praxis-playground

Local [kind](https://kind.sigs.k8s.io/) environment to test **token rate limiting** on two
AI gateways that share one upstream:

- **Kuadrant 1.6.0 + Istio**, with one Istio-managed gateway (pass-through for now).
- **Praxis AI gateway** enforcing token rate limiting natively via its `token_rate_limit` filter.
- A **shared upstream** — [`llm-d-inference-sim`](https://github.com/llm-d/llm-d-inference-sim)
  (OpenAI, real token usage) + MockServer (Anthropic/Gemini shapes) — fronted by both gateways.

Everything installs via Helm charts (Kuadrant, Istio, cert-manager) on a kind cluster.

## Prerequisites

`docker`, `kind`, `helm`, `kubectl`, `git`. Praxis AI is built from source (cloned
automatically), so a working Docker build environment is needed.

## Quick start

```sh
make setup                        # cluster -> deps -> kuadrant -> upstream -> gateways -> praxis
                                  # (the Praxis Rust image build is the slow step)

# in separate terminals:
./test/port-forward.sh praxis     # Praxis AI gateway  -> http://localhost:8080
./test/test-token-rate-limit.sh   # ~8x HTTP 200, then HTTP 429

./test/port-forward.sh istio      # Istio gateway (pass-through) -> http://localhost:8080
```

Expected test output: ~8 requests admitted (each reconciled to the real ~20 tokens the
inference-sim reports), then `429` with `X-RateLimit-*-Tokens` headers.

## Make targets

```
make help           # list targets
make setup          # full setup (runs steps 00-06)
make cluster        # kind cluster
make deps           # Gateway API + cert-manager + Istio (helm)
make kuadrant       # Kuadrant operator + CR (helm)
make upstream       # shared upstream (inference-sim + mockserver)
make istio-gateway  # Istio gateway + HTTPRoute
make praxis-image   # build Praxis AI image (token-rate-limit-filter) + load into kind
make praxis         # deploy Praxis AI gateway
make test           # run the token rate limit test (needs port-forward praxis)
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

Versions, image tags, and namespaces live in [`scripts/lib.sh`](scripts/lib.sh) and can be
overridden via environment variables, e.g.:

```sh
KUADRANT_VERSION=1.6.0 ISTIO_VERSION=1.29.1 ./scripts/setup.sh
PRAXIS_AI_SRC=/path/to/ai ./scripts/05-build-praxis-image.sh   # build an existing checkout
```

## Layout

```
Makefile              # convenience targets
scripts/              # numbered setup steps (00-06) + setup.sh / cleanup.sh / lib.sh
config/               # kind, istio, kuadrant, upstream, praxis manifests
test/                 # port-forward + token rate limit test
CLAUDE.md             # detailed design notes, pinned versions, gotchas, next steps
```

See [`CLAUDE.md`](CLAUDE.md) for the full design, routing table, and known gotchas.
