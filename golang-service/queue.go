package main

// Token-event queue on a Redis Stream.
//
// After a token is minted, the service adds a "token_minted" event to the
// stream "token-events". A background worker in the same service reads the
// stream as consumer group "audit", writes an audit log line, and acknowledges
// the event. The trace context travels inside the event, so the worker's span
// joins the original request's trace.
//
// Metrics:
//   token_events_enqueued_total{result}     events added (ok / error)
//   token_events_processed_total{result}    events handled (ok / error)
//   token_events_queue_depth                events not yet delivered to the worker (consumer-group lag)
//   token_events_queue_pending              delivered but not yet acknowledged
//   token_events_stream_length              entries kept in the stream (capped at about 10,000)
//   token_event_processing_seconds          time the worker spends on one event
//   token_event_queue_latency_seconds       time from enqueue to processed
//
// TOKEN_EVENT_WORK_MS (default 0) adds an artificial delay per event, to demo a growing queue.

import (
	"context"
	"errors"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/redis/go-redis/v9"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

const (
	eventStream    = "token-events"
	eventGroup     = "audit"
	eventStreamMax = 10000
)

var (
	eventsEnqueued = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "token_events_enqueued_total",
		Help: "Token events added to the queue.",
	}, []string{"result"})

	eventsProcessed = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "token_events_processed_total",
		Help: "Token events handled by the worker.",
	}, []string{"result"})

	queueDepth = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "token_events_queue_depth",
		Help: "Token events waiting to be delivered to the worker (consumer-group lag).",
	})

	queuePending = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "token_events_queue_pending",
		Help: "Token events delivered to the worker but not yet acknowledged.",
	})

	streamLength = promauto.NewGauge(prometheus.GaugeOpts{
		Name: "token_events_stream_length",
		Help: "Entries kept in the token-events stream.",
	})

	eventProcessingSeconds = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "token_event_processing_seconds",
		Help:    "Time the worker spends on one token event.",
		Buckets: []float64{0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1},
	})

	eventQueueLatencySeconds = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "token_event_queue_latency_seconds",
		Help:    "Time from adding a token event to the worker finishing it.",
		Buckets: []float64{0.001, 0.005, 0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30},
	})
)

// enqueueTokenEvent adds a token_minted event. A failure is logged and counted
// but does not fail the mint: the token itself is already stored.
func enqueueTokenEvent(ctx context.Context, rdb *redis.Client, user string, ttl time.Duration) {
	values := map[string]any{
		"event":       "token_minted",
		"user":        user,
		"ttl_seconds": strconv.FormatInt(int64(ttl.Seconds()), 10),
		"enqueued_at": strconv.FormatInt(time.Now().UnixNano(), 10),
	}
	carrier := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(ctx, carrier) // adds "traceparent"
	for k, v := range carrier {
		values[k] = v
	}

	err := rdb.XAdd(ctx, &redis.XAddArgs{
		Stream: eventStream,
		MaxLen: eventStreamMax,
		Approx: true,
		Values: values,
	}).Err()
	if err != nil {
		eventsEnqueued.WithLabelValues("error").Inc()
		logger.ErrorContext(ctx, "could not enqueue token event", "error", err.Error())
		return
	}
	eventsEnqueued.WithLabelValues("ok").Inc()
}

// runTokenEventWorker reads and processes events until ctx is cancelled.
func runTokenEventWorker(ctx context.Context, rdb *redis.Client, consumer string) {
	ensureEventGroup(ctx, rdb)
	tracer := otel.Tracer("go-token-service")
	workDelay := time.Duration(envInt("TOKEN_EVENT_WORK_MS", 0)) * time.Millisecond

	for ctx.Err() == nil {
		streams, err := rdb.XReadGroup(ctx, &redis.XReadGroupArgs{
			Group:    eventGroup,
			Consumer: consumer,
			Streams:  []string{eventStream, ">"},
			Count:    10,
			Block:    5 * time.Second,
		}).Result()
		if err != nil {
			if errors.Is(err, redis.Nil) || ctx.Err() != nil {
				continue // no new events within the block time, or shutting down
			}
			if strings.Contains(err.Error(), "NOGROUP") {
				ensureEventGroup(ctx, rdb) // Redis restarted and lost the stream
			}
			logger.Warn("reading token events failed", "error", err.Error())
			sleep(ctx, 2*time.Second)
			continue
		}
		for _, s := range streams {
			for _, m := range s.Messages {
				processTokenEvent(ctx, rdb, tracer, m, workDelay)
			}
		}
	}
}

func processTokenEvent(ctx context.Context, rdb *redis.Client, tracer trace.Tracer, m redis.XMessage, workDelay time.Duration) {
	fields := propagation.MapCarrier{}
	for k, v := range m.Values {
		if s, ok := v.(string); ok {
			fields[k] = s
		}
	}
	// Continue the trace of the request that minted the token
	msgCtx := otel.GetTextMapPropagator().Extract(ctx, fields)
	msgCtx, span := tracer.Start(msgCtx, "process token event", trace.WithSpanKind(trace.SpanKindConsumer))
	defer span.End()

	start := time.Now()
	// The work: write the audit record. A real system might store it or notify another team.
	logger.InfoContext(msgCtx, "audit: token minted",
		"user", fields["user"], "ttl_seconds", fields["ttl_seconds"], "event_id", m.ID)
	if workDelay > 0 {
		sleep(ctx, workDelay)
	}

	if err := rdb.XAck(msgCtx, eventStream, eventGroup, m.ID).Err(); err != nil {
		eventsProcessed.WithLabelValues("error").Inc()
		span.RecordError(err)
		logger.ErrorContext(msgCtx, "could not acknowledge token event", "error", err.Error(), "event_id", m.ID)
		return
	}
	eventProcessingSeconds.Observe(time.Since(start).Seconds())
	if ns, err := strconv.ParseInt(fields["enqueued_at"], 10, 64); err == nil {
		eventQueueLatencySeconds.Observe(time.Since(time.Unix(0, ns)).Seconds())
	}
	eventsProcessed.WithLabelValues("ok").Inc()
}

// pollTokenEventQueue updates the queue-size gauges every 5 seconds.
func pollTokenEventQueue(ctx context.Context, rdb *redis.Client) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
		if n, err := rdb.XLen(ctx, eventStream).Result(); err == nil {
			streamLength.Set(float64(n))
		}
		groups, err := rdb.XInfoGroups(ctx, eventStream).Result()
		if err != nil {
			continue
		}
		for _, g := range groups {
			if g.Name == eventGroup {
				queueDepth.Set(float64(g.Lag))
				queuePending.Set(float64(g.Pending))
			}
		}
	}
}

func ensureEventGroup(ctx context.Context, rdb *redis.Client) {
	err := rdb.XGroupCreateMkStream(ctx, eventStream, eventGroup, "$").Err()
	if err != nil && !strings.Contains(err.Error(), "BUSYGROUP") {
		logger.Warn("could not create token event consumer group", "error", err.Error())
	}
}

func sleep(ctx context.Context, d time.Duration) {
	select {
	case <-ctx.Done():
	case <-time.After(d):
	}
}

func envInt(name string, fallback int) int {
	if v, err := strconv.Atoi(os.Getenv(name)); err == nil {
		return v
	}
	return fallback
}
