# Observability

I run the Grafana stack (Loki, Grafana, Tempo, Prometheus) next to the services: with Compose as containers, on Kubernetes from the official Helm charts (`deploy/observability/`). Both use the same dashboards and data source settings.

- **Traces** go through the OTel collector to **Tempo**, which keeps them for 7 days.
- **Logs** go through the collector to **Loki**, which keeps them for 30 days. The collector masks email addresses as `[email]` before anything is stored.
- **Metrics** are scraped by **Prometheus** every 5 seconds and kept for 15 days.

## Strategy

One trace id ties a request together: W3C trace context flows from the API over gRPC to the Go service, and inside the Redis event to the audit worker, and every log line carries it. Metrics say something is wrong, traces say where, logs say why. Apps only talk OTLP to the collector, which masks personal data and adds Kubernetes labels before anything is stored. The live-demo script is in [`DEMO.md`](DEMO.md).

## Access

Grafana is at <http://127.0.0.1:3000> (on Kubernetes, start `./deploy/observability/ui.sh` first), user `admin`. The password is in `secrets/grafana_admin_password.txt`:

```bash
cat secrets/grafana_admin_password.txt; echo
```

The data sources are set up automatically. From a log line you can jump to its trace (**View trace**), and from a trace to its logs.

## Dashboards

Six dashboards load automatically under **Dashboards → Token Service**:

- **Overview:** is it healthy? Availability against a 99.9% target, request rate, error ratios, mint latency, which services are up, and the latest errors.
- **Security & Auth:** who's being refused and why, unknown-user lookups (a sign of someone probing), requests per calling service, and any direct calls to the Go service with invalid lifetimes.
- **Logs Explorer:** filter by service, level and text. It also has a check that shows when a service stops sending logs.
- **Traces:** slow requests, failed requests, and requests from one caller. Click through to the full trace.
- **Runtime & Resources:** memory, CPU, file handles, goroutines and garbage collection, to spot leaks or pressure.
- **Dependencies:** RED metrics for the gRPC calls, the database connection pool (in use, waits, timeouts), and the Redis audit queue (depth, pending, processing time).

On Kubernetes there are also SLO alerts for `/token` (99.5% availability and 95% under 0.5 s, with fast and slow burn-rate alerts) and alerts for the dependencies. They show in Prometheus (`:9091/alerts`) and in Grafana → Alerting.

The dashboards are code, in `observability/grafana/provisioning/dashboards/json/`. Change them in git: edits made in the Grafana UI aren't saved.

## Trying out the dashboards

To see the dashboards with real data, use `scripts/scenarios.sh` (with Compose; against kind, set `API=http://127.0.0.1:8080` and use the traffic scenarios only, since the outage ones stop Compose containers). It sends realistic traffic, simulates attacks and briefly takes services down, and marks each run on the dashboards with a purple marker so you can match cause and effect. It only talks to `localhost`, and anything it stops is started again, even if you press Ctrl+C.

1. Start the stack (see the [README](../README.md)) and log in to Grafana.
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

## Following one request across services

Every response from the API has an `X-Trace-Id` header, and every log line from both services carries that `trace_id`. So for one request:

```bash
bash scripts/demo-request.sh            # Compose (:8000); API=http://127.0.0.1:8080 for kind
```

It sends one `/token` request and prints its trace id with the two queries to paste into Grafana → Explore:

- **Tempo** (the trace: API → Postgres → Go service → Redis, and the audit worker): paste the trace id.
- **Loki** (every log line of that request, from both services, in order): `{service_name=~"python-token-service|go-token-service"} | trace_id="<trace id>"`

From a log line, **View trace** opens the trace; from a span, **Logs for this span** goes back. A script for the whole live demo is in [`DEMO.md`](DEMO.md).

## Handy queries in Explore

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
