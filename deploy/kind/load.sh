#!/usr/bin/env bash
# Sends steady load to /token so the HPAs scale the API (and the Go service) up.
#   ./deploy/kind/load.sh            # 3 minutes, 8 parallel clients
#   DURATION=300 CLIENTS=12 ./deploy/kind/load.sh
# Watch in another terminal:  kubectl -n token-service get hpa,pods -w
# Each client has its own JWT client id, so the per-client rate limit
# (RATE_LIMIT_PER_MINUTE) doesn't cap the test.
set -uo pipefail
cd "$(dirname "$0")/../.."
API="${API_URL:-http://127.0.0.1:8080}"
DURATION="${DURATION:-180}"; CLIENTS="${CLIENTS:-8}"
IMAGE=$(kubectl -n token-service get deploy token-service-api -o jsonpath='{.spec.template.spec.containers[0].image}')

worker() {
  local jwt=$1 end=$((SECONDS + DURATION))
  while (( SECONDS < end )); do
    curl -s -o /dev/null -w '%{http_code}\n' -X POST "$API/token" -H "Authorization: Bearer $jwt" \
      -H "Content-Type: application/json" -d '{"user_email":"alice@example.com"}'
  done
}
out=$(mktemp)
for i in $(seq 1 "$CLIENTS"); do
  jwt=$(docker run --rm --user "$(id -u):$(id -g)" \
    -v "$PWD/secrets/jwt_dev_private.pem:/run/dev/jwt.key:ro" -v "$PWD/scripts/dev_token.py:/run/dev/dev_token.py:ro" \
    "$IMAGE" python /run/dev/dev_token.py "load-client-$i" token:mint $((DURATION + 300)))
  worker "$jwt" >> "$out" &
done
echo "load: $CLIENTS clients for ${DURATION}s against $API"
for _ in $(seq 1 $((DURATION / 30))); do
  sleep 30
  kubectl -n token-service get hpa --no-headers 2>/dev/null | awk '{print "  " $1 ": " $3 " replicas " $6}'
done
wait
echo "responses:"; sort "$out" | uniq -c | awk '{print "  " $2 " x " $1}'; rm -f "$out"
kubectl -n token-service get hpa
