# Acceptance tests (M1–M7) — procedures & results

How each of the six rate-limiting **offerings** was exercised on the kind cluster against
proposal `00121`'s must-haves **M1–M7**, and the observed result per criterion. This is the
"verify the [praxis-proxy/policy#200](https://github.com/praxis-proxy/policy/issues/200)
findings in a live cluster" deliverable.

These tests are **run manually** (port-forward + `curl`, or the small per-offering helper
scripts under `test/`) — there is intentionally no unified runner. The narrative detail behind
every score is in **CLAUDE.md → "Live-validation findings (issue #200)"**; this file is the
spec + procedure + matrix.

## Criteria

Canonical definitions are in #200 / proposal `00121`; **M1 and M5 were refined** for this
exercise (recorded in the #200 comment).

| # | Criterion | What it means |
|---|---|---|
| **M1** | Applicability | A request is **limited vs exempt** by rules keyed on **model / operation-path / claim**, with a **default** (catch-all) budget and an **exemption** (e.g. enterprise = unlimited). |
| **M2** | Reserve → reconcile | Reserve an amount at admission, then **reconcile** against the actual usage reported in the response. |
| **M3** | Estimation | The reserved amount is an **estimate** (ideally derived from the request, e.g. body `max_tokens`). |
| **M4** | Token-type weighting | Actual usage is **weighted by token type** (e.g. cached input discounted vs completion). |
| **M5** | Multiple budgets + keys | Several **independent budgets**, each keyed on a dimension (model / tier / user). |
| **M6** | Denial semantics | Over-budget returns **HTTP 429** with rate-limit headers (`X-RateLimit-*`, `Retry-After`). |
| **M7** | Observability | Metrics, spans, and/or accounting logs. |
| S1 | (stretch) Shadow | Observe-only mode (count, don't enforce). |

Legend: ✅ supported/verified · 🟡 partial · ❌ not supported · **N/A** not applicable.

## Prerequisites

```sh
make setup                 # full stack (all six offerings); see README / scripts/setup.sh
```

Per-tier JWTs are minted into `.cache/tokens/{gold,silver,enterprise,basic,notier}.jwt`
(`gold`/`silver`/`enterprise` carry a `tier` claim; `basic` = a non-premium tier for the
default bucket; `notier` = a valid token with **no** `tier` claim). Port-forward one gateway
per terminal (`test/port-forward.sh <p1|p2|p3|p4|istio>`): `p1→8081 p2→8082 p3→8083 p4→8084
istio→8080`.

A tiered request looks like:

```sh
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:<port>/v1/chat/completions \
  -H "Authorization: Bearer $(cat .cache/tokens/gold.jwt)" \
  -H 'Content-Type: application/json' \
  -d '{"model":"mock","messages":[{"role":"user","content":"hello there"}]}'
```

## Procedures & observed results

### P1 — core `rate_limit` (request-count) · ns `praxis-p1`, port 8081
- **Procedure:** `test/port-forward.sh p1`, then send `/v1/chat/completions` repeatedly and
  watch 200 flip to 429 (`rate: 1`, `burst: 5`, `mode: per_ip`). No tokens needed.
- **Observed:** request-count admission only; limited by IP/global, not by model/claim; not
  token-denominated. *(Deployed; scores per #200 prediction, not yet live-confirmed.)*
- **Scores:** M1 🟡 · M5 ❌ · M6 ✅ (`X-RateLimit-*` on 200 **and** 429) · M7 🟡 · S1 🟡
  (`shadow: true`) · **M2/M3/M4 N/A** (request-count).

### P2 — `token_rate_limit` filter (native, token) · ns `praxis-p2`, port 8082
- **Procedure:** `test/port-forward.sh p2`, then `BASE_URL=http://localhost:8082
  ./test/test-token-rate-limit.sh` (8×200 → 429). For the tiered/model matrix send the
  per-tier tokens with `model: gpt-4o` / `gpt-4o-mini` and inspect `praxis_trl_*` at
  `:9901/metrics`.
- **Observed (all live-verified):** M1 tiered `rules` + catch-all; M2 `tokens_reserved_total`→
  `tokens_reconciled_total`; M3 `strategy: max_tokens` reserves 100/2000/50 from body
  `max_tokens`; M4 weighted reconcile (gpt-4o 3000 incl. 2000 cached → `actual=1700` with
  `cached_input: 0.1`); M5 compound `(model, tier)` keys; M6 429 + `X-RateLimit-*-Tokens`
  (on 429 only); M7 `praxis_trl_*` + accounting logs.
- **Scores:** **M1–M7 all ✅.** Caveats: enterprise exemption is *approximated* (huge-capacity
  rule, no native skip); `x-tier` is a client header, not a verified-JWT claim.

### P3 — PPE `quota/limitador` (token, standalone Limitador) · ns `praxis-p3`, port 8083
- **Procedure:** `test/port-forward.sh p3`, then send the tiered tokens (`gold` 7000 / `silver`
  4000 / `enterprise` unmetered token budget/60s). Watch 200→**403** when a tier's budget is
  spent; `enterprise` stays 200.
- **Observed:** enforces per-tier via APL (`when claim.tier != enterprise → run`) + Limitador
  `descriptors[0]["tier"]` limits. Debit is check-probe + post-response `/report` (no
  reservation). Model-capable (acts at `cmf.llm_input`, sees the body), though configured on
  `tier`.
- **Scores:** M1 ✅ · M5 ✅ (per-tier; single-descriptor, so no compound model+tier in one rule)
  · M6 ❌ (**403**, no `X-RateLimit-*`/`Retry-After`) · M7 🟡 (`tracing` only) · **M2 ❌** (debit
  after, not a reservation) · **M3 ❌ / M4 ❌** (no estimation, flat `total_tokens`, no weights).

### P4 — PPE `ratelimit/limitador` (request-count, embedded) · ns `praxis-p4`, port 8084
- **Procedure:** `test/port-forward.sh p4`, then `./test/test-p4-ratelimit.sh` — gold 5→429,
  silver 2→429, basic 3→429, enterprise all 200, notier 400 (missing `tier`), unauth 401.
- **Observed:** per-tier request budgets at the `ratelimit.post_identity` hook (pre-body),
  keyed on `tier` claim + per-user; enterprise exempt via conditions.
- **Scores:** M1 🟡 (claim/path, **no body-`model`** — hook is pre-body) · M5 🟡 (per-tier keys,
  no model-keyed budgets) · M6 🟡 (**429**, no headers) · M7 🟡 (`tracing` only) · **M2/M3/M4
  N/A** (request-count).

### K-TRLP — Kuadrant `TokenRateLimitPolicy` (token) · Istio gateway, port 8080
- **Procedure:** `test/port-forward.sh istio`, then `./test/test-k-trlp.sh` — gold 4→429,
  silver 2→429, basic 3→429, enterprise all 200, no-token 401. (`Reservation` mode: reserve
  `reservation.amount`, commit actual `usage.total_tokens`.)
- **Observed:** token-denominated per-tier budgets keyed per user (`auth.identity.sub`), gated
  by `auth.identity.tier`; enterprise exempt via conditions; reserve→reconcile confirmed (gold
  admits 4, not `limit/amount`, proving over-reservation is released).
- **Scores:** M1 🟡 (claim/path, **no body-`model`** — CONNLINK-1608) · M2 ✅ (reserve→reconcile)
  · M3 🟡 (estimate is static/claim, **can't read body `max_tokens`**) · M4 ❌ (flat
  `total_tokens`, no token-type weights) · M5 🟡 (per-tier/user keys, no model-keyed budgets) ·
  M6 🟡 (**429**, no `X-RateLimit-*`/`Retry-After`) · M7 ✅ (Kuadrant/Limitador metrics + Istio
  telemetry).

## Results matrix (observed)

| Criterion | P1 `rate_limit` | P2 `token_rate_limit` | P3 `quota/limitador` | P4 `ratelimit/limitador` | K-TRLP |
|---|:---:|:---:|:---:|:---:|:---:|
| **M1** applicability (model/path/claim) | 🟡 | ✅ | ✅ | 🟡 | 🟡 |
| **M2** reserve → reconcile | N/A | ✅ | ❌ | N/A | ✅ |
| **M3** estimation | N/A | ✅ | ❌ | N/A | 🟡 |
| **M4** token-type weighting | N/A | ✅ | ❌ | N/A | ❌ |
| **M5** multiple budgets + keys | ❌ | ✅ | ✅ | 🟡 | 🟡 |
| **M6** 429 + rate-limit headers | ✅¹ | ✅ | ❌² | 🟡³ | 🟡³ |
| **M7** observability | 🟡 | ✅ | 🟡 | 🟡 | ✅ |

¹ P1 injects `X-RateLimit-*` on both 200 and 429 (predicted; not live-confirmed).
² P3 denies with **403**, no rate-limit headers.
³ P4/K-TRLP deny with **429** but emit no `X-RateLimit-*`/`Retry-After`.

**Cross-cutting:** the request-body **`model`** is only usable as a key by offerings that read
the body (**P2** via `model_to_header`, **P3** via `cmf.llm_input`). The pre-body offerings
(**P1**, **P4**, **K-TRLP** — the last blocked by Envoy/CONNLINK-1608) can key on claim/path/user
but **not model**, which is why their **M1/M5 are 🟡**. Only **P2** demonstrates the full token
pipeline (M2–M4); **K-TRLP** adds reserve→reconcile (M2) but with a static estimate (M3 🟡) and
no token-type weighting (M4 ❌).
