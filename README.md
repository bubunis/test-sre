# Token Issuance Service

A small service that hands out short-lived tokens. A Python API checks which permissions a user has in Postgres, then asks a Go gRPC service to create a token, which is stored in Redis. Everything is instrumented with OpenTelemetry and shows up in Grafana.

I've been hardening it for production step by step, Docker only: no cloud, no Kubernetes. So far: passwords moved to Docker secrets, internal ports closed, token lifetime capped on the server, and callers have to authenticate with a JWT. My notes on each change, how I tested it, and what's still open are in [`docs/SECURITY-HARDENING.md`](docs/SECURITY-HARDENING.md).

## How it fits together

```text
                     only :8000 is published
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

The **Python API** (port 8000) checks the caller's JWT, looks up the user's permissions, and if the user exists, asks the Go service for a token. It also serves `/health` and `/metrics`.

The **Go token service** (gRPC on 50051, metrics on 9090, both internal only) generates a random 256-bit token and stores it in Redis. The server decides how long the token lives: 15 minutes by default, at most an hour.

## Security in short

- **No passwords in the code or the repo.** `scripts/init-secrets.sh` generates them into `secrets/`, which git ignores. Containers read them as Docker secrets.
- **Only the API is reachable from outside.** Postgres, Redis, gRPC and the collector are internal. Grafana and the Prometheus UI only listen on `127.0.0.1`, and Grafana needs a login.
- **Tokens always expire.** A caller can't ask for a token that never expires or lives longer than an hour.
- **Callers need a valid JWT** with the `token:mint` scope. No or bad token → 401; wrong scope → 403.
- **It fails closed.** If the database password or the JWT settings are missing, the API won't start. There's no "auth off" switch.

Still open (details in the hardening log):

- Containers run as root, and the API uses the Postgres superuser.
- Traffic between containers isn't encrypted.
- Any container on the Docker network could call the Go service directly.
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

`init-secrets.sh` is safe to run again: it never overwrites existing passwords or keys. One thing to watch: Postgres only sets its password the first time it starts, so if you regenerate it later, run `docker compose down -v` to start the database fresh.

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
| `POST` | `/token` | Bearer JWT with `token:mint` | `200` token + permissions · `401` no/bad JWT · `403` missing scope · `404` unknown user |
| `GET` | `/health` | none | `{"status": "healthy"}` |
| `GET` | `/metrics` | none | Prometheus metrics |

The request body for `/token` is `{"user_email": "alice@example.com"}`.

## Observability

I run the Grafana stack (Loki, Grafana, Tempo, Prometheus) locally next to the services:

- **Traces** go through the OTel collector to **Tempo**, which keeps them for 7 days.
- **Logs** go through the collector to **Loki**, which keeps them for 30 days. The collector masks email addresses as `[email]` before anything is stored.
- **Metrics** are scraped by **Prometheus** every 5 seconds and kept for 15 days.

Grafana is at <http://127.0.0.1:3000>, user `admin`. The password is in `secrets/grafana_admin_password.txt`:

```bash
cat secrets/grafana_admin_password.txt; echo
```

The data sources are set up automatically. From a log line you can jump to its trace (**View trace**), and from a trace to its logs.

### Dashboards

Five dashboards load automatically under **Dashboards → Token Service**:

- **Overview:** is it healthy? Availability against a 99.9% target, request rate, error ratios, mint latency, which services are up, and the latest errors.
- **Security & Auth:** who's being refused and why, unknown-user lookups (a sign of someone probing), requests per calling service, and any direct calls to the Go service with invalid lifetimes.
- **Logs Explorer:** filter by service, level and text. It also has a check that shows when a service stops sending logs.
- **Traces:** slow requests, failed requests, and requests from one caller. Click through to the full trace.
- **Runtime & Resources:** memory, CPU, file handles, goroutines and garbage collection, to spot leaks or pressure.

The dashboards are code, in `observability/grafana/provisioning/dashboards/json/`. Change them in git: edits made in the Grafana UI aren't saved.

### Trying out the dashboards

To see the dashboards with real data, use `scripts/scenarios.sh`. It sends realistic traffic, simulates attacks and briefly takes services down, and marks each run on the dashboards with a purple marker so you can match cause and effect. It only talks to `localhost`, and anything it stops is started again, even if you press Ctrl+C.

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

### Handy queries in Explore

- **Loki:** `{service_name="python-token-service"}` or `{service_name="go-token-service"}`. Add `|= "User not found"` to filter by text.
- **Tempo:** `{ resource.service.name = "python-token-service" }`
- **Prometheus:** `sum by (status) (rate(tokens_minted_total[5m]))`

The Go metrics port isn't published. To look at the raw metrics:

```bash
docker compose exec golang-service wget -qO- http://localhost:9090/metrics
```

## Configuration

### Python API

| Variable | Required | What it's for |
| --- | --- | --- |
| `DATABASE_URL` | yes | Postgres URL *without* a password, e.g. `postgres://postgres@postgres:5432/tokendb` |
| `DB_PASSWORD_FILE` | yes | File with the database password (Docker secret) |
| `TOKEN_SERVICE_HOST` | no | Go gRPC address (default `localhost:50051`) |
| `JWT_ISSUER` | yes | Expected `iss` claim |
| `JWT_AUDIENCE` | yes | Expected `aud` claim |
| `JWT_JWKS_URL` | one of these two | The identity provider's signing keys (production) |
| `JWT_PUBLIC_KEY_FILE` | one of these two | A PEM public key (dev and CI) |
| `JWT_ALGORITHMS` | no | Allowed algorithms (default `RS256,ES256`; asymmetric only) |
| `JWT_REQUIRED_SCOPE` | no | Scope callers need (default `token:mint`) |
| `JWT_LEEWAY_SECONDS` | no | Allowed clock skew (default `30`) |
| `JWT_CA_FILE` | no | CA bundle if the identity provider uses an internal CA |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | no | Where to send traces and logs |

### Go token service

| Variable | Required | What it's for |
| --- | --- | --- |
| `REDIS_ADDR` | no | Redis address (default `localhost:6379`) |
| `REDIS_PASSWORD_FILE` | yes in Docker | File with the Redis password; the service exits if it can't read it |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | no | Where to send traces and logs |

The token lifetime limits live in code (`golang-service/internal/tokenpolicy`): 15 minutes by default, between 1 minute and 1 hour.

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
# Go: token lifetime rules
cd golang-service && go test ./... && cd ..

# Python: JWT checks (expiry, audience, issuer, alg=none, HS256 key confusion,
# wrong key, scope, leeway, refusing to start without config)
cd python-service && uv run pytest -q tests && cd ..
```

CI (`.github/workflows/ci.yml`) runs on every push and pull request to `main`:

1. **Build & Validate:** Go and Python unit tests, then `docker compose build`.
2. **Observability Contracts:** the API's `/health` and the Go `/metrics` endpoint respond.
3. **Stateful E2E Flow:** requests without a valid JWT get 401 or 403; a valid JWT gets a token for alice with the right permissions; the token is stored in Redis.

## Project layout

```text
.
├── docker-compose.yml           # services, secrets, published ports
├── scripts/
│   ├── init-secrets.sh          # creates secrets/ (passwords, Grafana admin, dev JWT keys)
│   ├── dev-token.sh             # prints a signed dev JWT
│   ├── dev_token.py             # used by dev-token.sh
│   └── scenarios.sh             # dev only: traffic, attacks and outages for the dashboards
├── secrets/                     # created locally, git-ignored
├── protos/token.proto           # gRPC definition
├── python-service/
│   ├── main.py                  # FastAPI app
│   ├── auth.py                  # JWT checks for callers
│   ├── conftest.py              # lets pytest import the app modules
│   ├── tests/test_auth.py
│   ├── pyproject.toml, uv.lock
│   └── token_pb2*.py            # generated protobuf code
├── golang-service/
│   ├── main.go                  # gRPC server
│   ├── internal/tokenpolicy/    # token lifetime rules + tests
│   ├── go.mod, go.sum
│   └── proto/                   # generated protobuf code
├── database/init.sql            # schema and sample data
├── observability/
│   ├── otel-collector/config.yaml     # receives OTLP, masks emails, sends to Tempo and Loki
│   ├── tempo/tempo.yaml
│   ├── loki/loki.yaml
│   ├── prometheus/prometheus.yml
│   └── grafana/provisioning/
│       ├── datasources/datasources.yaml
│       └── dashboards/          # dashboards.yaml + json/ (the 5 dashboards)
├── docs/SECURITY-HARDENING.md   # my notes on the hardening work
└── .github/workflows/ci.yml
```

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

I used Claude to help draft some of the code, tests and docs. I reviewed every change, ran the tests locally and in CI, and decided what to fix and in which order. For example, I went with JWT rather than mTLS for caller authentication, and I deferred the network-isolation step.
