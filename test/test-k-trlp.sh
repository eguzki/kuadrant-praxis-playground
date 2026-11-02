#!/usr/bin/env bash
# Exercise the Kuadrant K-TRLP arm (TokenRateLimitPolicy + AuthPolicy) on the
# Istio gateway.
#
# Prereq: port-forward the Istio gateway in another terminal:
#   ./test/port-forward.sh istio        # -> http://localhost:8080
#
# Token-DENOMINATED limits (Kuadrant extracts usage.total_tokens from the
# response). Budgets in config/kuadrant/tokenratelimitpolicy.yaml are sized to the
# inference-sim echo backend, which returns ~4 total_tokens for the fixed prompt
# below, so:
#   gold       20 tok/60s  -> ~5 requests then 429
#   silver      8 tok/60s  -> ~2 requests then 429
#   basic      12 tok/60s  -> ~3 requests then 429   (default/catch-all tier)
#   enterprise unlimited    -> all 200 (no limit matches the tier)
#   notier     -> depends on how the CEL predicate treats a missing claim (observed below)
#   no token   -> 401 (AuthPolicy rejects)
#
# NOTE: optimistic mode commits the actual token count AFTER each response, so the
# request that tips over the budget is the one denied. Re-run after the 60s window.
source "$(dirname "$0")/../scripts/lib.sh"
source "$(dirname "$0")/../scripts/lib-jwt.sh"

BASE_URL="${BASE_URL:-http://localhost:8080}"
# Fixed prompt -> deterministic ~4 total_tokens on the echo backend.
BODY='{"model":"mock","messages":[{"role":"user","content":"hello there"}]}'

hammer() {
  local tier="$1" n="$2" tok code i
  tok="$(jwt_token "${tier}")"
  printf '%-11s (x%s): ' "${tier}" "${n}"
  for i in $(seq 1 "${n}"); do
    code=$(curl -s -o /dev/null -w '%{http_code}' \
      "${BASE_URL}/v1/chat/completions" \
      -H "Authorization: Bearer ${tok}" \
      -H "Content-Type: application/json" \
      -d "${BODY}" || echo "000")
    printf '%s ' "${code}"
  done
  printf '\n'
}

echo "K-TRLP token rate limiting @ ${BASE_URL}"
echo "Expect: gold ~5×200→429, silver ~2→429, basic ~3→429, enterprise all 200, no-token 401."
echo

hammer gold 6
hammer silver 3
hammer basic 4
hammer enterprise 6
hammer notier 3
printf '%-11s (x1): ' "no-token"
curl -s -o /dev/null -w '%{http_code}\n' "${BASE_URL}/v1/chat/completions" \
  -H "Content-Type: application/json" -d "${BODY}" 2>/dev/null
