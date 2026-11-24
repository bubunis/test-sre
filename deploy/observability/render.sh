#!/usr/bin/env bash
# Renders the four observability charts with our values, without a cluster.
# Catches a wrong value name or a chart schema error in seconds, before
# anything is installed. CI runs it first.
set -euo pipefail
cd "$(dirname "$0")/../.."
source deploy/observability/versions.env
V=deploy/observability/values
OUT="${OUT:-$(mktemp -d)}"

helm repo add prometheus-community "$KPS_REPO" --force-update >/dev/null
helm repo add grafana-community "$GRAFANA_COMMUNITY_REPO" --force-update >/dev/null
helm repo add open-telemetry "$OTEL_REPO" --force-update >/dev/null
helm repo update prometheus-community grafana-community open-telemetry >/dev/null

render() {  # release chart version values
  helm template "$1" "$2" --version "$3" -n observability -f "$4" > "$OUT/$1.yaml"
  echo "ok  $1 $3  ($(grep -c '^kind:' "$OUT/$1.yaml") objects)"
}
render loki           grafana-community/loki                     "$LOKI_VERSION"           "$V/loki.yaml"
render tempo          grafana-community/tempo                    "$TEMPO_VERSION"          "$V/tempo.yaml"
render otel-collector open-telemetry/opentelemetry-collector     "$OTEL_COLLECTOR_VERSION" "$V/otel-collector.yaml"
render kps            prometheus-community/kube-prometheus-stack "$KPS_VERSION"            "$V/kube-prometheus-stack.yaml"

# The Services the rest of the setup expects by name
for svc in loki tempo otel-collector; do
  grep -q "name: $svc$" "$OUT/$svc.yaml" || { echo "expected Service '$svc' not found in $svc chart"; exit 1; }
done
grep -q "name: grafana$" "$OUT/kps.yaml"        || { echo "expected Service 'grafana'"; exit 1; }
grep -q "name: kps-prometheus$" "$OUT/kps.yaml" || { echo "expected Service 'kps-prometheus'"; exit 1; }
echo "rendered to $OUT"
