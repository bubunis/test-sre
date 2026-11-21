package main

// RED metrics (Rate, Errors, Duration) for every gRPC method, using the same
// metric names as the common go-grpc-prometheus library so standard dashboards work.

import (
	"context"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/status"
)

var (
	grpcStarted = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "grpc_server_started_total",
		Help: "RPCs started on the server.",
	}, []string{"grpc_method"})

	grpcHandled = promauto.NewCounterVec(prometheus.CounterOpts{
		Name: "grpc_server_handled_total",
		Help: "RPCs completed on the server, by gRPC status code.",
	}, []string{"grpc_method", "grpc_code"})

	grpcHandlingSeconds = promauto.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "grpc_server_handling_seconds",
		Help:    "Time to handle an RPC on the server.",
		Buckets: []float64{0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5},
	}, []string{"grpc_method"})
)

// metricsInterceptor records rate, errors (by status code) and duration for each unary RPC.
func metricsInterceptor(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
	grpcStarted.WithLabelValues(info.FullMethod).Inc()
	start := time.Now()
	resp, err := handler(ctx, req)
	grpcHandlingSeconds.WithLabelValues(info.FullMethod).Observe(time.Since(start).Seconds())
	grpcHandled.WithLabelValues(info.FullMethod, status.Code(err).String()).Inc()
	return resp, err
}
