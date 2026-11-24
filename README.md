# Token Issuance Service

A small service that hands out short-lived tokens. A Python API checks a user's permissions in Postgres, then asks a Go gRPC service to create a token, which is stored in Redis. Everything sends traces, logs and metrics to Grafana through OpenTelemetry.

It runs with Docker Compose for quick local work, and on a three-node kind cluster (Helm, optionally Argo CD) for the full setup.

**Reviewing this?** Open [`docs/guide/index.html`](docs/guide/index.html) in a browser for a step-by-step lab of the whole assignment.

## Architecture

```text
Calling service ──(Bearer JWT)──► Python API :8000 ──► Postgres
                                        │ gRPC
                                        ▼
                                  Go token service ──► Redis

both services ──OTLP──► OTel collector ──► Tempo (traces), Loki (logs)
Prometheus scrapes both services ──► Grafana shows all three
```

- **Python API** (FastAPI): checks the JWT, rate-limits each caller, looks up permissions, calls the Go service.
- **Go token service**: creates a random 256-bit token and stores it in Redis. The server sets the lifetime: 15 minutes by default, at most an hour.
- On **Kubernetes**, the app runs in `token-service` (API and Go service with HPAs, Postgres and Redis as StatefulSets) spread over two "zones", and the Grafana stack runs in `observability`.

## Quick start: Docker Compose

You need Docker with Compose v2 and `openssl`.

```bash
bash scripts/init-secrets.sh          # passwords and dev JWT keys into secrets/ (git-ignored)
docker compose up -d --build

JWT=$(bash scripts/dev-token.sh)
curl -s -X POST http://localhost:8000/token \
  -H "Authorization: Bearer $JWT" -H "Content-Type: application/json" \
  -d '{"user_email": "alice@example.com"}'
# → {"token": "...", "permissions": ["read:data", "write:data"]}
```

## Quick start: Kubernetes (kind)

Give Docker 4 CPUs and 8 GB. The scripts install pinned `kind`, `kubectl` and `helm` for your OS and CPU.

```bash
docker compose down                   # free the resources
./deploy/kind/install-tools.sh        # once
./deploy/kind/up.sh                   # ~5-8 min; GITOPS=1 ./deploy/kind/up.sh to deploy through Argo CD
./deploy/kind/smoke.sh                # API, security and zone checks (CHAOS=1 adds a Redis outage and a node drain)
./deploy/observability/check.sh       # metrics, logs, traces, dashboards, SLO rules
./deploy/kind/policy-check.sh         # network policies, autoscaling, Argo CD sync
./deploy/observability/ui.sh          # Grafana, Prometheus, Alertmanager on 127.0.0.1
./deploy/kind/down.sh
```

The API is on <http://127.0.0.1:8080>. More in [`deploy/README.md`](deploy/README.md).

## Observability

Grafana is at <http://127.0.0.1:3000> (on kind, run `ui.sh` first). User `admin`, password:

```bash
cat secrets/grafana_admin_password.txt; echo
```

Seven dashboards are under **Dashboards → Token Service**: SLOs (error budgets and burn rates), Overview, Security & Auth, Logs, Traces, Runtime, and Dependencies (DB pool, Redis queue).

To follow one request across both services:

```bash
bash scripts/demo-request.sh          # prints the trace id and the Loki query to paste into Explore
```

Dashboards, test scenarios and handy queries: [`docs/OBSERVABILITY.md`](docs/OBSERVABILITY.md).

## Security

- No passwords in git: they live in `secrets/` and reach containers as Docker or Kubernetes secrets.
- Only the API is exposed. Callers need a JWT with the `token:mint` scope, and every caller gets a rate limit.
- Non-root, read-only containers. The API uses a read-only database login.
- On Kubernetes, network policies allow only the arrows in the diagram.

What I changed, how I tested it, and what's still open: [`docs/SECURITY-HARDENING.md`](docs/SECURITY-HARDENING.md).

## Design decisions

| Decision | Why | Trade-off |
| --- | --- | --- |
| JWT (OAuth2 client credentials), not mTLS | Works with any identity provider | Service-to-service traffic isn't encrypted yet |
| Server decides token lifetime | A caller can't create a token that never expires | One limit for every client |
| kind with 3 nodes and 2 zones | Shows spreading, PDBs and drains on a laptop and in CI | Two zones can't hold a quorum |
| NetworkPolicies, no service mesh | No sidecar per pod on a small laptop | No mTLS or per-call auth |
| Argo CD, app of apps | Git is what runs; manual changes are undone | Image tags are set at bootstrap, not committed |
| Single Postgres and Redis | Enough for a demo; failures are tested | No failover |

## Production readiness

| In place | Before real traffic |
| --- | --- |
| Probes, graceful shutdown, PDBs, zone spreading, HPAs | Database backups and failover, load tests |
| SLO burn-rate alerts (99.5% availability, 95% under 0.5 s) | Alert routing to a pager, runbooks |
| CI on amd64 and arm64, security scans, GitOps | Image registry, signed images, staged rollouts |
| NetworkPolicies, restricted Pod Security | mTLS, a real identity provider, External Secrets |

## More docs

- [`docs/DEMO.md`](docs/DEMO.md): the live demo, step by step
- [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md): every setting and secret
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md): API, dev tokens, tests, project layout
- [`deploy/README.md`](deploy/README.md): Kubernetes, GitOps, SLOs, production scenarios

## A note on how I built this

I used Claude to help draft some of the code, tests and docs. I reviewed every change, ran the tests locally and in CI, and decided what to fix and in which order. For example, I went with JWT rather than mTLS for caller authentication, deferred network isolation in Compose, and closed it on Kubernetes with network policies instead.
