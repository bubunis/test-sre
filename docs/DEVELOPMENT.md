# Development

Things you need when working on the code: the API, dev tokens, tests and the project layout. Getting it running is in the [README](../README.md).

## API

| Method | Path | Auth | Responses |
| --- | --- | --- | --- |
| `POST` | `/token` | Bearer JWT with `token:mint` | `200` token + permissions · `401` no/bad JWT · `403` missing scope · `404` unknown user · `422` invalid email · `429` rate limited · `503` database or Go service unavailable |
| `GET` | `/livez` | none | `200` while the process runs (liveness) |
| `GET` | `/readyz` | none | `200` when the database and the Go service answer, else `503` (readiness) |
| `GET` | `/health` | none | `{"status": "healthy"}` (kept for old checks) |
| `GET` | `/metrics` | none | Prometheus metrics |

The request body for `/token` is `{"user_email": "alice@example.com"}` (3 to 254 characters; case doesn't matter).

## Sample data

| User | Email | Permissions |
| --- | --- | --- |
| Alice | alice@example.com | read:data, write:data |
| Bob | bob@example.com | read:data, admin:users |

## Dev tokens

There's no real identity provider locally. `init-secrets.sh` creates a key pair that stands in for one. The API only gets the public key, and `scripts/dev-token.sh` signs test tokens with the private key inside a throwaway container, so the key never ends up in an image.

```bash
bash scripts/dev-token.sh                                  # valid token: login-service, token:mint, 5 min
bash scripts/dev-token.sh login-service profile            # wrong scope → 403
bash scripts/dev-token.sh login-service token:mint -120    # expired 2 min ago → 401
```

The API allows 30 seconds of clock skew, so a token that expired less than 30 seconds ago still works. That's why the expired example uses -120. Don't use the dev keys in production; see [Production identity provider](#production-identity-provider).

## Production identity provider

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
│   ├── OBSERVABILITY.md         # dashboards, scenarios, queries
│   ├── DEVELOPMENT.md           # this file
│   ├── SECURITY-HARDENING.md    # my notes on the hardening work
│   ├── CONFIGURATION.md         # every setting and secret
│   ├── DEMO.md                  # the live demo, step by step
│   └── guide/index.html         # reviewer lab
└── .github/workflows/           # ci.yml (Compose), kubernetes.yml (kind)
```

## Changing the proto, and habits

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
