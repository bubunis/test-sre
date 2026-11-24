#!/usr/bin/env bash
# Checks the network and admission policies (PR 7) on the kind cluster:
#   - only the API can reach the Go service, Postgres and Redis   (QA finding F1)
#   - only the collector and Grafana can reach Loki and Tempo     (F9)
#   - Argo CD (GITOPS=1 only): every app synced and healthy, drift is undone
#   - the HPAs get CPU metrics
# Same on a Mac and in CI. Run after up.sh.
set -uo pipefail
cd "$(dirname "$0")/../.."
NS=token-service
pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass+1)); }
bad() { echo "  FAIL  $*"; fail=$((fail+1)); }
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
retry() { local until=$((SECONDS + $1)); shift; until "$@" >/dev/null 2>&1; do (( SECONDS < until )) || return 1; sleep 3; done; }

GRPCURL=fullstorydev/grpcurl:v1.9.1
CURL=curlimages/curl:8.11.1
json_str() { local v=${1//\\/\\\\}; v=${v//\"/\\\"}; printf '"%s"' "$v"; }
# A short-lived pod that satisfies the "restricted" Pod Security level. $1 namespace, $2 image, $3 labels JSON, $4 command|args,
# rest = the words of that command/args. Prints the pod's output.
run_pod() {
  local ns=$1 image=$2 labels=$3 field=$4 name="qa-$RANDOM"; shift 4
  local words="" w
  for w in "$@"; do words+="$(json_str "$w"),"; done
  kubectl -n "$ns" run "$name" --rm -i --restart=Never --quiet --image="$image" --pod-running-timeout=60s \
    --overrides="{\"metadata\":{\"labels\":$labels},\"spec\":{
      \"securityContext\":{\"runAsNonRoot\":true,\"runAsUser\":65532,\"seccompProfile\":{\"type\":\"RuntimeDefault\"}},
      \"volumes\":[{\"name\":\"p\",\"configMap\":{\"name\":\"token-proto\",\"optional\":true}}],
      \"containers\":[{\"name\":\"$name\",\"image\":\"$image\",\"$field\":[${words%,}],
        \"volumeMounts\":[{\"name\":\"p\",\"mountPath\":\"/p\"}],
        \"resources\":{\"requests\":{\"cpu\":\"10m\",\"memory\":\"16Mi\"},\"limits\":{\"memory\":\"64Mi\"}},
        \"securityContext\":{\"allowPrivilegeEscalation\":false,\"capabilities\":{\"drop\":[\"ALL\"]}}}]}}" 2>&1
}
mint_from() {  # mint_from <namespace> <labels JSON> -> grpcurl output
  run_pod "$1" "$GRPCURL" "$2" args \
    -plaintext -max-time 5 -import-path /p -proto token.proto \
    -d '{"user_email":"policy-check@example.com"}' \
    "token-service-grpc.$NS:50051" token.TokenService/MintToken
}
cant_mint_from() {  # grpcurl ran and timed out (not: the pod was refused, which proves nothing)
  local out; out=$(mint_from "$@")
  ! grep -q '"token"' <<<"$out" && grep -qi 'deadline\|timeout\|timed out' <<<"$out"
}
# The real API pod can still mint over gRPC (proves the blocked tests aren't just broken)
api_can_mint() {
  kubectl -n "$NS" exec deploy/token-service-api -- python -c '
import grpc, os, token_pb2, token_pb2_grpc
ch = grpc.insecure_channel(os.environ["TOKEN_SERVICE_HOST"])
r = token_pb2_grpc.TokenServiceStub(ch).MintToken(token_pb2.MintTokenRequest(user_email="policy-check@example.com"), timeout=5)
print("token" if r.token else "none")' 2>&1 | grep -qx token
}
# curl exit code 28 = timed out, i.e. dropped by a policy; anything else = it got through
blocked() {  # blocked <namespace> <url>
  run_pod "$1" "$CURL" '{}' command sh -c "curl -s -o /dev/null -m 4 '$2'; echo rc=\$?" | grep -q 'rc=28'
}

for ns in default "$NS"; do
  kubectl -n "$ns" create configmap token-proto --from-file=protos/token.proto --dry-run=client -o yaml \
    | kubectl -n "$ns" apply -f - >/dev/null
done
trap 'for ns in default '"$NS"'; do kubectl -n $ns delete configmap token-proto --ignore-not-found >/dev/null; done' EXIT

echo "Network policies"
check "API pod can still mint (control)"       api_can_mint
check "pod in 'default' can't mint (F1)"       cant_mint_from default '{}'
check "other pod in token-service can't mint"  cant_mint_from "$NS" '{"app":"other"}'
check "pod in 'default' can't reach Postgres"  blocked default "http://token-service-postgres.$NS:5432"
check "pod in 'default' can't reach Redis"     blocked default "http://token-service-redis.$NS:6379"
check "pod in 'default' can't reach Loki (F9)" blocked default "http://loki.observability:3100/ready"
check "pod in 'default' can't reach Tempo"     blocked default "http://tempo.observability:3200/ready"
check "API still ready (its own paths open)"   test "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/readyz)" = 200

if kubectl get ns argocd >/dev/null 2>&1; then
  echo "GitOps (Argo CD)"
  apps_ok() {
    kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.status.sync.status}/{.status.health.status}{"\n"}{end}' \
      | grep -v '^Synced/Healthy$' | grep -q . && return 1 || return 0
  }
  check "all Argo CD applications Synced/Healthy" retry 300 apps_ok
  # drift: delete a NetworkPolicy by hand; self-heal must put it back from git
  kubectl -n "$NS" delete networkpolicy token-service-grpc --wait=true >/dev/null 2>&1
  check "deleted NetworkPolicy restored by Argo CD" retry 120 kubectl -n "$NS" get networkpolicy token-service-grpc
  kubectl -n argocd get applications
fi

echo "Autoscaling"
hpa_has_metrics() {
  for h in token-service-api token-service-grpc; do
    [[ -n "$(kubectl -n $NS get hpa "$h" -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)" ]] || return 1
  done
}
check "metrics-server answers"               retry 90 kubectl top nodes
check "both HPAs read CPU usage"             retry 120 hpa_has_metrics
kubectl -n "$NS" get hpa

echo
echo "passed: $pass  failed: $fail"
[[ $fail == 0 ]]
