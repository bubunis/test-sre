# Token Issuance Service

A small service that hands out short-lived tokens. A Python API checks which permissions a user has in Postgres, then asks a Go gRPC service to create a token, which is stored in Redis. Everything is instrumented with OpenTelemetry and shows up in Grafana.

It runs two ways: with Docker Compose for quick local work, and on Kubernetes (a local three-node kind cluster, installed with a Helm chart) for the full setup with policies, autoscaling and SLO alerts. Both run on a laptop, and CI runs both.

I hardened it step by step: secrets out of the repo, internal ports closed, token lifetime capped on the server, JWT auth for callers, non-root containers, a read-only database login, and on Kubernetes network policies, autoscaling, SLO alerts and GitOps with Argo CD. My notes on each change, how I tested it, and what's still open are in [`docs/SECURITY-HARDENING.md`](docs/SECURITY-HARDENING.md).

**Reviewing this?** Open [`docs/guide/index.html`](docs/guide/index.html) in a browser: a step-by-step lab that walks through every part of the assignment, with the commands, what you should see, and why.

## How it fits together

```text
                     only :8000 is published (Compose) / NodePort 127.0.0.1:8080 (kind)
Calling service ──(Bearer JWT)──► Python API (FastAPI) :8000 ──► Postgres
                                        │
                                        │ gRPC
                                        ▼
                                  Go token service ──► Redis

Telemetry:
  both services ──OTLP──► OTel collector ──► Tempo (traces)
                                         └─► Loki  (logs, emails masked)
  Prometheus scrapes both services (metrics)
  Grafana on 127.0.0.1:3000 shows all three
```

On Kubernetes the same pieces run in namespace `token-service` (API and Go service 2–5 pods each with an HPA, Postgres and Redis as StatefulSets), spread over two worker nodes that stand in for two zones. Prometheus, Grafana, Loki, Tempo and the collector run in `observability`, metrics-server in `kube-system`. In GitOps mode Argo CD (namespace `argocd`) installs and keeps all of it in sync from this repository. Details: [`deploy/README.md`](deploy/README.md).

```text
kind cluster: control plane (no apps) + worker (zone-a) + worker2 (zone-b)
  token-service:  api x2..5 ──► postgres (PVC)      NetworkPolicies: each arrow is the only path allowed
                   │                                 Argo CD (GITOPS=1): deploys all of it from git
                   └─gRPC─► grpc x2..4 ──► redis
  observability:  otel-collector ──► loki, tempo;  prometheus ──► api, grpc;  grafana ──► all three
```

The **Python API** (port 8000) checks the caller's JWT, applies a per-caller rate limit, looks up the user's permissions, and if the user exists, asks the Go service for a token. It also serves `/livez`, `/readyz` and `/metrics`.

The **Go token service** (gRPC on 50051, metrics on 9090, both internal only) generates a random 256-bit token and stores it in Redis. The server decides how long the token lives: 15 minutes by default, at most an hour.

## Security in short

- **No passwords in the code or the repo.** `scripts/init-secrets.sh` generates them into `secrets/`, which git ignores. Containers read them as Docker secrets.
- **Only the API is reachable from outside.** Postgres, Redis, gRPC and the collector are internal. Grafana and the Prometheus UI only listen on `127.0.0.1`, and Grafana needs a login.
- **Tokens always expire.** A caller can't ask for a token that never expires or lives longer than an hour.
- **Callers need a valid JWT** with the `token:mint` scope. No or bad token → 401; wrong scope → 403.
- **It fails closed.** If the database password or the JWT settings are missing, the API won't start. There's no "auth off" switch.
- **Least privilege.** Containers run as non-root with read-only filesystems. The API logs in to Postgres as `token_api`, which can only read three tables.
- **Limits.** Emails over 254 characters are refused, each calling service gets a rate limit (429 when over), and Redis has a memory cap.
- **On Kubernetes:** only the API can reach the Go service, Postgres only the API, Redis only the Go service; anything else is dropped. Argo CD puts back anything changed by hand.

Still open (details in the hardening log):

- Traffic between services isn't encrypted (mTLS is the next step).
- In Docker Compose, any container on the network could still call the Go service directly. On Kubernetes the network policies close this.
- A caller with a valid JWT can request a token for any existing user.

## Getting started

You need Docker with Compose v2 and `openssl`. You also need [`uv`](https://docs.astral.sh/uv/), but only to run the Python tests.

```bash
# 1. Create local secrets: DB and Redis passwords, the Grafana admin password,
#    and a dev-only key pair for signing test JWTs
bash scripts/init-secrets.sh

# 2. Build and start everything
docker compose up -d --build
docker compose ps                     # everything "Up"; tempo-init shows "Exited (0)", that's fine

# 3. Get a dev JWT and ask for a token
JWT=$(bash scripts/dev-token.sh)
curl -s -X POST http://localhost:8000/token \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"user_email": "alice@example.com"}'
# → {"token": "...", "permissions": ["read:data", "write:data"]}
```

`init-secrets.sh` is safe to run again: it never overwrites existing passwords or keys. One thing to watch: Postgres only sets its passwords (and creates the `token_api` login) the first time it starts, so if you regenerate them later, run `docker compose down -v` to start the database fresh.

### On Kubernetes (kind)

You need Docker (4 CPUs and 8 GB for Docker Desktop). The scripts install pinned `kind`, `kubectl` and `helm` for your OS and CPU, and work the same on an Apple Silicon or Intel Mac and in CI.

```bash
docker compose down                      # free the resources
./deploy/kind/install-tools.sh           # once
./deploy/kind/up.sh                      # cluster, images, secrets, observability, app (~5-8 min); GITOPS=1 via Argo CD
./deploy/kind/smoke.sh                   # API, security and zone checks; CHAOS=1 adds a Redis outage and a node drain
./deploy/observability/check.sh          # metrics, logs, traces, dashboards, SLO rules
./deploy/kind/policy-check.sh            # network policies, autoscaling (and Argo CD sync, in GitOps mode)
./deploy/observability/ui.sh             # Grafana http://127.0.0.1:3000, Prometheus :9091, Alertmanager :9093
./deploy/kind/down.sh                    # delete everything
```

The API is on <http://127.0.0.1:8080>. Get a token the same way as above, with port 8080.

### Dev tokens

There's no real identity provider locally. `init-secrets.sh` creates a key pair that stands in for one. The API only gets the public key, and `scripts/dev-token.sh` signs test tokens with the private key inside a throwaway container, so the key never ends up in an image.

```bash
bash scripts/dev-token.sh                                  # valid token: login-service, token:mint, 5 min
bash scripts/dev-token.sh login-service profile            # wrong scope → 403
bash scripts/dev-token.sh login-service token:mint -120    # expired 2 min ago → 401
```

The API allows 30 seconds of clock skew, so a token that expired less than 30 seconds ago still works. That's why the expired example uses -120. Don't use the dev keys in production; see [Production setup](#production-setup).

## API

| Method | Path | Auth | Responses |
| --- | --- | --- | --- |
| `POST` | `/token` | Bearer JWT with `token:mint` | `200` token + permissions · `401` no/bad JWT · `403` missing scope · `404` unknown user · `422` invalid email · `429` rate limited · `503` database or Go service unavailable |
| `GET` | `/livez` | none | `200` while the process runs (liveness) |
| `GET` | `/readyz` | none | `200` when the database and the Go service answer, else `503` (readiness) |
| `GET` | `/health` | none | `{"status": "healthy"}` (kept for old checks) |
| `GET` | `/metrics` | none | Prometheus metrics |

The request body for `/token` is `{"user_email": "alice@example.com"}` (3 to 254 characters; case doesn't matter).

## Observability

I run the Grafana stack (Loki, Grafana, Tempo, Prometheus) next to the services: with Compose as containers, on Kubernetes from the official Helm charts (`deploy/observability/`). Both use the same dashboards and data source settings.

- **Traces** go through the OTel collector to **Tempo**, which keeps them for 7 days.
- **Logs** go through the collector to **Loki**, which keeps them for 30 days. The collector masks email addresses as `[email]` before anything is stored.
- **Metrics** are scraped by **Prometheus** every 5 seconds and kept for 15 days.

Grafana is at <http://127.0.0.1:3000> (on Kubernetes, start `./deploy/observability/ui.sh` first), user `admin`. The password is in `secrets/grafana_admin_password.txt`:

```bash
cat secrets/grafana_admin_password.txt; echo
```

The data sources are set up automatically. From a log line you can jump to its trace (**View trace**), and from a trace to its logs.

### Dashboards

Six dashboards load automatically under **Dashboards → Token Service**:

- **Overview:** is it healthy? Availability against a 99.9% target, request rate, error ratios, mint latency, which services are up, and the latest errors.
- **Security & Auth:** who's being refused and why, unknown-user lookups (a sign of someone probing), requests per calling service, and any direct calls to the Go service with invalid lifetimes.
- **Logs Explorer:** filter by service, level and text. It also has a check that shows when a service stops sending logs.
- **Traces:** slow requests, failed requests, and requests from one caller. Click through to the full trace.
- **Runtime & Resources:** memory, CPU, file handles, goroutines and garbage collection, to spot leaks or pressure.
- **Dependencies:** RED metrics for the gRPC calls, the database connection pool (in use, waits, timeouts), and the Redis audit queue (depth, pending, processing time).

On Kubernetes there are also SLO alerts for `/token` (99.5% availability and 95% under 0.5 s, with fast and slow burn-rate alerts) and alerts for the dependencies. They show in Prometheus (`:9091/alerts`) and in Grafana → Alerting.

The dashboards are code, in `observability/grafana/provisioning/dashboards/json/`. Change them in git: edits made in the Grafana UI aren't saved.

### Trying out the dashboards

To see the dashboards with real data, use `scripts/scenarios.sh` (with Compose; against kind, set `API=http://127.0.0.1:8080` and use the traffic scenarios only, since the outage ones stop Compose containers). It sends realistic traffic, simulates attacks and briefly takes services down, and marks each run on the dashboards with a purple marker so you can match cause and effect. It only talks to `localhost`, and anything it stops is started again, even if you press Ctrl+C.

1. Start the stack (see [Getting started](#getting-started)) and log in to Grafana.
2. Open **Dashboards → Token Service → Overview** and set the time range to **Last 30 minutes**.
3. In a terminal, run all the scenarios in order (about 12 minutes):
   ```bash
   bash scripts/scenarios.sh all
   ```
4. Watch the dashboards update. Each scenario prints a summary of the HTTP status codes it got.

You can also run a single scenario, with an optional duration in seconds:

```bash
bash scripts/scenarios.sh baseline 300
bash scripts/scenarios.sh auth-attack
bash scripts/scenarios.sh redis-outage
```

What each scenario does, and what you should see:

| Scenario | What it does | What to look for |
| --- | --- | --- |
| `baseline` | Mostly valid requests from 3 callers, plus some unknown users and bad tokens | Steady traffic on Overview; three callers on Security |
| `unknown-users` | Valid callers ask for users that don't exist | 404s and unknown-user lookups climb |
| `auth-attack` | Missing, garbage, expired and wrong-scope JWTs | A 4xx spike; rejected JWTs split by reason |
| `spike` | A short burst of 25 requests a second | Request rate, latency, goroutines and CPU jump |
| `ttl-abuse` | Calls the Go service directly with invalid lifetimes | "Rejected token lifetimes" goes red; `invalid ttl requested` warnings in the logs |
| `redis-outage` | Stops Redis for 45 s | Mint errors, 5xx, `redis error` logs, failed traces |
| `token-outage` | Stops the Go service for 45 s | 5xx, and the Go service shows DOWN on the scrape timeline |
| `db-outage` | Stops Postgres for 45 s | 5xx and failed database spans on Traces |

If a panel stays empty, widen the time range, check that the scenario actually ran (its summary should show status codes), and wait half a minute for the data to arrive.

### Following one request across services

Every response from the API has an `X-Trace-Id` header, and every log line from both services carries that `trace_id`. So for one request:

```bash
bash scripts/demo-request.sh            # Compose (:8000); API=http://127.0.0.1:8080 for kind
```

It sends one `/token` request and prints its trace id with the two queries to paste into Grafana → Explore:

- **Tempo** (the trace: API → Postgres → Go service → Redis, and the audit worker): paste the trace id.
- **Loki** (every log line of that request, from both services, in order): `{service_name=~"python-token-service|go-token-service"} | trace_id="<trace id>"`

From a log line, **View trace** opens the trace; from a span, **Logs for this span** goes back. A script for the whole live demo is in [`docs/DEMO.md`](docs/DEMO.md).

### Handy queries in Explore

- **Loki:** `{service_name="python-token-service"}` or `{service_name="go-token-service"}`. Add `|= "User not found"` to filter by text.
- **Tempo:** `{ resource.service.name = "python-token-service" }`
- **Prometheus:** `sum by (status) (rate(tokens_minted_total[5m]))`

The Go metrics port isn't published, and the image has no shell. To look at the raw metrics:

```bash
# Compose: from a curl container on the same network
docker run --rm --network "$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$(docker compose ps -q golang-service)")" \
  curlimages/curl:8.11.1 -s http://golang-service:9090/metrics | head
# Kubernetes
kubectl -n token-service port-forward deploy/token-service-grpc 9090:9090 & curl -s localhost:9090/metrics | head
```

## Configuration

Every setting, its default, and whether it's plain config or a secret file is in [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md), with how each maps to a Kubernetes ConfigMap or Secret. The token lifetime limits live in code (`golang-service/internal/tokenpolicy`): 15 minutes by default, between 1 minute and 1 hour.

### Production setup

In production, point the API at your identity provider instead of the dev key:

```bash
JWT_ISSUER=https://idp.internal/realms/platform
JWT_AUDIENCE=token-service
JWT_JWKS_URL=https://idp.internal/realms/platform/protocol/openid-connect/certs
JWT_ALGORITHMS=RS256
JWT_CA_FILE=/run/secrets/ca_crt          # only if the IdP uses an internal CA
# and remove JWT_PUBLIC_KEY_FILE
```

Calling services get their JWTs through the OAuth2 client-credentials flow. The API identifies the caller from the token's `azp` claim, falling back to `client_id`, then `sub`.

## Tests

```bash
# Go: token lifetime and email rules, gRPC metrics, health checks, JSON logging
cd golang-service && go test ./... && cd ..

# Python: JWT checks (expiry, audience, issuer, alg=none, HS256 key confusion,
# wrong key, scope, leeway, bad config), log redaction, DB pool, rate limiter
cd python-service && uv run pytest -q tests && cd ..
```

CI runs on every push and pull request to `main`:

- **`ci.yml` (Docker Compose):** unit tests and image builds; `/health` and the Go `/metrics` respond; requests without a valid JWT get 401 or 403; a valid JWT gets alice's token with the right permissions, and the token is in Redis.
- **`kubernetes.yml` (kind):** the same scripts as on a laptop (`up.sh`, `CHAOS=1 smoke.sh`, `check.sh`, `policy-check.sh`), deploying through Argo CD, on amd64, and also on arm64 when the repo is public.

## Project layout

```text
.
├── docker-compose.yml           # services, secrets, published ports
├── deploy/                      # Kubernetes: kind scripts, Helm chart, observability, Argo CD (see deploy/README.md)
├── scripts/
│   ├── init-secrets.sh          # creates secrets/ (passwords, Grafana admin, dev JWT keys)
│   ├── dev-token.sh             # prints a signed dev JWT
│   ├── dev_token.py             # used by dev-token.sh
│   ├── demo-request.sh          # one request: prints its trace id and the Loki query
│   └── scenarios.sh             # dev only: traffic, attacks and outages for the dashboards
├── secrets/                     # created locally, git-ignored
├── protos/token.proto           # gRPC definition
├── python-service/
│   ├── main.py                  # FastAPI app
│   ├── auth.py                  # JWT checks for callers
│   ├── db_pool.py               # Postgres connection pool + metrics
│   ├── log_setup.py             # JSON logs with trace ids, emails replaced
│   ├── ratelimit.py             # per-caller rate limit
│   ├── conftest.py              # lets pytest import the app modules
│   ├── tests/
│   ├── pyproject.toml, uv.lock
│   └── token_pb2*.py            # generated protobuf code
├── golang-service/
│   ├── main.go                  # gRPC server
│   ├── queue.go, health.go, logging.go, grpc_metrics.go
│   ├── internal/tokenpolicy/    # token lifetime and email rules + tests
│   ├── go.mod, go.sum
│   └── proto/                   # generated protobuf code
├── database/
│   ├── init.sql                 # schema and sample data
│   └── app-role.sh              # creates the read-only token_api login
├── observability/
│   ├── otel-collector/config.yaml     # receives OTLP, masks emails, sends to Tempo and Loki
│   ├── tempo/tempo.yaml
│   ├── loki/loki.yaml
│   ├── prometheus/prometheus.yml
│   └── grafana/provisioning/
│       ├── datasources/datasources.yaml
│       └── dashboards/          # dashboards.yaml + json/ (the 6 dashboards)
├── docs/
│   ├── SECURITY-HARDENING.md    # my notes on the hardening work
│   ├── CONFIGURATION.md         # every setting and secret
│   └── DEMO.md                  # the live demo, step by step
└── .github/workflows/           # ci.yml (Compose), kubernetes.yml (kind)
```

## Design decisions

| Decision | Why | What I'd revisit |
| --- | --- | --- |
| JWT (OAuth2 client credentials) for callers, not mTLS | Works with any identity provider, no certificate infrastructure needed yet | mTLS between the API and the Go service as the next layer |
| The server decides token lifetime (15 min default, 1 h max) | A caller can't create a token that never expires | Per-client limits |
| kind with three nodes and two "zones" | Shows zone spreading, PodDisruptionBudgets and node drains on a laptop and in CI | Three zones and a managed control plane in production |
| One Helm chart for the app, official charts for the observability stack | My code in one place; well-maintained charts for the rest, pinned versions | Renovate to keep the pins current |
| Argo CD, app of apps with sync waves; a plain `helm` mode next to it | Git is what runs, drift is undone, CI tests the same path; the plain mode stays fast for local changes | Image tags committed by CI (or Argo CD Image Updater) instead of passed at bootstrap |
| Secrets created from local files, not stored in the chart | Nothing secret in git or in Helm release history | External Secrets / Vault in production |
| NetworkPolicies, no service mesh | Closes the "anyone can call the Go service" hole with what Kubernetes already has; a mesh would add a sidecar per pod on a laptop cluster | Istio or Linkerd for mTLS and per-call auth once there are more services |
| Redis Stream for audit events | A real queue with consumer groups, depth and lag metrics, and traces that continue into the worker | Reclaiming stuck events (XAUTOCLAIM) |
| Postgres and Redis as single StatefulSets | Enough for a demo; failure modes are tested and visible | A managed database or an operator (CloudNativePG, Redis Sentinel) |

## Production readiness

What's in place, and what I'd still add before real traffic:

| Area | Done | Next |
| --- | --- | --- |
| Security | Secrets out of git, non-root read-only containers, restricted Pod Security, read-only DB login, JWT auth, rate limit, NetworkPolicies | mTLS, per-client grants, hashed tokens in Redis, image signing and scanning |
| Reliability | Liveness/readiness/startup probes, graceful shutdown, PDBs, zone spreading, HPAs, tested Redis outage and node drain | Database backups and failover, load tests with a target |
| Observability | JSON logs with trace ids, RED metrics, DB pool and queue metrics, traces across all four parts, 6 dashboards, SLO burn-rate alerts | Alert routing to a pager, runbooks linked from alerts |
| Delivery | CI for Compose and kind on amd64/arm64, GitOps with Argo CD (auto-sync, prune, self-heal), pinned tool and chart versions | Image registry and signed images, staged rollouts (Argo Rollouts), dependency and image scans in CI |

## SLIs, SLOs and alerting

| SLI (what I measure) | SLO (target) | How it's alerted |
| --- | --- | --- |
| Share of `POST /token` calls that don't return 5xx | 99.5% over 30 days | Burn rate: 14.4× over 1 h and 5 m (pages; 2% of the month's budget gone in an hour) and 6× over 6 h and 30 m (pages) |
| Share of `POST /token` calls under 0.5 s | 95% | 14.4× burn over 1 h and 5 m (warning) |

4xx answers don't count against the SLO: a bad JWT or an unknown user is the caller's problem, and the Security dashboard watches those. Dependency alerts (Go service or API not scraped, DB pool over 90%, audit queue over 100, events stuck for 15 minutes, a client hitting the rate limit) are warnings that explain a page rather than pages themselves. Rules: `deploy/helm/token-service/templates/prometheusrule.yaml`.

## Production scenarios

- **More traffic.** The HPAs add API and Go pods on CPU (`./deploy/kind/load.sh` shows it). The limits after that are the database (5 API pods × 10 connections = 50, the `token_api` limit) and a single Redis; next steps would be PgBouncer and Redis replicas.
- **A node goes away.** Pods are spread over two zones with PodDisruptionBudgets; `CHAOS=1 smoke.sh` drains a worker under load and checks `/token` keeps working. Postgres can't move off its node (local volume), which is why production would use a managed or replicated database.
- **Redis or the Go service fails.** The Go pods go not-ready but aren't restarted (restarting wouldn't fix Redis), `/token` returns 503 within the 2 s deadline, and the API recovers by itself when they're back. The Dependencies dashboard and the burn-rate alert show it.
- **Debugging a slow or failing request.** Start from the alert or the Overview panel, open an example trace from the Traces dashboard, see which span is slow, then read that request's logs by its trace id.
- **A bad deploy.** In GitOps mode, revert the commit and Argo CD rolls back; rollouts never drop below the desired replica count (`maxUnavailable: 0`).

## Observability strategy

One trace id ties a request together: W3C trace context flows from the API over gRPC to the Go service, and inside the Redis event to the audit worker, and every log line carries it. Metrics say something is wrong, traces say where, logs say why. Apps only talk OTLP to the collector, which masks personal data and adds Kubernetes labels before anything is stored. The live-demo script is in [`docs/DEMO.md`](docs/DEMO.md).

## Sample data

| User | Email | Permissions |
| --- | --- | --- |
| Alice | alice@example.com | read:data, write:data |
| Bob | bob@example.com | read:data, admin:users |

## Working on it

If you change `protos/token.proto`, regenerate the code and commit it.

```bash
# Python
cd python-service
uv run python -m grpc_tools.protoc -I../protos --python_out=. \
  --grpc_python_out=. ../protos/token.proto

# Go
cd golang-service
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
protoc -I../protos --go_out=proto --go-grpc_out=proto \
  --go_opt=module=token-service/proto \
  --go-grpc_opt=module=token-service/proto \
  ../protos/token.proto
```

A few habits I stick to:

- Nothing under `secrets/` ever gets committed. I check `git status` before every commit.
- Every change starts from an up-to-date `main`, one branch per change.
- Anything security-related goes into `docs/SECURITY-HARDENING.md`, together with how I tested it.

## A note on how I built this

I used Claude to help draft some of the code, tests and docs. I reviewed every change, ran the tests locally and in CI, and decided what to fix and in which order. For example, I went with JWT rather than mTLS for caller authentication, deferred network isolation in Compose, and closed it on Kubernetes with network policies instead.
