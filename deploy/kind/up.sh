#!/usr/bin/env bash
# Runs the whole token service on a local kind cluster. Same script on a Mac
# (Apple Silicon or Intel), Linux, and GitHub Actions.
# Usage (from the repo root):  ./deploy/kind/up.sh
#   OBSERVABILITY=0 ./deploy/kind/up.sh   # app only, skip Prometheus/Grafana/Loki/Tempo
#   PLATFORM=0 ./deploy/kind/up.sh        # skip metrics-server
#   GITOPS=1 ./deploy/kind/up.sh          # let Argo CD deploy everything from git (push your branch first)
# Re-run it after a code change: it rebuilds, reloads and rolls out the new images.
set -euo pipefail
cd "$(dirname "$0")/../.."
source deploy/kind/platform.sh

CLUSTER=token-service
NS=token-service
RELEASE=token-service
API_PORT=8080                       # must match hostPort in deploy/kind/cluster.yaml
OBSERVABILITY="${OBSERVABILITY:-1}"
PLATFORM="${PLATFORM:-1}"
HELM_TIMEOUT="${HELM_TIMEOUT:-5m}"
[[ $IN_CI == 1 ]] && HELM_TIMEOUT="${HELM_TIMEOUT_CI:-8m}"   # shared runners are slower

describe_platform
[[ -n "$NODE_ARCH" ]] || { echo "Docker is not running. Start Docker Desktop (or colima) first."; exit 1; }
for tool in kind kubectl helm; do
  command -v "$tool" >/dev/null || { echo "missing: $tool  ->  ./deploy/kind/install-tools.sh"; exit 1; }
done

# 3 nodes + app ~3 GB; with the observability stack ~5 GB. Docker Desktop's
# default on a Mac can be too low.
mem_gb=$(( $(docker info --format '{{.MemTotal}}') / 1024 / 1024 / 1024 ))
cpus=$(docker info --format '{{.NCPU}}')
echo "Docker resources: ${cpus} CPUs, ${mem_gb} GB"
want_gb=6; [[ $OBSERVABILITY == 1 ]] && want_gb=8
if (( mem_gb < want_gb - 1 || cpus < 4 )); then
  echo "warning: give Docker at least 4 CPUs and ${want_gb} GB (Docker Desktop > Settings > Resources)"
fi

# 1. Secrets on this machine (same files Docker Compose uses; never committed)
# Always run: it only creates what's missing, and rewrites redis.conf
bash scripts/init-secrets.sh >/dev/null

# 2. Cluster
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  if port_in_use "$API_PORT"; then
    echo "port $API_PORT is already in use on this machine; free it, then re-run"; exit 1
  fi
  kind create cluster --config deploy/kind/cluster.yaml --wait 180s
fi
kubectl config use-context "kind-$CLUSTER" >/dev/null

# An older single-node cluster from a previous version of this script?
want=$(grep -c "role:" deploy/kind/cluster.yaml)
have=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
if [[ "$have" != "$want" ]]; then
  echo "cluster has $have node(s), cluster.yaml wants $want: run ./deploy/kind/down.sh, then this again"; exit 1
fi
kubectl wait node --all --for=condition=Ready --timeout=120s >/dev/null
# Apps run on workers only, as in a managed cluster (kind keeps this taint when
# there are workers; set it anyway so the layout doesn't depend on kind's version)
kubectl taint nodes -l node-role.kubernetes.io/control-plane \
  node-role.kubernetes.io/control-plane=:NoSchedule --overwrite >/dev/null
kubectl get nodes -L topology.kubernetes.io/zone

# 3. Images for the node's CPU (arm64 on Apple Silicon and arm runners, amd64
#    on Intel/most CI). An explicit --platform also protects against
#    DOCKER_DEFAULT_PLATFORM=linux/amd64 on an M-series Mac, which would build
#    images the arm64 node can't run ("exec format error").
#    A new tag per build makes Kubernetes roll out what you just built.
TAG="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
[[ -z "$(git status --porcelain 2>/dev/null)" ]] || TAG="$TAG-dirty-$(date +%s)"
docker build --platform "linux/$NODE_ARCH" -t "token-api:$TAG" python-service
docker build --platform "linux/$NODE_ARCH" -t "token-grpc:$TAG" golang-service
kind load docker-image "token-api:$TAG" "token-grpc:$TAG" --name "$CLUSTER"

# 4. Namespace with the "restricted" Pod Security Standard enforced:
#    pods that run as root, keep capabilities or escalate privileges are rejected
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace "$NS" --overwrite \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted >/dev/null

# 5. Secrets and the DB seed, created from local files (not stored in the chart).
#    Server-side apply: no "last-applied" annotation holding a copy of the secret.
#    One Secret per purpose, so each pod mounts only what it needs.
apply() { kubectl -n "$NS" apply --server-side --force-conflicts -f - >/dev/null; }
kubectl -n "$NS" create secret generic token-db \
  --from-file=password=secrets/postgres_password.txt \
  --from-file=app-password=secrets/app_db_password.txt --dry-run=client -o yaml | apply
kubectl -n "$NS" create secret generic token-redis \
  --from-file=password=secrets/redis_password.txt \
  --from-file=redis.conf=secrets/redis.conf --dry-run=client -o yaml | apply
kubectl -n "$NS" create secret generic token-jwt \
  --from-file=public.pem=secrets/jwt_dev_public.pem --dry-run=client -o yaml | apply
kubectl -n "$NS" create configmap token-db-init \
  --from-file=01-schema.sql=database/init.sql \
  --from-file=02-app-role.sh=database/app-role.sh --dry-run=client -o yaml | apply
echo "secrets and db seed applied"

# GitOps mode: Argo CD installs metrics-server, the observability stack and
# the app from the pushed branch; this script only provides images and secrets.
if [[ "${GITOPS:-0}" == 1 ]]; then
  TAG="$TAG" bash deploy/gitops/bootstrap.sh
  kubectl -n "$NS" get pods -o wide
  echo
  echo "API: http://127.0.0.1:$API_PORT   Argo CD UI: ./deploy/observability/ui.sh"
  exit 0
fi

# 6. Cluster add-on: metrics-server (CPU numbers for the HPAs)
[[ $PLATFORM == 1 ]] && bash deploy/platform/install.sh

# 6b. Observability first: the app chart's ServiceMonitors need its CRDs,
#    and the apps should find the collector when they start
APP_EXTRA=()
if [[ $OBSERVABILITY == 1 ]]; then
  bash deploy/observability/install.sh
  APP_EXTRA=(--set otel.endpoint=http://otel-collector.observability.svc:4317
             --set metrics.serviceMonitor.enabled=true)
fi

# 7. Install / upgrade the app, and wait until every pod is ready
if ! helm upgrade --install "$RELEASE" deploy/helm/token-service \
      --namespace "$NS" \
      --set api.image.tag="$TAG" \
      --set grpc.image.tag="$TAG" \
      ${APP_EXTRA[@]+"${APP_EXTRA[@]}"} \
      --wait --timeout "$HELM_TIMEOUT"; then
  echo "install did not become ready; diagnostics:"
  bash deploy/kind/debug.sh
  exit 1
fi

# which node / zone each pod landed on
kubectl -n "$NS" get pods -o wide
echo
echo "API: http://127.0.0.1:$API_PORT   (next: ./deploy/kind/smoke.sh)"
[[ $OBSERVABILITY == 1 ]] && echo "UIs: ./deploy/observability/ui.sh   (checks: ./deploy/observability/check.sh)"
exit 0
