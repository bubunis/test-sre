# Kubernetes (local, kind)

Same services as Docker Compose, on a three-node kind cluster, installed with a Helm chart.

```
            127.0.0.1:8080
                  │  (NodePort 30080)
   ┌──────────────▼───────────────┐
   │ control-plane (NoSchedule)   │   apps never run here
   └──────────────────────────────┘
   ┌──────────── zone-a ──────────┐   ┌──────────── zone-b ──────────┐
   │ worker:  api, grpc           │   │ worker2: api, grpc           │
   │          (postgres or redis) │   │          (postgres or redis) │
   └──────────────────────────────┘   └──────────────────────────────┘
```

```
deploy/
├── kind/
│   ├── cluster.yaml        # 1 control plane + 2 workers (zone-a, zone-b)
│   ├── platform.sh         # detects OS, CPU, Docker's CPU, CI (sourced by the others)
│   ├── install-tools.sh    # pinned kind/kubectl/helm for this OS + CPU, checksum-verified
│   ├── up.sh               # build, load images, create secrets, helm install
│   ├── smoke.sh            # e2e + security checks (CHAOS=1: Redis outage too)
│   ├── debug.sh            # pods, events, logs when something is stuck
│   └── down.sh             # delete the cluster
└── helm/token-service/
    ├── values.yaml         # replicas, resources, settings (no secrets)
    └── templates/
        ├── configmap.yaml  # settings for the API and the Go service
        ├── api.yaml        # Deployment + NodePort Service + PDB
        ├── grpc.yaml       # Deployment + headless Service + PDB
        ├── postgres.yaml   # StatefulSet + PVC + headless Service
        └── redis.yaml      # StatefulSet + headless Service
```

## Run it

```bash
./deploy/kind/install-tools.sh # once; skips tools you already have (FORCE=1 to pin)
docker compose down            # free up CPU/memory
./deploy/kind/up.sh            # ~3-5 min the first time
./deploy/kind/smoke.sh         # CHAOS=1 adds a Redis outage test
./deploy/kind/down.sh          # when done
```

The same scripts run in GitHub Actions (`.github/workflows/kubernetes.yml`).
They adapt to where they run:

| | Mac, Apple Silicon | Mac, Intel | Linux / GitHub runner |
| --- | --- | --- | --- |
| Tools downloaded | `darwin-arm64` | `darwin-amd64` | `linux-amd64` or `linux-arm64` |
| Images built for | `linux/arm64` | `linux/amd64` | runner's CPU |
| Checksum tool | `shasum -a 256` | `shasum -a 256` | `sha256sum` |
| Port check | `lsof` | `lsof` | `lsof` or `ss` |
| Helm wait | 5 min | 5 min | 8 min in CI |

Images are built for **Docker's** CPU, not the host's, so a Mac with
`DOCKER_DEFAULT_PLATFORM=linux/amd64` set still gets images its arm64 kind node can run.
CI runs on amd64, and also on arm64 when the repo is public.

## What's in it

- **Secrets stay out of the chart.** `up.sh` creates them from `secrets/` (same files as Compose). One Secret per purpose, mounted as read-only files.
- **Probes.** API: HTTP `/livez` and `/readyz`. Go: native gRPC probes, `liveness` service for liveness, `""` (Redis reachable) for readiness. Postgres: `pg_isready`. Redis: `PING` with the password.
- **Locked-down pods.** The namespace enforces the `restricted` Pod Security Standard. Every container is non-root, read-only root filesystem, no capabilities, no privilege escalation, default seccomp, no service account token.
- **Requests and limits** on every container.
- **Service discovery** is Kubernetes DNS (`token-service-postgres`, `token-service-redis`, `token-service-grpc`).
- **gRPC load balancing.** The Go Service is headless and the API dials `dns:///token-service-grpc:50051` with `round_robin`, so calls go to both Go pods, not only the one the first connection landed on. The Go server closes connections after 2 minutes so new pods get picked up.
- **Multi-node, zone-aware.** Each worker is labelled as its own zone. API and Go pods have a hard spread across zones and a soft spread across nodes, so one worker going down takes half the replicas, not all. A cordoned node is ignored by the spread (`nodeTaintsPolicy: Honor`), so replacements can still start during maintenance.
- **Node maintenance works.** `kubectl drain` respects the PodDisruptionBudgets; `CHAOS=1 smoke.sh` drains a worker under load and checks the API stays up.
- **Rollouts without downtime.** `maxUnavailable: 0`, a PodDisruptionBudget, and a short `preStop` sleep on the API so it leaves the Service before it stops.

## Why only 3 nodes

Three kind nodes take ~1.5 GB before any app pod. That fits a laptop (give Docker 4 CPUs / 6 GB) and a GitHub runner (4 CPUs / 16 GB). Production would add a 3-node control plane and 3 zones; with two zones a quorum-based system (etcd, Redis Sentinel) can't survive losing one, so I kept stateful parts single and said so.

Postgres stays on the node that holds its volume (local storage, like a zonal disk), so the drain test drains the *other* worker.

## Not here yet

Observability stack (PR 6), NetworkPolicies, HPA and SLO alerts (PR 7). Postgres and Redis are single pods; in production I'd use a managed database or an operator (CloudNativePG, Redis Sentinel).
