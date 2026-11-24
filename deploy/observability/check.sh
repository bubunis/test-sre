#!/usr/bin/env bash
# Checks the assignment's observability requirements end to end on kind:
#   metrics in Prometheus, JSON logs with trace context in Loki (no emails),
#   one trace across Python -> PostgreSQL -> Go -> Redis in Tempo, dashboards in Grafana.
# Same on a Mac and in CI. Run after deploy/kind/up.sh.
set -uo pipefail
cd "$(dirname "$0")/../.."
OBS=observability
APP=token-service
API="${API_URL:-http://127.0.0.1:8080}"
pass=0; fail=0
ok()  { echo "  PASS  $*"; pass=$((pass+1)); }
bad() { echo "  FAIL  $*"; fail=$((fail+1)); }
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
retry() {  # retry <seconds> <command...>: data needs a few seconds to arrive
  local until=$((SECONDS + $1)); shift
  until "$@" >/dev/null 2>&1; do (( SECONDS < until )) || return 1; sleep 3; done
}

# Local ports for the checks only (not the UI ports, so ui.sh can stay running)
kubectl -n $OBS port-forward --address 127.0.0.1 svc/kps-prometheus 19090:9090 >/dev/null 2>&1 &
kubectl -n $OBS port-forward --address 127.0.0.1 svc/loki 13100:3100 >/dev/null 2>&1 &
kubectl -n $OBS port-forward --address 127.0.0.1 svc/tempo 13200:3200 >/dev/null 2>&1 &
kubectl -n $OBS port-forward --address 127.0.0.1 svc/grafana 13000:80 >/dev/null 2>&1 &
trap 'kill $(jobs -p) 2>/dev/null' EXIT
sleep 3
PROM=http://127.0.0.1:19090 LOKI=http://127.0.0.1:13100 TEMPO=http://127.0.0.1:13200 GRAFANA=http://127.0.0.1:13000
GF_AUTH="admin:$(cat secrets/grafana_admin_password.txt)"

prom()  { curl -sG "$PROM/api/v1/query" --data-urlencode "query=$1"; }
loki()  { curl -sG "$LOKI/loki/api/v1/query_range" --data-urlencode "query=$1" --data-urlencode "since=15m" --data-urlencode "limit=${2:-20}"; }
has_result() { grep -q '"result":\[{' <<<"$1"; }
prom_has() { has_result "$(prom "$1")"; }     # query again on every retry
loki_has() { has_result "$(loki "$1")"; }
no_email_in_loki() { ! grep -q '@example.com' <<<"$(loki '{service_name=~".+"} |= "@example.com"' 100)"; }

echo "Stack"
check "all observability pods ready"   kubectl -n $OBS wait pod --all --for=condition=Ready --timeout=120s

# --- traffic, so there is something to find --------------------------------
IMAGE=$(kubectl -n $APP get deploy token-service-api -o jsonpath='{.spec.template.spec.containers[0].image}')
JWT=$(docker run --rm --user "$(id -u):$(id -g)" \
  -v "$PWD/secrets/jwt_dev_private.pem:/run/dev/jwt.key:ro" \
  -v "$PWD/scripts/dev_token.py:/run/dev/dev_token.py:ro" \
  "$IMAGE" python /run/dev/dev_token.py login-service token:mint 900)
for _ in $(seq 1 20); do
  curl -s -o /dev/null -X POST "$API/token" -H "Authorization: Bearer $JWT" \
    -H "Content-Type: application/json" -d '{"user_email":"alice@example.com"}'
done
curl -s -o /dev/null -X POST "$API/token" -H "Content-Type: application/json" -d '{"user_email":"alice@example.com"}'  # a 401

echo "Metrics (Prometheus)"
check "both app jobs scraped and up (4 pods)" retry 90 prom_has 'count(up{job=~"python-token-service|go-token-service"} == 1) == 4'
check "RED: HTTP request rate by status"  retry 60 prom_has 'sum by (status) (rate(http_requests_total[1m]))'
check "RED: gRPC calls by code"            prom_has 'sum by (grpc_code) (grpc_server_handled_total)'
check "DB pool metrics"                    prom_has 'db_pool_connections_max'
check "Redis queue depth metric"           prom_has 'token_events_queue_depth'
check "queue processing time histogram"    prom_has 'token_event_processing_seconds_count'
check "Kubernetes metrics (kube-state-metrics)" prom_has 'kube_deployment_status_replicas_available{namespace="token-service"}'

slo_rules() { curl -s "$PROM/api/v1/rules" | grep -q 'token-service-slo.alerts'; }
slo_recorded() { prom_has 'token:request_error_ratio:rate5m'; }
check "SLO alert rules loaded"             retry 60 slo_rules
check "SLO error ratio is being recorded"  retry 90 slo_recorded

echo "Logs (Loki)"
check "Python logs arrive"                 retry 60 loki_has '{service_name="python-token-service"}'
check "Go logs arrive"                     retry 60 loki_has '{service_name="go-token-service"}'
check "logs carry trace_id"                retry 30 loki_has '{service_name="python-token-service"} | trace_id != ""'
check "logs carry the Kubernetes pod name" loki_has '{service_name="go-token-service", k8s_pod_name=~".+"}'
check "no email address stored"            no_email_in_loki

echo "One request, end to end (Tempo + Loki)"
# The API returns X-Trace-Id; follow that one request through traces and logs
TRACE_ID=$(curl -s -D - -o /dev/null -X POST "$API/token" -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" -d '{"user_email":"bob@example.com"}' \
  | awk 'tolower($1)=="x-trace-id:" {print $2}' | tr -d '\r')
check "API returns X-Trace-Id"             test -n "$TRACE_ID"
echo "  trace id: $TRACE_ID"
TRACE=""
trace_complete() {  # all four parts appear in the trace (spans arrive in batches)
  TRACE=$(curl -s "$TEMPO/api/traces/$TRACE_ID")
  grep -q 'python-token-service' <<<"$TRACE" && grep -q 'go-token-service' <<<"$TRACE" \
    && grep -qi 'postgresql' <<<"$TRACE" && grep -qi 'redis' <<<"$TRACE"
}
check "trace found in Tempo"               retry 60 bash -c "curl -sf '$TEMPO/api/traces/$TRACE_ID' >/dev/null"
retry 60 trace_complete
check "trace includes the Python API"      grep -q 'python-token-service' <<<"$TRACE"
check "trace includes PostgreSQL"          grep -qi 'postgresql' <<<"$TRACE"
check "trace includes the Go service"      grep -q 'go-token-service' <<<"$TRACE"
check "trace includes Redis"               grep -qi 'redis' <<<"$TRACE"
check "trace includes the audit worker"    grep -q 'process token event' <<<"$TRACE"
logs_for_trace() {  # $1 = service
  loki_has "{service_name=\"$1\"} | trace_id=\"$TRACE_ID\""
}
check "Loki: API log lines for this request" retry 60 logs_for_trace python-token-service
check "Loki: Go log lines for this request"  retry 60 logs_for_trace go-token-service
echo "  Loki query: {service_name=~\"python-token-service|go-token-service\"} | trace_id=\"$TRACE_ID\""

echo "Grafana"
check "login works with the secret"        curl -sf -u "$GF_AUTH" "$GRAFANA/api/user"
DS=$(curl -s -u "$GF_AUTH" "$GRAFANA/api/datasources")
for uid in prometheus loki tempo; do
  check "data source '$uid'"               grep -q "\"uid\":\"$uid\"" <<<"$DS"
done
dashboards() { test "$(curl -s -u "$GF_AUTH" "$GRAFANA/api/search?type=dash-db&query=Token" | grep -o '"uid":' | wc -l)" -ge 6; }
check "6 token dashboards loaded"          retry 60 dashboards

echo
echo "passed: $pass  failed: $fail"
[[ $fail == 0 ]]
