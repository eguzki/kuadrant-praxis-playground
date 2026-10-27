# Findings — live validation of issue [praxis-proxy/policy#200](https://github.com/praxis-proxy/policy/issues/200)

Parking lot for things learned while exercising the offerings on the kind cluster.
Feeds the per-offering M1–M7 scoring in the issue comment.

## Infra / setup gotchas

- **MockServer rejects JSON comment keys.** `mockserver/mockserver:8.0.0` validates the
  initialization JSON strictly (`additionalProperties: false`). A `"//": "..."` comment key
  in any expectation makes it reject the **entire** file → 0 expectations loaded → every
  request 404/502. Keep `config/upstream/mockserver-expectations.json` comment-free.
- **Praxis metrics need an `admin` block, bound to 0.0.0.0.** The Prometheus recorder is
  only installed when `admin.address` or `admin.metrics_address` is set; `/metrics` (incl.
  all `praxis_trl_*`) is absent otherwise. The default binds `127.0.0.1:9901`, which a
  `kubectl port-forward` can't reach — use `admin.metrics_address: "0.0.0.0:9901"`.
- **502 with no Praxis error log = the upstream returned 502.** Praxis passes it through; it
  is not necessarily the private-IP dial guard. Enable `runtime.log_overrides` for
  `pingora_core`/`pingora_proxy` at `debug` to see the actual upstream response.

## P2 — `token_rate_limit` (native) — LIVE VERIFIED

Config: `config/praxis/p2/configmap.yaml`. Upstream = MockServer (model-varied usage).

- **M1 (limited vs exempt + default): ✅** `tier=enterprise` → not limited; gold/silver/none
  → limited; catch-all `default` works.
- **M2 (reserve→reconcile): ✅** reserve `reserved_tokens` at admission, reconcile to actual
  usage (metrics `tokens_reserved_total` → `tokens_reconciled_total`; accounting log
  `phase=admission`/`reconciliation`).
- **M4 (token-type weights): ✅** gpt-4o response (prompt 3000 / cached 2000 / completion 500)
  reconciled to **`actual=1700`** = `(3000−2000)×1 + 2000×0.1 + 500×1`, not raw
  `total_tokens=3500`. `cached_input: 0.1` weight applied.
- **M5 (multiple budgets, compound keys): ✅** compound `(model, tier)` key →
  `premium` (gold+gpt-4o) / `gold-basic` (gold+gpt-4o-mini) / `silver-basic` (silver) fire
  correctly and discriminate by **both** model and tier.
- **M6 (hard 429 + headers): ✅** 429 with `Retry-After`, `X-RateLimit-Limit-Tokens`,
  `-Remaining-Tokens`, `-Reset-Tokens`. **Note:** these headers appear on **429 only**, not
  on admitted 200 responses.
- **M7 (observability): ✅** metrics `praxis_trl_*` (`requests_total{result,rule}`,
  `tokens_reserved/reconciled/refunded/overage_total`, `budget_remaining{rule}`,
  `active_keys`, `reservations_active`) + accounting logs on target
  `praxis_ai::token_rate_limit::accounting`.
- **Model-based rule matching WORKS.** `model_to_header` promotes body `model` → `X-Model`,
  and `token_rate_limit` sees it at admission (so `premium`'s `x-model: gpt-4o` match fires).
  An earlier report that model-match failed was **not reproducible** (config-iteration
  artifact); the current reproducible result is authoritative.
- **No explicit skip/allow action.** `token_rate_limit` rules always apply a budget; the M1
  `enterprise` **bypass is approximated** with an effectively-unlimited-capacity rule
  (`capacity: 1_000_000_000`). A native "exempt" action would be cleaner.

## P1 — core `rate_limit` (request-count)

Config: `config/praxis/p1/configmap.yaml`.

- Token-bucket **request-count** limiter; keys only `global` or `per_ip` (no model/claim/
  subject). Decides pre-body.
- #200 predicted: **M1 🟡, M5 ❌, M6 ✅, M7 🟡, S1 🟡 (shadow); M2/M3/M4 N/A** (not
  token-denominated). Live confirmation pending.

## Open / to confirm later

- M5 budget **independence** (exhausting one budget must not 429 another) — shown
  structurally (separate rules+keys) but not yet exhaustion-tested.
- P3/P4/K-TRLP/K-RLP: not yet exercised.
- Verified-JWT-claim → `x-tier` wiring on P2 (currently a client header).
