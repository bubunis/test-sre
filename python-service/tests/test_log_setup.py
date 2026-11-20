"""Tests for JSON logging (log_setup.py).

Run from python-service/:  uv run pytest -q tests/test_log_setup.py
"""
import io
import json
import logging

import pytest
from opentelemetry import trace
from opentelemetry.trace import NonRecordingSpan, SpanContext, TraceFlags

import log_setup


class ListHandler(logging.Handler):
    """Stands in for the OpenTelemetry handler and keeps what it receives."""

    def __init__(self):
        super().__init__()
        self.records = []

    def emit(self, record):
        self.records.append(record)


@pytest.fixture()
def logs():
    out = io.StringIO()
    otel = ListHandler()
    log_setup.configure("test-service", otel, stream=out)
    yield out, otel
    logging.getLogger().handlers = []


def lines(out):
    return [json.loads(line) for line in out.getvalue().splitlines()]


def test_one_json_object_per_line_with_core_fields(logs):
    out, _ = logs
    logging.getLogger("app").info("hello %s", "world")
    [line] = lines(out)
    assert line["message"] == "hello world"
    assert line["level"] == "INFO"
    assert line["service"] == "test-service"
    assert line["logger"] == "app"
    assert line["timestamp"].endswith("Z")


def test_extra_fields_are_included(logs):
    out, _ = logs
    logging.getLogger("app").info("token request", extra={"client_id": "login-service", "jwt.reason": "x"})
    [line] = lines(out)
    assert line["client_id"] == "login-service"
    assert line["jwt.reason"] == "x"


def test_trace_and_span_ids_inside_a_span(logs):
    out, _ = logs
    ctx = SpanContext(trace_id=0x4BF92F3577B34DA6A3CE929D0E0E4736, span_id=0x00F067AA0BA902B7,
                      is_remote=False, trace_flags=TraceFlags(TraceFlags.SAMPLED))
    with trace.use_span(NonRecordingSpan(ctx)):
        logging.getLogger("app").info("inside")
    logging.getLogger("app").info("outside")
    inside, outside = lines(out)
    assert inside["trace_id"] == format(ctx.trace_id, "032x")
    assert inside["span_id"] == format(ctx.span_id, "016x")
    assert "trace_id" not in outside


def test_emails_are_replaced_on_both_outputs(logs):
    out, otel = logs
    logging.getLogger("app").info("Token request for %s", "alice@example.com", extra={"who": "bob@example.com"})
    [line] = lines(out)
    assert "@" not in json.dumps(line)
    assert line["message"] == "Token request for " + log_setup.user_ref("alice@example.com")
    assert line["who"] == log_setup.user_ref("bob@example.com")
    assert "@" not in otel.records[0].getMessage()


def test_pseudonym_is_stable_and_matches_go_rule():
    # Go: "user-" + hex(sha256(email)[:6])  ==  Python: "user-" + sha256 hexdigest[:12]
    ref = log_setup.user_ref("alice@example.com")
    assert ref == log_setup.user_ref("alice@example.com")
    assert ref.startswith("user-") and len(ref) == len("user-") + 12
    assert ref == "user-ff8d9819fc0e"


def test_exceptions_are_logged_as_one_field(logs):
    out, _ = logs
    try:
        raise ValueError("boom")
    except ValueError:
        logging.getLogger("app").exception("failed")
    [line] = lines(out)
    assert "ValueError: boom" in line["exception"]


def test_uvicorn_logs_are_routed_through_json(logs):
    out, _ = logs
    uv = logging.getLogger("uvicorn.access")
    uv.addHandler(logging.StreamHandler(io.StringIO()))  # what uvicorn would install
    log_setup.configure("test-service", ListHandler(), stream=out)  # configure runs after uvicorn
    uv.info('%s - "%s %s HTTP/%s" %d', "127.0.0.1:5000", "POST", "/token", "1.1", 401)
    assert uv.handlers == [] and uv.propagate
    assert any('"POST /token HTTP/1.1" 401' in l["message"] for l in lines(out))
