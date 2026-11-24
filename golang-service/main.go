// Token Service - gRPC server with observability
package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"token-service/internal/tokenpolicy"
	pb "token-service/proto"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"github.com/redis/go-redis/extra/redisotel/v9"
	"github.com/redis/go-redis/v9"
	"github.com/redis/go-redis/v9/maintnotifications"
	"go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/log/global"
	"go.opentelemetry.io/otel/propagation"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/keepalive"
	"google.golang.org/grpc/status"
)

var (
	tokensTotal = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "tokens_minted_total",
		Help: "Total tokens minted",
	}, []string{"status"})
	mintLatency = promauto.NewHistogram(prometheus.HistogramOpts{
		Name:    "token_mint_duration_seconds",
		Help:    "Token minting latency",
		Buckets: prometheus.DefBuckets,
	})
	logger *slog.Logger
)

func initOtel() func() {
	ctx := context.Background()

	// Set W3C Trace Context propagator for cross-service trace correlation
	otel.SetTextMapPropagator(propagation.TraceContext{})

	res, _ := resource.New(ctx,
		resource.WithAttributes(semconv.ServiceName("go-token-service")),
	)

	// Initialize tracing
	tp := sdktrace.NewTracerProvider(sdktrace.WithResource(res))

	// Initialize logging
	var lp *sdklog.LoggerProvider

	// Only export to OTLP if endpoint is configured
	if endpoint := os.Getenv("OTEL_EXPORTER_OTLP_ENDPOINT"); endpoint != "" {
		//Strip the http:// scheme to satisfy the Go gRPC dialer while remaining OTel compliant
		cleanEndpoint := strings.TrimPrefix(endpoint, "http://")

		// Trace exporter
		traceExporter, err := otlptracegrpc.New(ctx,
			otlptracegrpc.WithEndpoint(cleanEndpoint),
			otlptracegrpc.WithTLSCredentials(insecure.NewCredentials()),
		)
		if err != nil {
			panic("OTEL Trace Exporter Failed: " + err.Error())
		} else {
			tp = sdktrace.NewTracerProvider(
				sdktrace.WithBatcher(traceExporter),
				sdktrace.WithResource(res),
			)
		}

		// Log exporter
		logExporter, err := otlploggrpc.New(ctx,
			otlploggrpc.WithEndpoint(cleanEndpoint),
			otlploggrpc.WithTLSCredentials(insecure.NewCredentials()),
		)
		if err == nil {
			lp = sdklog.NewLoggerProvider(
				sdklog.WithProcessor(sdklog.NewBatchProcessor(logExporter)),
				sdklog.WithResource(res),
			)
		}
	}

	// No OTLP endpoint: export nothing. The JSON handler already writes every
	// log line to stdout, so a stdout exporter here would print each line twice.
	if lp == nil {
		lp = sdklog.NewLoggerProvider(sdklog.WithResource(res))
	}

	otel.SetTracerProvider(tp)
	global.SetLoggerProvider(lp)

	// JSON to stdout (with trace_id/span_id) + OpenTelemetry; emails replaced (see logging.go)
	logger = newLogger("go-token-service")

	return func() {
		tp.Shutdown(ctx)
		lp.Shutdown(ctx)
	}
}

type server struct {
	pb.UnimplementedTokenServiceServer
	rdb *redis.Client
}

func (s *server) MintToken(ctx context.Context, req *pb.MintTokenRequest) (*pb.MintTokenResponse, error) {
	start := time.Now()
	logger.InfoContext(ctx, "minting token", "user", req.UserEmail)

	// Server decides the lifetime: 0 means the default, out-of-range is refused,
	// and a token can never be stored without an expiry.
	if err := tokenpolicy.ValidateEmail(req.UserEmail); err != nil {
		tokensTotal.WithLabelValues("rejected").Inc()
		logger.WarnContext(ctx, "invalid user_email", "error", err.Error())
		return nil, status.Error(codes.InvalidArgument, err.Error())
	}

	ttl, err := tokenpolicy.TTL(req.TtlSeconds)
	if err != nil {
		tokensTotal.WithLabelValues("rejected").Inc()
		logger.WarnContext(ctx, "invalid ttl requested", "ttl_seconds", req.TtlSeconds)
		return nil, status.Error(codes.InvalidArgument, err.Error())
	}

	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		tokensTotal.WithLabelValues("error").Inc()
		logger.ErrorContext(ctx, "random source failed", "error", err.Error())
		return nil, status.Error(codes.Internal, "could not generate token")
	}
	token := hex.EncodeToString(bytes)

	if err := s.rdb.Set(ctx, "token:"+token, req.UserEmail, ttl).Err(); err != nil {
		tokensTotal.WithLabelValues("error").Inc()
		logger.ErrorContext(ctx, "redis error", "error", err.Error())
		return nil, status.Error(codes.Unavailable, "token store unavailable")
	}

	tokensTotal.WithLabelValues("success").Inc()
	mintLatency.Observe(time.Since(start).Seconds())
	logger.InfoContext(ctx, "token minted", "user", req.UserEmail)

	// Audit event on the Redis Stream queue (see queue.go); never stores the raw email
	enqueueTokenEvent(ctx, s.rdb, userRef(req.UserEmail), ttl)
	return &pb.MintTokenResponse{Token: token}, nil
}

func (s *server) ValidateToken(ctx context.Context, req *pb.ValidateTokenRequest) (*pb.ValidateTokenResponse, error) {
	email, err := s.rdb.Get(ctx, "token:"+req.Token).Result()
	if err != nil {
		return &pb.ValidateTokenResponse{Valid: false}, nil
	}
	return &pb.ValidateTokenResponse{Valid: true, UserEmail: email}, nil
}

func main() {
	grpcPort := envOr("GRPC_PORT", "50051")
	metricsPort := envOr("METRICS_PORT", "9090")

	// Docker healthcheck: the image has no shell or curl, so the binary checks itself (see health.go)
	if len(os.Args) > 1 && os.Args[1] == "-healthcheck" {
		os.Exit(runHealthcheck("127.0.0.1:" + grpcPort))
	}

	// Stop cleanly on SIGTERM (docker stop, Kubernetes) or Ctrl+C
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	cleanup := initOtel()
	defer cleanup()

	redisAddr := envOr("REDIS_ADDR", "localhost:6379")
	// Read the Redis password from a file (Docker/Kubernetes secret), never from a plain env value
	redisPassword := ""
	if f := os.Getenv("REDIS_PASSWORD_FILE"); f != "" {
		b, err := os.ReadFile(f)
		if err != nil {
			logger.Error("cannot read REDIS_PASSWORD_FILE", "error", err)
			os.Exit(1)
		}
		redisPassword = strings.TrimSpace(string(b))
	}

	// Redis client with OpenTelemetry instrumentation
	rdb := redis.NewClient(&redis.Options{
		Addr:     redisAddr,
		Password: redisPassword,
		// Disable maintenance notifications (Redis Cloud feature not available in standard Redis)
		MaintNotificationsConfig: &maintnotifications.Config{
			Mode: maintnotifications.ModeDisabled,
		},
	})
	if err := redisotel.InstrumentTracing(rdb); err != nil {
		panic(err)
	}

	// Token-event queue: background worker plus queue-size metrics (see queue.go)
	consumer, _ := os.Hostname()
	go runTokenEventWorker(ctx, rdb, consumer)
	go pollTokenEventQueue(ctx, rdb)

	// Metrics endpoint
	mux := http.NewServeMux()
	mux.Handle("/metrics", promhttp.Handler())
	metricsSrv := &http.Server{Addr: ":" + metricsPort, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		if err := metricsSrv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("metrics server failed", "port", metricsPort, "error", err.Error())
			os.Exit(1)
		}
	}()

	lis, err := net.Listen("tcp", ":"+grpcPort)
	if err != nil {
		logger.Error("cannot listen for gRPC; is another process using the port?", "port", grpcPort, "error", err.Error())
		os.Exit(1)
	}

	// gRPC server with OpenTelemetry auto-instrumentation and RED metrics
	s := grpc.NewServer(
		grpc.StatsHandler(otelgrpc.NewServerHandler()),
		grpc.ChainUnaryInterceptor(metricsInterceptor), // see grpc_metrics.go
		// Close each client connection after a few minutes (in-flight calls finish).
		// Clients then reconnect and re-resolve DNS, so new pods get traffic after
		// a scale-up or rollout instead of every client staying pinned to old pods.
		grpc.KeepaliveParams(keepalive.ServerParameters{
			MaxConnectionAge:      2 * time.Minute,
			MaxConnectionAgeGrace: 30 * time.Second,
		}),
	)
	pb.RegisterTokenServiceServer(s, &server{rdb: rdb})
	hs := startHealth(ctx, s, rdb)

	// Graceful shutdown: report NOT_SERVING, finish in-flight requests (max 10 s), then stop
	go func() {
		<-ctx.Done()
		logger.Info("shutting down")
		hs.Shutdown()
		done := make(chan struct{})
		go func() { s.GracefulStop(); close(done) }()
		select {
		case <-done:
		case <-time.After(10 * time.Second):
			s.Stop()
		}
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = metricsSrv.Shutdown(shutdownCtx)
	}()

	logger.Info("token service starting", "grpc_port", grpcPort, "metrics_port", metricsPort)
	if err := s.Serve(lis); err != nil {
		logger.Error("gRPC server stopped", "error", err.Error())
		os.Exit(1)
	}
}
