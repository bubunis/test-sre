#!/usr/bin/env bash
# Installs the observability stack into namespace "observability" with the
# official Helm charts (versions pinned in versions.env).
# Normally run by deploy/kind/up.sh; can be run on its own against the kind cluster.
set -euo pipefail
cd "$(dirname "$0")/../.."
source deploy/observability/versions.env
source deploy/kind/platform.sh

NS=observability
TIMEOUT="${HELM_TIMEOUT:-8m}"
[[ $IN_CI == 1 ]] && TIMEOUT=10m
V=deploy/observability/values

# 1. Chart repositories
helm repo add prometheus-community "$KPS_REPO" --force-update >/dev/null
helm repo add grafana-community "$GRAFANA_COMMUNITY_REPO" --force-update >/dev/null
helm repo add open-telemetry "$OTEL_REPO" --force-update >/dev/null
helm repo update prometheus-community grafana-community open-telemetry >/dev/null

# 2. Namespace. "baseline" (not "restricted"): some of these charts' pods don't
#    set every restricted field. Warnings still show what's missing.
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace "$NS" --overwrite \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted >/dev/null

# 3. Grafana admin login (same password file as Docker Compose) and the dashboards.
apply() { kubectl -n "$NS" apply --server-side --force-conflicts -f - >/dev/null; }
kubectl -n "$NS" create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-file=admin-password=secrets/grafana_admin_password.txt \
  --dry-run=client -o yaml | apply
# Dashboards are the same JSON files Compose uses; the Grafana sidecar loads
# every ConfigMap labelled grafana_dashboard=1 into the folder in grafana_folder.
kubectl -n "$NS" create configmap token-dashboards \
  --from-file=observability/grafana/provisioning/dashboards/json/ \
  --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml \
  | kubectl annotate --local -f - grafana_folder="Token Service" -o yaml \
  | apply
echo "grafana login and dashboards applied"

# 4. Charts. Order: Loki and Tempo first (the collector sends to them),
#    kube-prometheus-stack (brings the ServiceMonitor CRD the app chart uses).
install() {  # release chart version values
  echo "installing $1 ($2 $3)"
  helm upgrade --install "$1" "$2" --version "$3" -n "$NS" -f "$4" --wait --timeout "$TIMEOUT"
}
install loki           grafana-community/loki                     "$LOKI_VERSION"           "$V/loki.yaml"
install tempo          grafana-community/tempo                    "$TEMPO_VERSION"          "$V/tempo.yaml"
install otel-collector open-telemetry/opentelemetry-collector     "$OTEL_COLLECTOR_VERSION" "$V/otel-collector.yaml"
install kps            prometheus-community/kube-prometheus-stack "$KPS_VERSION"            "$V/kube-prometheus-stack.yaml"

kubectl -n "$NS" get pods
