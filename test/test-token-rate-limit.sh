#!/usr/bin/env bash
# Exercise token rate limiting on the Praxis AI gateway.
#
# Prereq: port-forward the P2 (token_rate_limit) gateway in another terminal:
#   ./test/port-forward.sh p2
#
# With the playground config (window=1m, capacity=200, reserved_tokens=50) and
# the inference-sim reporting ~20 tokens/response, ~8 requests are admitted per
# minute: each reserves 50 at admission, then reconciles down to the real ~20,
# so a 9th request can't get its 50-token headroom and gets HTTP 429.
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8082}"
COUNT="${COUNT:-8}"
BODY='{"model":"mock","messages":[{"role":"user","content":"Tell me a three sentence bedtime story about a unicorn."}]}'

echo "POST ${BASE_URL}/v1/chat/completions x ${COUNT}"
echo "Expect: 200 (admitted) flipping to 429 once the token budget is exhausted."
echo

headers_file="$(mktemp)"
body_file="$(mktemp)"
trap 'rm -f "${headers_file}" "${body_file}"' EXIT

for i in $(seq 1 "${COUNT}"); do
  code=$(curl -s -D "${headers_file}" -o "${body_file}" -w '%{http_code}' \
    "${BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "${BODY}" || echo "000")

  rl=$(grep -i 'x-ratelimit' "${headers_file}" | tr -d '\r' | paste -sd' ' - || true)
  printf 'request %-2s -> HTTP %s   %s\n' "$i" "$code" "${rl}"
done

echo
echo "Last response body:"
head -c 800 "${body_file}" || true
echo
