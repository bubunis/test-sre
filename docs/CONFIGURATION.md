# Configuration

Both services are configured only through environment variables. Anything secret is read from a **file** whose path is in a `*_FILE` variable, never from the variable itself. In Docker Compose those files are Docker secrets; on Kubernetes, plain settings come from a ConfigMap and the files from a Secret mounted as a volume.

## Python API (`python-service`)

| Variable | Default | Kind | What it does |
| --- | --- | --- | --- |
| `DATABASE_URL` | (required) | config | Postgres URL without a password, e.g. `postgres://postgres@postgres:5432/tokendb` |
| `DB_PASSWORD_FILE` | (required) | **secret file** | File containing the database password |
| `DB_POOL_MIN` | `2` | config | Connections kept open between requests |
| `DB_POOL_MAX` | `10` | config | Most connections open at once |
| `DB_POOL_TIMEOUT_SECONDS` | `2` | config | How long a request waits for a free connection before getting 503 |
| `DB_STATEMENT_TIMEOUT_MS` | `2000` | config | Longest a single query may run |
| `TOKEN_SERVICE_HOST` | `localhost:50051` | config | Go token service address |
| `GRPC_TIMEOUT_SECONDS` | `2` | config | Deadline for each call to the Go service; after it, the API returns 503 |
| `JWT_ISSUER` | (required) | config | Expected `iss` claim |
| `JWT_AUDIENCE` | (required) | config | Expected `aud` claim |
| `JWT_PUBLIC_KEY_FILE` | one of these two | **secret file** | Public key that verifies caller JWTs (dev) |
| `JWT_JWKS_URL` | one of these two | config | Identity provider's key endpoint (production) |
| `JWT_ALGORITHMS` | `RS256,ES256` | config | Allowed signing algorithms (asymmetric only) |
| `JWT_REQUIRED_SCOPE` | `token:mint` | config | Scope a caller must have |
| `JWT_LEEWAY_SECONDS` | `30` | config | Allowed clock difference |
| `JWT_CA_FILE` | unset | secret file | CA bundle for an identity provider with an internal certificate |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | config | Where traces and logs go (the OTel collector) |

Endpoints for checks: `GET /livez` (process is up), `GET /readyz` (database and Go service reachable; 503 if not), `GET /metrics`.

## Go token service (`golang-service`)

| Variable | Default | Kind | What it does |
| --- | --- | --- | --- |
| `REDIS_ADDR` | `localhost:6379` | config | Redis address |
| `REDIS_PASSWORD_FILE` | unset | **secret file** | File containing the Redis password; the service exits if set but unreadable |
| `GRPC_PORT` | `50051` | config | gRPC port |
| `METRICS_PORT` | `9090` | config | Prometheus metrics port (`/metrics`) |
| `TOKEN_EVENT_WORK_MS` | `0` | config | Artificial delay per queued event, to demo a growing queue |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | unset | config | Where traces and logs go |

Health over the standard gRPC health protocol: service `liveness` is always SERVING while the process runs; service `""` (and `token.TokenService`) is SERVING only while Redis answers. `token-server -healthcheck` checks the local server and exits 0 when ready.

Token lifetimes are fixed in code (`internal/tokenpolicy`): 15 minutes by default, 1 minute to 1 hour.

## Mapping to Kubernetes

| Kind | Kubernetes object | Example |
| --- | --- | --- |
| config | `ConfigMap`, passed as environment variables | `DATABASE_URL`, `DB_POOL_MAX`, `JWT_ISSUER` |
| secret file | `Secret`, mounted read-only as files; the `*_FILE` variable points at the mount | `DB_PASSWORD_FILE=/etc/secrets/db/password` |
