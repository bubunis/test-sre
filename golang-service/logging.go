package main

// Structured logging: every record goes to stdout as JSON (with trace_id and
// span_id) and to OpenTelemetry (OTLP -> collector -> Loki).
//
// Email addresses are replaced by a stable pseudonym, "user-" plus the first
// 12 hex characters of their SHA-256. The Python API uses the same rule, so one
// user's requests can be followed across both services without storing the
// address.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"log/slog"
	"os"
	"regexp"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/otel/trace"
)

var emailPattern = regexp.MustCompile(`[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}`)

// userRef returns a stable pseudonym for an email address.
func userRef(email string) string {
	sum := sha256.Sum256([]byte(email))
	return "user-" + hex.EncodeToString(sum[:6])
}

func redact(s string) string { return emailPattern.ReplaceAllStringFunc(s, userRef) }

// newLogger returns a logger that writes JSON to stdout and sends records to OpenTelemetry.
func newLogger(service string) *slog.Logger {
	return slog.New(redactHandler{next: fanout{
		newJSONHandler(os.Stdout, service),
		otelslog.NewHandler(service),
	}})
}

// newJSONHandler writes one JSON object per line, with the same field names as the Python API.
func newJSONHandler(w io.Writer, service string) slog.Handler {
	h := slog.NewJSONHandler(w, &slog.HandlerOptions{
		Level: slog.LevelInfo,
		ReplaceAttr: func(groups []string, a slog.Attr) slog.Attr {
			if len(groups) > 0 {
				return a
			}
			switch a.Key {
			case slog.TimeKey:
				a.Key = "timestamp"
				a.Value = slog.StringValue(a.Value.Time().UTC().Format("2006-01-02T15:04:05.000Z"))
			case slog.MessageKey:
				a.Key = "message"
			}
			return a
		},
	})
	return traceHandler{h.WithAttrs([]slog.Attr{slog.String("service", service)})}
}

// traceHandler adds trace_id and span_id when the log call carries a span in its context.
type traceHandler struct{ slog.Handler }

func (h traceHandler) Handle(ctx context.Context, r slog.Record) error {
	if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
		r = r.Clone()
		r.AddAttrs(slog.String("trace_id", sc.TraceID().String()), slog.String("span_id", sc.SpanID().String()))
	}
	return h.Handler.Handle(ctx, r)
}

func (h traceHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return traceHandler{h.Handler.WithAttrs(attrs)}
}

func (h traceHandler) WithGroup(name string) slog.Handler {
	return traceHandler{h.Handler.WithGroup(name)}
}

// fanout sends each record to every handler.
type fanout []slog.Handler

func (f fanout) Enabled(ctx context.Context, level slog.Level) bool {
	for _, h := range f {
		if h.Enabled(ctx, level) {
			return true
		}
	}
	return false
}

func (f fanout) Handle(ctx context.Context, r slog.Record) error {
	var firstErr error
	for _, h := range f {
		if !h.Enabled(ctx, r.Level) {
			continue
		}
		if err := h.Handle(ctx, r.Clone()); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func (f fanout) WithAttrs(attrs []slog.Attr) slog.Handler {
	out := make(fanout, len(f))
	for i, h := range f {
		out[i] = h.WithAttrs(attrs)
	}
	return out
}

func (f fanout) WithGroup(name string) slog.Handler {
	out := make(fanout, len(f))
	for i, h := range f {
		out[i] = h.WithGroup(name)
	}
	return out
}

// redactHandler replaces email addresses in the message and in attribute values.
type redactHandler struct{ next slog.Handler }

func (h redactHandler) Enabled(ctx context.Context, level slog.Level) bool {
	return h.next.Enabled(ctx, level)
}

func (h redactHandler) Handle(ctx context.Context, r slog.Record) error {
	out := slog.NewRecord(r.Time, r.Level, redact(r.Message), r.PC)
	r.Attrs(func(a slog.Attr) bool {
		out.AddAttrs(redactAttr(a))
		return true
	})
	return h.next.Handle(ctx, out)
}

func (h redactHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	red := make([]slog.Attr, len(attrs))
	for i, a := range attrs {
		red[i] = redactAttr(a)
	}
	return redactHandler{next: h.next.WithAttrs(red)}
}

func (h redactHandler) WithGroup(name string) slog.Handler {
	return redactHandler{next: h.next.WithGroup(name)}
}

func redactAttr(a slog.Attr) slog.Attr {
	v := a.Value.Resolve()
	switch v.Kind() {
	case slog.KindString:
		return slog.String(a.Key, redact(v.String()))
	case slog.KindGroup:
		group := v.Group()
		red := make([]slog.Attr, len(group))
		for i, g := range group {
			red[i] = redactAttr(g)
		}
		return slog.Attr{Key: a.Key, Value: slog.GroupValue(red...)}
	case slog.KindAny:
		if err, ok := v.Any().(error); ok {
			return slog.String(a.Key, redact(err.Error()))
		}
	}
	return slog.Attr{Key: a.Key, Value: v}
}

// Default until main() sets up the real logger, so code (and tests) that log early never hit a nil logger.
func init() {
	if logger == nil {
		logger = slog.Default()
	}
}
