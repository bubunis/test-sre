package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"testing"

	"go.opentelemetry.io/otel/trace"
)

// testLogger returns a logger writing JSON to buf, plus a second handler that records what it receives.
func testLogger(buf *bytes.Buffer) (*slog.Logger, *recorder) {
	rec := &recorder{}
	return slog.New(redactHandler{next: fanout{newJSONHandler(buf, "go-token-service"), rec}}), rec
}

type recorder struct{ records []slog.Record }

func (r *recorder) Enabled(context.Context, slog.Level) bool { return true }
func (r *recorder) Handle(_ context.Context, rec slog.Record) error {
	r.records = append(r.records, rec)
	return nil
}
func (r *recorder) WithAttrs([]slog.Attr) slog.Handler { return r }
func (r *recorder) WithGroup(string) slog.Handler      { return r }

func decode(t *testing.T, buf *bytes.Buffer) []map[string]any {
	t.Helper()
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatalf("not JSON: %q: %v", line, err)
		}
		out = append(out, m)
	}
	return out
}

func TestJSONFieldsMatchPython(t *testing.T) {
	var buf bytes.Buffer
	logger, _ := testLogger(&buf)
	logger.Info("token minted", "ttl_seconds", 900)

	line := decode(t, &buf)[0]
	for _, key := range []string{"timestamp", "level", "service", "message"} {
		if _, ok := line[key]; !ok {
			t.Errorf("missing field %q in %v", key, line)
		}
	}
	if line["message"] != "token minted" || line["service"] != "go-token-service" || line["level"] != "INFO" {
		t.Errorf("unexpected line: %v", line)
	}
	if !strings.HasSuffix(line["timestamp"].(string), "Z") {
		t.Errorf("timestamp not UTC: %v", line["timestamp"])
	}
}

func TestTraceAndSpanIDsFromContext(t *testing.T) {
	var buf bytes.Buffer
	logger, _ := testLogger(&buf)
	tid, _ := trace.TraceIDFromHex("4bf92f3577b34da6a3ce929d0e0e4736")
	sid, _ := trace.SpanIDFromHex("00f067aa0ba902b7")
	ctx := trace.ContextWithSpanContext(context.Background(),
		trace.NewSpanContext(trace.SpanContextConfig{TraceID: tid, SpanID: sid, TraceFlags: trace.FlagsSampled}))

	logger.InfoContext(ctx, "inside")
	logger.Info("outside")

	lines := decode(t, &buf)
	if lines[0]["trace_id"] != "4bf92f3577b34da6a3ce929d0e0e4736" || lines[0]["span_id"] != "00f067aa0ba902b7" {
		t.Errorf("trace context missing: %v", lines[0])
	}
	if _, ok := lines[1]["trace_id"]; ok {
		t.Errorf("trace_id outside a span: %v", lines[1])
	}
}

func TestEmailsAreReplacedOnBothOutputs(t *testing.T) {
	var buf bytes.Buffer
	logger, rec := testLogger(&buf)
	logger.With("caller", "ops@example.com").Info("minting token for alice@example.com",
		"user", "alice@example.com", "error", errors.New("bob@example.com not found"))

	if strings.Contains(buf.String(), "@") {
		t.Errorf("email leaked to stdout: %s", buf.String())
	}
	line := decode(t, &buf)[0]
	if line["user"] != userRef("alice@example.com") {
		t.Errorf("user = %v, want %v", line["user"], userRef("alice@example.com"))
	}
	r := rec.records[0]
	if strings.Contains(r.Message, "@") {
		t.Errorf("email leaked to OpenTelemetry: %s", r.Message)
	}
	r.Attrs(func(a slog.Attr) bool {
		if strings.Contains(a.Value.String(), "@") {
			t.Errorf("email leaked to OpenTelemetry attr %s", a.Key)
		}
		return true
	})
}

func TestPseudonymMatchesPythonRule(t *testing.T) {
	// Python: "user-" + sha256(email).hexdigest()[:12]
	if got, want := userRef("alice@example.com"), "user-ff8d9819fc0e"; got != want {
		t.Errorf("userRef = %s, want %s", got, want)
	}
}
