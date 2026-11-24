#!/usr/bin/env bash
# Cluster add-on: metrics-server (CPU/memory numbers for the HPAs and `kubectl top`).
# Run by deploy/kind/up.sh in the plain (non-GitOps) mode; with GITOPS=1 Argo CD installs it.
set -euo pipefail
cd "$(dirname "$0")/../.."
source deploy/platform/versions.env
source deploy/kind/platform.sh
TIMEOUT="${HELM_TIMEOUT:-5m}"; [[ $IN_CI == 1 ]] && TIMEOUT=8m

helm repo add metrics-server "$METRICS_SERVER_REPO" --force-update >/dev/null
helm repo update metrics-server >/dev/null
echo "installing metrics-server ($METRICS_SERVER_VERSION)"
helm upgrade --install metrics-server metrics-server/metrics-server --version "$METRICS_SERVER_VERSION" \
  -n kube-system -f deploy/platform/values/metrics-server.yaml --wait --timeout "$TIMEOUT"
