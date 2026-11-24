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
│   ├── policy-check.sh     # network policies, HPAs, Argo CD sync and self-heal
│   ├── load.sh             # steady load, to watch the HPAs scale
│   ├── debug.sh            # pods, events, logs when something is stuck
│   └── down.sh             # delete the cluster
├── platform/
│   ├── versions.env        # pinned metrics-server chart
│   ├── values/
│   └── install.sh          # metrics-server (plain mode; Argo CD installs it in GitOps mode)
├── gitops/
│   ├── versions.env        # pinned Argo CD chart
│   ├── argocd-values.yaml
│   ├── bootstrap.sh        # Argo CD + secrets + the root Application
│   ├── apps/               # app of apps: one Application per component, with sync waves
│   └── observability-config/  # kustomize: dashboards ConfigMap + network policies
├── observability/
│   ├── versions.env        # pinned chart versions
│   ├── values/             # kube-prometheus-stack, loki, tempo, otel-collector
│   ├── render.sh           # render all four charts offline (catches value mistakes)
│   ├── install.sh          # namespace, Grafana login, dashboards, helm installs
│   ├── check.sh            # metrics, logs, traces, dashboards, SLO rules end to end
│   ├── networkpolicies.yaml # who may reach Loki, Tempo and the collector
│   └── ui.sh               # Grafana :3000, Prometheus :9091, Alertmanager :9093
└── helm/token-service/
    ├── values.yaml         # replicas, resources, settings (no secrets)
    └── templates/
        ├── configmap.yaml  # settings for the API and the Go service
        ├── api.yaml        # Deployment + NodePort Service + PDB
        ├── grpc.yaml       # Deployment + headless Service + PDB
        ├── postgres.yaml   # StatefulSet + PVC + headless Service
        ├── redis.yaml      # StatefulSet + headless Service
        ├── networkpolicy.yaml   # default deny + exactly the paths each workload needs
        ├── hpa.yaml        # CPU autoscaling for the API and the Go service
        ├── prometheusrule.yaml  # SLO recording rules and burn-rate alerts
        └── servicemonitor.yaml  # Prometheus scrape config (when the CRD exists)
```

## Run it

```bash
./deploy/kind/install-tools.sh # once; skips tools you already have (FORCE=1 to pin)
docker compose down            # free up CPU/memory
./deploy/kind/up.sh            # ~3-5 min the first time
./deploy/kind/smoke.sh         # CHAOS=1 adds a Redis outage and a node drain
./deploy/observability/check.sh
./deploy/kind/policy-check.sh  # network policies, HPAs (and Argo CD, in GitOps mode)
./deploy/kind/load.sh          # optional: watch the HPAs scale (kubectl -n token-service get hpa -w)
./deploy/observability/ui.sh   # Grafana on http://127.0.0.1:3000
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

## Observability

Installed by `up.sh` (skip with `OBSERVABILITY=0`) into namespace `observability`, from the official charts:

| Chart | What | Notes |
| --- | --- | --- |
| `prometheus-community/kube-prometheus-stack` | Prometheus, Alertmanager, Grafana, kube-state-metrics | node-exporter and kind's unreachable control-plane targets turned off |
| `grafana-community/loki` | Logs, monolithic | filesystem on a 2 Gi PVC, 72 h retention, caches off |
| `grafana-community/tempo` | Traces, single binary | local storage on a 2 Gi PVC, 72 h retention |
| `open-telemetry/opentelemetry-collector` | One entry point for traces and logs | masks emails, adds pod/namespace/node to every span and log line |

```
api, grpc ──OTLP──▶ otel-collector ──▶ Tempo (traces)
                                   └─▶ Loki  (logs, email masked)
Prometheus ──scrape (ServiceMonitor)──▶ api /metrics, grpc :9090/metrics
Grafana ──▶ Prometheus, Loki, Tempo   (same 6 dashboards and data source UIDs as Compose)
```

- The dashboards are the same JSON files as Compose. A labelled ConfigMap is picked up by Grafana's sidecar, so there's one copy of each dashboard.
- The ServiceMonitors set `job` to `python-token-service` / `go-token-service`, the same as in Compose, so queries don't change.
- Grafana's password comes from `secrets/grafana_admin_password.txt`. Anonymous access and sign-up are off, and the UIs are reached only through `kubectl port-forward` on 127.0.0.1.
- The namespace enforces the `baseline` Pod Security level (and warns on `restricted`): these third-party charts don't all set every restricted field.

## Network policies

Who may talk to whom (everything else is dropped):

| To | From | Port |
| --- | --- | --- |
| API | anyone (clients, Prometheus) | 8000 |
| Go service | API pods only | 50051 |
| Go service metrics | Prometheus only | 9090 |
| Postgres | API pods only | 5432 |
| Redis | Go service pods only | 6379 |
| OTel collector | pods in `token-service` | 4317/4318 |
| Loki / Tempo | collector and Grafana | 3100 / 4317, 3200 |

Outgoing traffic is limited too: the API may only reach Postgres, the Go service, the collector and DNS; the Go service only Redis, the collector and DNS; Postgres and Redis nothing. A token can't be minted by calling the Go service directly any more (`policy-check.sh` proves it, with the real API pod as the control).

Kubelet probes and `kubectl port-forward` come from the pod's own node, which Kubernetes always allows.

## GitOps with Argo CD

`up.sh` has two modes:

- **Plain** (default): `up.sh` runs `helm upgrade --install` for everything. Fast, works offline, good while changing things.
- **GitOps** (`GITOPS=1 ./deploy/kind/up.sh`): `up.sh` only builds and loads the images and creates the secrets, then `deploy/gitops/bootstrap.sh` installs Argo CD and one root Application. Argo CD installs everything else from GitHub and keeps it there. CI uses this mode, on the exact commit under test.

```text
root Application "token-platform"  (applied by bootstrap.sh: repo, branch, image tag)
  └─ deploy/gitops/apps  (Helm chart, "app of apps")
       wave -3  AppProject token-platform   (allowed repos and namespaces)
       wave -2  metrics-server, observability-config (dashboards + network policies)
       wave -1  loki, tempo, otel-collector, kube-prometheus-stack
       wave  0  token-service  (this repo's chart; needs the Prometheus CRDs from wave -1)
```

Every Application has automated sync with `prune` (deleted from git → deleted from the cluster) and `selfHeal` (changed by hand → changed back). `policy-check.sh` proves it: it deletes the Go service's NetworkPolicy and waits for Argo CD to restore it.

Try it:

```bash
git push -u origin "$(git branch --show-current)"   # Argo CD reads GitHub, not your disk
export GIT_TOKEN=<fine-grained token, read-only Contents>   # only if the repo is private
GITOPS=1 ./deploy/kind/up.sh
./deploy/observability/ui.sh                         # Argo CD on https://127.0.0.1:8443
# change something in git, e.g. api.autoscaling.maxReplicas in deploy/helm/token-service/values.yaml,
# commit and push: Argo CD applies it within about a minute
```

What stays outside git, on purpose:

- **Secrets.** `bootstrap.sh` creates them from `secrets/`. In production: External Secrets (from Vault or a cloud secret manager) or Sealed Secrets, so they can be in git encrypted.
- **The image tag.** kind gets locally built images, so the tag is passed to the root Application. In production CI would push the image to a registry and commit the new tag (or Argo CD Image Updater would), so git always says what runs.
- **Argo CD itself.** Installed once with Helm. It could manage itself as one more Application.

## Autoscaling

Both Deployments have an HPA on CPU (70% of the request): API 2–5 pods, Go service 2–4. metrics-server provides the numbers (with `--kubelet-insecure-tls`, needed only because kind's kubelets have self-signed certificates). Scale-up is immediate, scale-down waits 3 minutes. Five API pods × 10 database connections = 50, the `token_api` connection limit.

## SLOs and alerts

| SLO | Target | Alert |
| --- | --- | --- |
| Availability of `POST /token` (no 5xx) | 99.5% over 30 days | fast burn (14.4× over 1 h and 5 m) and slow burn (6× over 6 h and 30 m), both critical |
| Latency of `POST /token` | 95% under 0.5 s | 14.4× burn over 1 h and 5 m, warning |

4xx answers don't count against the SLO: a bad JWT or an unknown user is the caller's problem, and the Security dashboard watches those. Plus dependency alerts (warnings that explain a page, not pages): Go service or API not scraped, DB pool over 90%, audit queue over 100 events, events stuck unacknowledged for 15 minutes, a client hitting the rate limit. Rules live in `templates/prometheusrule.yaml`; see them in Prometheus (`:9091/alerts`) or Grafana → Alerting. No receiver is set up, so they show but don't notify.

## Why only 3 nodes

Three kind nodes take ~1.5 GB before any app pod; app + observability bring it to ~5 GB, and Argo CD adds ~0.5 GB in GitOps mode. That fits a laptop (give Docker 4 CPUs / 8 GB) and a GitHub runner (4 CPUs / 16 GB). Production would add a 3-node control plane and 3 zones; with two zones a quorum-based system (etcd, Redis Sentinel) can't survive losing one, so I kept stateful parts single and said so.

Postgres stays on the node that holds its volume (local storage, like a zonal disk), so the drain test drains the *other* worker.

## Production scenarios

- **More traffic.** The HPAs add API and Go pods on CPU (`./deploy/kind/load.sh` shows it). The limits after that are the database (5 API pods × 10 connections = 50, the `token_api` limit) and a single Redis; next steps would be PgBouncer and Redis replicas.
- **A node goes away.** Pods are spread over two zones with PodDisruptionBudgets; `CHAOS=1 smoke.sh` drains a worker under load and checks `/token` keeps working. Postgres can't move off its node (local volume), which is why production would use a managed or replicated database.
- **Redis or the Go service fails.** The Go pods go not-ready but aren't restarted (restarting wouldn't fix Redis), `/token` returns 503 within the 2 s deadline, and the API recovers by itself when they're back. The Dependencies dashboard and the burn-rate alert show it.
- **Debugging a slow or failing request.** Start from the alert or the Overview panel, open an example trace from the Traces dashboard, see which span is slow, then read that request's logs by its trace id.
- **A bad deploy.** In GitOps mode, revert the commit and Argo CD rolls back; rollouts never drop below the desired replica count (`maxUnavailable: 0`).

## Not here yet

mTLS between the API and the Go service (the NetworkPolicy closes the hole; mTLS would also prove identity). Alert routing to a pager. Postgres and Redis are single pods; in production I'd use a managed database or an operator (CloudNativePG, Redis Sentinel).
