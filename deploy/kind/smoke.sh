#!/usr/bin/env bash
# End-to-end checks against the kind deployment. Same on a Mac and in CI.
#   ./deploy/kind/smoke.sh             # functional + security checks (~20 s)
#   CHAOS=1 ./deploy/kind/smoke.sh     # + take Redis away and back (~1-2 min)
set -uo pipefail
cd "$(dirname "$0")/../.."
source deploy/kind/platform.sh

NS=token-service
API="${API_URL:-http://127.0.0.1:8080}"
pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass+1)); }
bad() { echo "  FAIL  $*"; fail=$((fail+1)); }
check() { local name=$1; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi; }
k() { kubectl -n "$NS" "$@"; }

describe_platform
echo "API: $API"

# --- wait for the API ---------------------------------------------------------
for _ in $(seq 1 30); do
  [[ "$(curl -s -o /dev/null -w '%{http_code}' "$API/readyz")" == 200 ]] && break
  sleep 2
done

# --- dev JWTs, signed inside the API image that runs in the cluster -----------
# (PyJWT is already there; the private key is mounted read-only, never copied in)
IMAGE=$(k get deploy token-service-api -o jsonpath='{.spec.template.spec.containers[0].image}')
jwt() {
  docker run --rm --user "$(id -u):$(id -g)" \
    -v "$PWD/secrets/jwt_dev_private.pem:/run/dev/jwt.key:ro" \
    -v "$PWD/scripts/dev_token.py:/run/dev/dev_token.py:ro" \
    "$IMAGE" python /run/dev/dev_token.py "${1:-login-service}" "${2:-token:mint}" "${3:-300}"
}
code() {  # code <email> [curl args...]  -> HTTP status of POST /token
  local email=$1; shift
  curl -s -o /dev/null -w '%{http_code}' -X POST "$API/token" \
    -H "Content-Type: application/json" -d "{\"user_email\":\"$email\"}" "$@"
}
JWT=$(jwt)

echo "Functional"
check "readyz is 200"                  test "$(curl -s -o /dev/null -w '%{http_code}' "$API/readyz")" = 200
check "no JWT -> 401"                  test "$(code alice@example.com)" = 401
check "wrong scope -> 403"             test "$(code alice@example.com -H "Authorization: Bearer $(jwt login-service profile)")" = 403
check "expired JWT -> 401"             test "$(code alice@example.com -H "Authorization: Bearer $(jwt login-service token:mint -120)")" = 401
check "unknown user -> 404"            test "$(code nobody@example.com -H "Authorization: Bearer $JWT")" = 404

RESP=$(curl -s -X POST "$API/token" -H "Authorization: Bearer $JWT" \
         -H "Content-Type: application/json" -d '{"user_email":"alice@example.com"}')
TOKEN=$(echo "$RESP" | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
check "alice gets a token"             test -n "$TOKEN"
check "alice has read:data"            grep -q 'read:data' <<<"$RESP"
REDIS_VAL=$(k exec sts/token-service-redis -- sh -c \
  "REDISCLI_AUTH=\"\$(cat /etc/secrets/redis/password)\" redis-cli GET token:$TOKEN" 2>/dev/null)
check "token stored in Redis"          grep -q 'alice@example.com' <<<"$REDIS_VAL"

echo "Cluster layout"
zone_of() { kubectl get node "$1" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'; }
zones_of() {  # distinct zones of the pods with this app label
  for n in $(k get pods -l app.kubernetes.io/name="$1" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}'); do zone_of "$n"; echo; done | sort -u | grep -c .
}
check "3 nodes Ready"                  test "$(kubectl get nodes --no-headers | grep -cw Ready)" = 3
check "control plane is tainted"       bash -c "kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].spec.taints}' | grep -q NoSchedule"
check "no app pod on the control plane" test -z "$(k get pods -o wide --no-headers | grep control-plane)"
check "API pods in 2 zones"            test "$(zones_of api)" = 2
check "Go pods in 2 zones"             test "$(zones_of grpc)" = 2

echo "Security"
check "namespace enforces 'restricted'" test "$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')" = restricted
root_pods=$(k get pods -o jsonpath='{range .items[*]}{.metadata.name}={.spec.securityContext.runAsUser}{"\n"}{end}' | grep -E '=(0)?$')
check "no pod runs as root"            test -z "$root_pods"
check "API root filesystem read-only"  bash -c "! kubectl -n $NS exec deploy/token-service-api -- touch /app/x"
check "API can't see Redis secret"     bash -c "! kubectl -n $NS exec deploy/token-service-api -- ls /etc/secrets/redis"
check "no service account token"       bash -c "! kubectl -n $NS exec deploy/token-service-api -- ls /var/run/secrets/kubernetes.io"

echo "Load balancing (info)"
for _ in $(seq 1 20); do code alice@example.com -H "Authorization: Bearer $JWT" >/dev/null; done
for p in $(k get pods -l app.kubernetes.io/name=grpc -o name); do
  n=$(kubectl get --raw "/api/v1/namespaces/$NS/pods/${p#pod/}:9090/proxy/metrics" 2>/dev/null \
      | awk '/^grpc_server_handled_total/ && /MintToken/ && /grpc_code="OK"/ {s+=$2} END {print s+0}')
  echo "  ${p#pod/}: $n MintToken calls"
done
echo "  (both should be > 0; an API pod that started before the 2nd Go pod picks it up within 2 min)"

if [[ "${CHAOS:-0}" == 1 ]]; then
  echo "Resilience: Redis goes away"
  restarts() { k get pods -l app.kubernetes.io/name=grpc -o jsonpath='{range .items[*]}{.status.containerStatuses[0].restartCount}{" "}{end}'; }
  before=$(restarts)
  k scale sts/token-service-redis --replicas=0 >/dev/null
  check "Go pods become NOT ready"     k wait pod -l app.kubernetes.io/name=grpc --for=condition=Ready=false --timeout=60s
  check "/token -> 503 while Redis is down" test "$(code alice@example.com -H "Authorization: Bearer $JWT")" = 503
  check "Go pods were not restarted"   test "$(restarts)" = "$before"
  k scale sts/token-service-redis --replicas=1 >/dev/null
  check "Redis back"                   k rollout status sts/token-service-redis --timeout=90s
  check "Go pods ready again"          k wait pod -l app.kubernetes.io/name=grpc --for=condition=Ready --timeout=60s
  sleep 3
  check "/token works again"           test "$(code alice@example.com -H "Authorization: Bearer $JWT")" = 200
fi

if [[ "${CHAOS:-0}" == 1 ]]; then
  echo "Resilience: drain a worker (node maintenance / lost zone)"
  # drain the worker that does NOT hold Postgres: its volume is local to its node
  # (kind's local-path storage), like a zonal disk in the cloud
  pg_node=$(k get pod token-service-postgres-0 -o jsonpath='{.spec.nodeName}')
  victim=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o name | grep -vx "node/$pg_node" | head -1)
  victim=${victim#node/}
  echo "  draining $victim (zone $(zone_of "$victim")); Postgres stays on $pg_node"
  errlog=$(mktemp)
  ( for _ in $(seq 1 60); do
      [[ "$(code alice@example.com -H "Authorization: Bearer $JWT")" == 200 ]] || echo x
      sleep 1
    done ) > "$errlog" &
  poller=$!
  check "drain respects PDBs and finishes" kubectl drain "$victim" --ignore-daemonsets --delete-emptydir-data --timeout=120s
  check "API back to 2 ready pods"     k rollout status deploy/token-service-api --timeout=120s
  check "Go back to 2 ready pods"      k rollout status deploy/token-service-grpc --timeout=120s
  check "Redis ready (moved if it was there)" k rollout status sts/token-service-redis --timeout=120s
  sleep 5
  check "/token works with one zone"   test "$(code alice@example.com -H "Authorization: Bearer $JWT")" = 200
  kill "$poller" 2>/dev/null; wait "$poller" 2>/dev/null
  errors=$(grep -c x "$errlog" || true); rm -f "$errlog"
  echo "  info: ${errors:-0} failed /token calls during the drain (non-zero only if Redis had to move)"
  kubectl uncordon "$victim" >/dev/null
  # Kubernetes doesn't move running pods back by itself; a rollout re-spreads them
  k rollout restart deploy/token-service-api deploy/token-service-grpc >/dev/null
  k rollout status deploy/token-service-api --timeout=120s >/dev/null
  k rollout status deploy/token-service-grpc --timeout=120s >/dev/null
  check "pods spread over 2 zones again" test "$(zones_of api)$(zones_of grpc)" = 22
fi

echo
echo "passed: $pass  failed: $fail"
[[ $fail == 0 ]]
