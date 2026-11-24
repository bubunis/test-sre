#!/usr/bin/env bash
# Prints what you need when pods don't come up. CI runs it on failure.
NS="${NS:-token-service}"   # NS=observability ./deploy/kind/debug.sh for the stack
set -x
kubectl get nodes -o wide -L topology.kubernetes.io/zone
kubectl describe nodes | grep -E "^Name:|Taints:|Unschedulable:|Allocated resources" -A0
kubectl -n "$NS" get all,pvc,secrets,configmaps -o wide
kubectl -n "$NS" get events --sort-by=.lastTimestamp | tail -40
kubectl -n "$NS" describe pods | grep -E "^Name:|State:|Reason:|Exit Code:|Restart Count:|Warning|Liveness|Readiness" 
for p in $(kubectl -n "$NS" get pods -o name); do
  kubectl -n "$NS" logs "$p" --all-containers --tail=50
  kubectl -n "$NS" logs "$p" --all-containers --previous --tail=30 2>/dev/null || true
done
