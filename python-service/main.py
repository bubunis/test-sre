"""Token Issuance Service - with observability"""
import os, logging, grpc, psycopg2, uvicorn
from fastapi import Depends, FastAPI, HTTPException
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field, field_validator
from opentelemetry import trace
from opentelemetry._logs import set_logger_provider
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.propagate import set_global_textmap
from opentelemetry.propagators.composite import CompositePropagator
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.grpc import GrpcInstrumentorClient
from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor
from prometheus_fastapi_instrumentator import Instrumentator
import token_pb2, token_pb2_grpc
import log_setup
from db_pool import ConnectionPool, PoolTimeout
from auth import Caller, configure_auth, require_caller
from ratelimit import RateLimiter

# Set W3C Trace Context propagator for cross-service trace correlation
set_global_textmap(CompositePropagator([TraceContextTextMapPropagator()]))

# Create shared resource
resource = Resource.create({"service.name": "python-token-service"})

# Initialize OpenTelemetry Tracing
trace_provider = TracerProvider(resource=resource)
otlp_endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
if otlp_endpoint:
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    trace_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=otlp_endpoint, insecure=True)))
trace.set_tracer_provider(trace_provider)

# Initialize OpenTelemetry Logging
log_provider = LoggerProvider(resource=resource)
if otlp_endpoint:
    from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
    log_provider.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter(endpoint=otlp_endpoint, insecure=True)))
set_logger_provider(log_provider)

# Logs go to stdout as JSON (with trace_id/span_id) and to OpenTelemetry (-> Loki).
# Email addresses are replaced by a stable pseudonym before either output sees them.
otel_handler = LoggingHandler(level=logging.INFO, logger_provider=log_provider)
log_setup.configure("python-token-service", otel_handler)
logger = logging.getLogger(__name__)

# Callers must present a valid JWT. Refuse to start if JWT settings are missing (fail closed).
configure_auth()

# Instrument gRPC client for trace propagation
GrpcInstrumentorClient().instrument()

# Instrument psycopg2 for automatic SQL tracing
Psycopg2Instrumentor().instrument()

class TokenRequest(BaseModel):
    # 254 = the longest valid address (RFC 5321). The limit also keeps a huge
    # body from reaching the logs and the database.
    user_email: str = Field(min_length=3, max_length=254)

    @field_validator("user_email")
    @classmethod
    def normalise(cls, v: str) -> str:
        v = v.strip().lower()   # Alice@Example.com and alice@example.com are one user
        if "@" not in v:
            raise ValueError("not an email address")
        return v

app = FastAPI()

# Added before the tracing middleware, so it runs inside the request's span
@app.middleware("http")
async def add_trace_id(request, call_next):
    """Return the request's trace id, so a caller (or a demo) can find its trace and logs."""
    response = await call_next(request)
    ctx = trace.get_current_span().get_span_context()
    if ctx.is_valid:
        response.headers["X-Trace-Id"] = format(ctx.trace_id, "032x")
    return response

# Instrument FastAPI for automatic tracing
FastAPIInstrumentor.instrument_app(app)

# Instrument FastAPI for automatic Prometheus metrics (exposes /metrics)
Instrumentator().instrument(app).expose(app)

DB_URL = os.environ["DATABASE_URL"]  # required, and contains no password


def _read_secret(path_env: str) -> str:
    """Read a secret from the file named in an environment variable."""
    with open(os.environ[path_env]) as f:
        return f.read().strip()


DB_PASSWORD = _read_secret("DB_PASSWORD_FILE")

# One shared connection pool instead of a new connection per request (metrics: db_pool_*)
db = ConnectionPool(
    DB_URL, DB_PASSWORD,
    minconn=int(os.getenv("DB_POOL_MIN", "2")),
    maxconn=int(os.getenv("DB_POOL_MAX", "10")),
    acquire_timeout=float(os.getenv("DB_POOL_TIMEOUT_SECONDS", "2")),
    statement_timeout_ms=int(os.getenv("DB_STATEMENT_TIMEOUT_MS", "2000")),
)
GRPC_HOST = os.getenv("TOKEN_SERVICE_HOST", "localhost:50051")
GRPC_TIMEOUT = float(os.getenv("GRPC_TIMEOUT_SECONDS", "2"))

# One long-lived gRPC channel, shared by all requests (it reconnects by itself).
# On Kubernetes TOKEN_SERVICE_HOST is dns:///<headless service>:50051 and
# round_robin spreads calls over every ready Go pod. With the default
# (pick_first) one HTTP/2 connection would pin all calls to a single pod.
grpc_channel = grpc.insecure_channel(
    GRPC_HOST,
    options=[
        ("grpc.lb_policy_name", os.getenv("GRPC_LB_POLICY", "round_robin")),
        # retry a lost Go service within seconds (the default backoff grows to 2 minutes)
        ("grpc.max_reconnect_backoff_ms", 5000),
    ],
)
token_stub = token_pb2_grpc.TokenServiceStub(grpc_channel)

# Per calling service (JWT client id), per pod: protects Redis and the database
# from one client minting in a loop. 0 turns it off.
limiter = RateLimiter(
    per_minute=int(os.getenv("RATE_LIMIT_PER_MINUTE", "600")),
    burst=int(os.getenv("RATE_LIMIT_BURST", "60")),
)

@app.get("/health")
def health():
    return {"status": "healthy"}


@app.get("/livez")
def livez():
    """The process is up and answering. Kubernetes restarts the container if this fails."""
    return {"status": "alive"}


@app.get("/readyz")
def readyz():
    """Ready for traffic: the database answers and the token service is reachable.
    While this fails, Kubernetes stops sending traffic here but leaves the container running."""
    checks = {}
    try:
        checks["database"] = "ok" if db.ping() else "failed"
    except Exception as exc:
        checks["database"] = f"failed: {type(exc).__name__}"
    try:
        grpc.channel_ready_future(grpc_channel).result(timeout=1)
        checks["token_service"] = "ok"
    except grpc.FutureTimeoutError:
        checks["token_service"] = "failed: unreachable"
    ready = all(v == "ok" for v in checks.values())
    return JSONResponse(status_code=200 if ready else 503,
                        content={"status": "ready" if ready else "not ready", "checks": checks})

@app.get("/faq")
def faq():
    return {"message": "This is a token issuance service. Use POST /token to request a token."}

@app.post("/token")
def request_token(req: TokenRequest, caller: Caller = Depends(require_caller)):
    # Only reached when the caller's JWT is valid; caller.client_id says which service asked.
    trace.get_current_span().set_attribute("app.client_id", caller.client_id)
    retry_after = limiter.check(caller.client_id)
    if retry_after:
        logger.warning("rate limit exceeded", extra={"client_id": caller.client_id})
        raise HTTPException(status_code=429, detail="Too many requests",
                            headers={"Retry-After": str(retry_after)})
    logger.info(f"Token request for {req.user_email}", extra={"client_id": caller.client_id})

    try:
        row = db.fetchone("user_permissions", """
            SELECT ARRAY_AGG(DISTINCT gp.permission)
            FROM users u JOIN memberships m ON u.id = m.user_id
            JOIN group_permissions gp ON m.group_id = gp.group_id
            WHERE u.email = %s
        """, (req.user_email,))
    except PoolTimeout:
        logger.warning("database pool exhausted", extra={"client_id": caller.client_id})
        raise HTTPException(status_code=503, detail="Service busy, try again")
    except psycopg2.Error as exc:   # Postgres down, connection lost, statement timeout
        logger.error("database unavailable", extra={"error": type(exc).__name__, "client_id": caller.client_id})
        raise HTTPException(status_code=503, detail="Database unavailable")

    if not row or not row[0]:
        logger.info(f"User not found: {req.user_email}")
        raise HTTPException(status_code=404, detail="User not found")

    try:
        resp = token_stub.MintToken(token_pb2.MintTokenRequest(
            user_email=req.user_email, permissions=row[0], ttl_seconds=3600), timeout=GRPC_TIMEOUT)
    except grpc.RpcError as exc:
        logger.error("token service call failed", extra={"grpc_code": exc.code().name, "client_id": caller.client_id})
        raise HTTPException(status_code=503, detail="Token service unavailable")

    logger.info(f"Token issued for {req.user_email}")
    return {"token": resp.token, "permissions": row[0]}


if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8000, reload=True)