#!/usr/bin/env bash
# GitOps mode: installs Argo CD, then points it at this repository. From then
# on Argo CD installs and keeps in sync everything under deploy/gitops/apps
# (metrics-server, the observability stack, the token service).
#
# Run by deploy/kind/up.sh when GITOPS=1, after images are loaded and the app
# secrets exist. Secrets never go through git: this script creates them.
#
# Argo CD reads from GitHub, not from your disk, so push your branch first.
# Private repo: export GIT_TOKEN=<fine-grained token, read-only "Contents"> first.
# CI sets GITOPS_REVISION to the commit under test and GIT_TOKEN to the job token.
set -euo pipefail
cd "$(dirname "$0")/../.."
source deploy/gitops/versions.env
source deploy/kind/platform.sh
TAG="${TAG:?TAG (the image tag loaded into kind) is required}"
TIMEOUT=600; [[ $IN_CI == 1 ]] && TIMEOUT=900

# 1. Which repo and revision Argo CD should follow
origin=$(git remote get-url origin)
case "$origin" in
  git@github.com:*) REPO_URL="https://github.com/${origin#git@github.com:}" ;;
  *)                REPO_URL="$origin" ;;
esac
[[ -n "${GITHUB_REPOSITORY:-}" ]] && REPO_URL="https://github.com/$GITHUB_REPOSITORY.git"
REVISION="${GITOPS_REVISION:-$(git rev-parse --abbrev-ref HEAD)}"
echo "Argo CD will follow $REPO_URL @ $REVISION"

if [[ -z "${GITOPS_REVISION:-}" ]]; then
  remote_sha=$(git ls-remote origin "refs/heads/$REVISION" | cut -f1)
  if [[ -z "$remote_sha" ]]; then
    echo "branch '$REVISION' is not on GitHub yet: git push -u origin $REVISION"; exit 1
  elif [[ "$remote_sha" != "$(git rev-parse HEAD)" ]]; then
    echo "warning: GitHub has a different commit for '$REVISION' than your HEAD; Argo CD deploys what's on GitHub"
  fi
fi
if ! GIT_TERMINAL_PROMPT=0 git ls-remote "$REPO_URL" >/dev/null 2>&1 && [[ -z "${GIT_TOKEN:-}" ]]; then
  echo "can't read $REPO_URL anonymously (private repo?): export GIT_TOKEN=<read-only token>"; exit 1
fi

# 2. Namespaces with their Pod Security levels, and the secrets git never sees
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace observability --overwrite \
  pod-security.kubernetes.io/enforce=baseline pod-security.kubernetes.io/warn=restricted >/dev/null
apply() { kubectl apply --server-side --force-conflicts -f - >/dev/null; }
kubectl -n observability create secret generic grafana-admin \
  --from-literal=admin-user=admin \
  --from-file=admin-password=secrets/grafana_admin_password.txt \
  --dry-run=client -o yaml | apply
if [[ -n "${GIT_TOKEN:-}" ]]; then
  kubectl -n argocd create secret generic repo-token-platform \
    --from-literal=type=git --from-literal=url="$REPO_URL" \
    --from-literal=username=x-access-token --from-literal=password="$GIT_TOKEN" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml | apply
  echo "repository credentials stored in Argo CD"
fi

# 3. Argo CD
helm repo add argo "$ARGOCD_REPO" --force-update >/dev/null
helm repo update argo >/dev/null
echo "installing Argo CD ($ARGOCD_VERSION)"
helm upgrade --install argocd argo/argo-cd --version "$ARGOCD_VERSION" -n argocd \
  -f deploy/gitops/argocd-values.yaml --wait --timeout 8m

# 4. The root Application ("app of apps"). It's the only thing not in git:
#    it says which repo, branch and image tag this cluster follows.
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: token-platform
  namespace: argocd
spec:
  project: default
  destination: { server: https://kubernetes.default.svc, namespace: argocd }
  source:
    repoURL: $REPO_URL
    targetRevision: $REVISION
    path: deploy/gitops/apps
    helm:
      valuesObject:
        repoURL: $REPO_URL
        targetRevision: $REVISION
        imageTag: "$TAG"
  syncPolicy:
    automated: { prune: true, selfHeal: true }
YAML
echo "root application applied; waiting for every application to be Synced and Healthy"

# 5. Wait until everything is synced and healthy
end=$((SECONDS + TIMEOUT))
while :; do
  states=$(kubectl -n argocd get applications -o jsonpath='{range .items[*]}{.metadata.name}={.status.sync.status}/{.status.health.status}{"\n"}{end}' 2>/dev/null)
  total=$(grep -c . <<<"$states" || true)
  good=$(grep -c '=Synced/Healthy$' <<<"$states" || true)
  echo "  $good/$total applications Synced/Healthy"
  (( total >= 8 && good == total )) && break
  if (( SECONDS > end )); then
    echo "timed out; application states:"; echo "$states"
    kubectl -n argocd get applications -o wide || true
    exit 1
  fi
  sleep 15
done
kubectl -n argocd get applications
