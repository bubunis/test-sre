# Live demo (about 15 minutes)

What I show, in order, and the commands for each. Start the cluster before the call: the first `up.sh` takes 5–8 minutes.

## Before the call

```bash
docker compose down
git push                                   # GitOps mode deploys what's on GitHub
GITOPS=1 ./deploy/kind/up.sh               # or plain ./deploy/kind/up.sh
./deploy/observability/ui.sh               # leave running: Grafana :3000, Prometheus :9091, Argo CD :8443
API=http://127.0.0.1:8080 bash scripts/scenarios.sh baseline 600 &   # live traffic on the dashboards
```

Log in to Grafana (`admin`, password in `secrets/grafana_admin_password.txt`) and open **Dashboards → Token Service → Overview**, last 15 minutes.

## 1. Services running on Kubernetes (2 min)

```bash
kubectl get nodes -L topology.kubernetes.io/zone       # control plane + 2 workers, two "zones"
kubectl -n token-service get pods -o wide              # API and Go pods split across both workers
kubectl -n token-service get hpa,pdb,networkpolicy
kubectl -n argocd get applications                     # GitOps mode: all Synced / Healthy
```

Points to make: probes on every pod (HTTP for the API, native gRPC for the Go service); requests and limits; non-root, read-only, restricted Pod Security; ConfigMaps for settings and Secrets mounted as files; services find each other by Kubernetes DNS.

## 2. One request, end to end (5 min)

```bash
API=http://127.0.0.1:8080 bash scripts/demo-request.sh
```

It prints the HTTP status, the trace id (the API returns it as `X-Trace-Id`) and the queries.

- **Trace:** Grafana → Explore → Tempo → paste the trace id. Walk the waterfall: `POST /token` → the PostgreSQL query → the gRPC call → the Go `MintToken` span → Redis `SET` and `XADD` → `process token event` in the audit worker, which joined the same trace through the Redis Stream.
- **Logs for that request:** Explore → Loki:
  `{service_name=~"python-token-service|go-token-service"} | trace_id="<trace id>"`
  Lines from both services, in order, each with `trace_id` and `span_id`, and no email address (it's replaced by a pseudonym like `user-ff8d9819fc0e`).
- Click **View trace** on a log line to jump back, and **Logs for this span** on a span.

## 3. Dashboards with live metrics (4 min)

- **Overview:** request rate, errors and latency (RED) for `/token`, availability against the target.
- **Dependencies:** gRPC RED by method and code, the database pool (in use, waits, timeouts), the Redis audit queue (depth, pending, processing time).
- Show a failure live: freeze Redis for a minute and watch mint errors, 5xx and the Go pods going not-ready (but not restarting), then recovering by themselves:
  `kubectl -n token-service exec sts/token-service-redis -- sh -c 'REDISCLI_AUTH="$(cat /etc/secrets/redis/password)" redis-cli CLIENT PAUSE 60000 ALL'`
  (Scaling Redis to 0 works in plain mode only; in GitOps mode Argo CD puts it straight back.)

## 4. Observability strategy (2 min)

- **One id ties everything together.** W3C trace context goes from the API over gRPC into the Go service, and inside the Redis event to the worker. Every log line carries the trace id, so I can go from an alert to the metric, to an example trace, to its logs.
- **Metrics tell me something is wrong, traces where, logs why.** RED for every endpoint, USE-style saturation for the pool and the queue.
- **Alerts on symptoms, not causes.** SLO burn-rate alerts on `/token` page; dependency alerts (pool nearly full, queue backlog) are warnings that help explain a page.
- **Privacy by default.** No email address reaches stdout or Loki; the collector masks any that slip through.
- **One pipeline.** Apps send OTLP to the collector only; the backends can change without touching the apps.

## If something goes wrong

`./deploy/kind/debug.sh` (pods, events, logs), `NS=observability ./deploy/kind/debug.sh`, and `kubectl -n argocd get applications -o wide`.
