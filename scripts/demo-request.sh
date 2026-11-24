#!/usr/bin/env bash
# Sends one POST /token and prints how to find that request everywhere:
# its trace in Tempo and its log lines (both services) in Loki.
#   bash scripts/demo-request.sh                        # Docker Compose (:8000)
#   API=http://127.0.0.1:8080 bash scripts/demo-request.sh   # kind
#   EMAIL=bob@example.com bash scripts/demo-request.sh
set -euo pipefail
cd "$(dirname "$0")/.."
API="${API:-http://localhost:8000}"
EMAIL="${EMAIL:-alice@example.com}"

if [[ "$API" == *":8080"* ]] && command -v kubectl >/dev/null; then
  # kind: sign the JWT with the API image already loaded on this machine
  IMAGE=$(kubectl -n token-service get deploy token-service-api -o jsonpath='{.spec.template.spec.containers[0].image}')
  JWT=$(docker run --rm --user "$(id -u):$(id -g)" \
    -v "$PWD/secrets/jwt_dev_private.pem:/run/dev/jwt.key:ro" -v "$PWD/scripts/dev_token.py:/run/dev/dev_token.py:ro" \
    "$IMAGE" python /run/dev/dev_token.py)
else
  JWT=$(bash scripts/dev-token.sh)
fi

headers=$(mktemp); trap 'rm -f "$headers"' EXIT
body=$(curl -s -D "$headers" -X POST "$API/token" -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" -d "{\"user_email\":\"$EMAIL\"}")
status=$(head -1 "$headers" | awk '{print $2}')
trace_id=$(grep -i '^x-trace-id:' "$headers" | awk '{print $2}' | tr -d '\r')

echo "POST /token for $EMAIL -> HTTP $status"
echo "permissions: $(echo "$body" | sed -n 's/.*"permissions": *\(\[[^]]*\]\).*/\1/p')"
echo
echo "trace id: $trace_id"
echo
echo "Grafana (http://127.0.0.1:3000) -> Explore:"
echo "  Tempo:  $trace_id"
echo "  Loki:   {service_name=~\"python-token-service|go-token-service\"} | trace_id=\"$trace_id\""
echo
echo "Give it ~10 seconds to arrive (the collector sends in batches)."
