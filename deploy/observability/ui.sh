#!/usr/bin/env bash
# Opens the observability UIs on this machine only (127.0.0.1). Ctrl-C to stop.
#   Grafana     http://127.0.0.1:3000   user admin, password: secrets/grafana_admin_password.txt
#   Prometheus  http://127.0.0.1:9091
#   Alertmanager http://127.0.0.1:9093
#   Argo CD     https://127.0.0.1:8443  (GITOPS=1 only; user admin, password printed below)
# Same ports as Docker Compose, so stop Compose first (docker compose down).
set -euo pipefail
NS=observability
kubectl -n "$NS" port-forward --address 127.0.0.1 svc/grafana 3000:80 &
kubectl -n "$NS" port-forward --address 127.0.0.1 svc/kps-prometheus 9091:9090 &
kubectl -n "$NS" port-forward --address 127.0.0.1 svc/kps-alertmanager 9093:9093 &
if kubectl get ns argocd >/dev/null 2>&1; then
  kubectl -n argocd port-forward --address 127.0.0.1 svc/argocd-server 8443:443 &
fi
trap 'kill $(jobs -p) 2>/dev/null' EXIT
sleep 2
echo
echo "Grafana:      http://127.0.0.1:3000  (admin / \$(cat secrets/grafana_admin_password.txt))"
echo "Prometheus:   http://127.0.0.1:9091"
echo "Alertmanager: http://127.0.0.1:9093"
if kubectl get ns argocd >/dev/null 2>&1; then
  echo "Argo CD:      https://127.0.0.1:8443  (admin / \$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d))"
fi
wait
