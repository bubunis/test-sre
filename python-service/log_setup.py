"""Structured JSON logging with trace context, and no raw email addresses.

Every log record goes to two places:
  * stdout, as one JSON object per line (`docker compose logs`, `kubectl logs`)
  * OpenTelemetry (OTLP -> collector -> Loki), through the handler passed in

Email addresses are replaced by a stable pseudonym, "user-" plus the first 12 hex
characters of their SHA-256. The Go service uses the same rule, so one user's
requests can be followed across both services without storing the address.
"""
import hashlib
import json
import logging
import re
import sys
import traceback
from datetime import datetime, timezone

from opentelemetry import trace

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")

# Attributes every LogRecord has; anything else was passed with extra={...}
_STANDARD = set(vars(logging.LogRecord("", 0, "", 0, "", None, None))) | {"message", "asctime", "taskName"}

# uvicorn installs its own plain-text handlers; these are routed through ours instead
_UVICORN_LOGGERS = ("uvicorn", "uvicorn.error", "uvicorn.access")


def user_ref(email: str) -> str:
    """Stable pseudonym for an email address (same rule as the Go service)."""
    return "user-" + hashlib.sha256(email.encode()).hexdigest()[:12]


def redact(text: str) -> str:
    return EMAIL.sub(lambda m: user_ref(m.group(0)), text)


class RedactEmails(logging.Filter):
    """Replaces email addresses in the message and in extra fields before a handler sees them."""

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            record.msg = redact(record.getMessage())
            record.args = None
        except Exception:  # a broken format string must never drop the log line
            record.msg = redact(str(record.msg))
            record.args = None
        for key, value in list(vars(record).items()):
            if key not in _STANDARD and isinstance(value, str):
                setattr(record, key, redact(value))
        return True


class JsonFormatter(logging.Formatter):
    """One JSON object per line: timestamp, level, service, logger, message,
    trace_id/span_id (when inside a trace) and any extra fields."""

    def __init__(self, service: str):
        super().__init__()
        self.service = service

    def format(self, record: logging.LogRecord) -> str:
        out = {
            "timestamp": datetime.fromtimestamp(record.created, tz=timezone.utc)
            .isoformat(timespec="milliseconds")
            .replace("+00:00", "Z"),
            "level": record.levelname,
            "service": self.service,
            "logger": record.name,
            "message": record.getMessage(),
        }
        ctx = trace.get_current_span().get_span_context()
        if ctx.is_valid:
            out["trace_id"] = format(ctx.trace_id, "032x")
            out["span_id"] = format(ctx.span_id, "016x")
        for key, value in vars(record).items():
            if key in _STANDARD or key in out:
                continue
            out[key] = value if isinstance(value, (str, int, float, bool)) or value is None else str(value)
        if record.exc_info:
            out["exception"] = "".join(traceback.format_exception(*record.exc_info)).rstrip()
        return json.dumps(out, ensure_ascii=False)


def configure(service: str, otel_handler: logging.Handler, level: int = logging.INFO, stream=None) -> None:
    """Send all logs (including uvicorn's) as JSON to stdout and to OpenTelemetry."""
    stdout = logging.StreamHandler(stream or sys.stdout)
    stdout.setFormatter(JsonFormatter(service))

    redact_filter = RedactEmails()
    for handler in (stdout, otel_handler):
        handler.addFilter(redact_filter)

    root = logging.getLogger()
    root.handlers = [stdout, otel_handler]
    root.setLevel(level)

    for name in _UVICORN_LOGGERS:
        uv_logger = logging.getLogger(name)
        uv_logger.handlers = []
        uv_logger.propagate = True
