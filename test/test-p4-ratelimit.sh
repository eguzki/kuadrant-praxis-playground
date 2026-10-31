#!/usr/bin/env bash
# Exercise offering P4 -- Praxis PPE ratelimit/limitador plugin (request-count,
# embedded in-memory Limitador).
#
# Prereq: port-forward the P4 gateway in another terminal:
#   ./test/port-forward.sh p4          # -> http://localhost:8084
#
# What it checks (request-COUNT, per the policy doc config/praxis/p4/configmap.yaml):
#   gold       -> 5 per 60s   (M5 budget keyed on tier)
#   silver     -> 2 per 60s
#   basic      -> 3 per 60s   (default/catch-all tier)
#   enterprise -> EXEMPT      (APL when-gate; plugin never runs -> no 429)
#   notier     -> DENIED      (tier binding missing -> plugin denies before counting)
# And M1 (limited-vs-exempt) + M5 (independent per-tier budgets) fall out of the above.
#
# NOTE: embedded counters are in-process and per-replica; they reset on pod
# restart. Budgets are small on purpose. Re-run after the 60s window to reset.
source "$(dirname "$0")/../scripts/lib.sh"
source "$(dirname "$0")/../scripts/lib-jwt.sh"

BASE_URL="${BASE_URL:-http://localhost:8084}"
BODY='{"model":"mock","messages":[{"role":"user","content":"hi"}]}'

# hammer <tier> <n>: send n requests with the tier's JWT, print HTTP codes.
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

echo "P4 request-count rate limiting @ ${BASE_URL}"
echo "Expect: gold 200x5 then 403/429; silver 200x2 then ...; basic 200x3 then ...;"
echo "        enterprise all 200 (exempt); notier denied."
echo

hammer gold 6
hammer silver 3
hammer basic 4
hammer enterprise 6
hammer notier 2

echo
echo "M5 independence: after the above, gold+silver budgets are separate counters."
echo "(Re-run once the 60s window elapses to see them reset.)"
