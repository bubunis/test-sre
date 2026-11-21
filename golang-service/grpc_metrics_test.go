package main

import (
	"context"
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestMetricsInterceptorCountsByCode(t *testing.T) {
	info := &grpc.UnaryServerInfo{FullMethod: "/token.TokenService/MintToken"}
	ok := func(ctx context.Context, req any) (any, error) { return "ok", nil }
	bad := func(ctx context.Context, req any) (any, error) {
		return nil, status.Error(codes.InvalidArgument, "bad ttl")
	}

	before := testutil.ToFloat64(grpcHandled.WithLabelValues(info.FullMethod, "OK"))
	beforeBad := testutil.ToFloat64(grpcHandled.WithLabelValues(info.FullMethod, "InvalidArgument"))

	if _, err := metricsInterceptor(context.Background(), nil, info, ok); err != nil {
		t.Fatal(err)
	}
	if _, err := metricsInterceptor(context.Background(), nil, info, bad); status.Code(err) != codes.InvalidArgument {
		t.Fatalf("error not passed through: %v", err)
	}

	if got := testutil.ToFloat64(grpcHandled.WithLabelValues(info.FullMethod, "OK")); got != before+1 {
		t.Errorf("OK count = %v, want %v", got, before+1)
	}
	if got := testutil.ToFloat64(grpcHandled.WithLabelValues(info.FullMethod, "InvalidArgument")); got != beforeBad+1 {
		t.Errorf("InvalidArgument count = %v, want %v", got, beforeBad+1)
	}
	if n := testutil.CollectAndCount(grpcHandlingSeconds); n == 0 {
		t.Error("no duration recorded")
	}
}
