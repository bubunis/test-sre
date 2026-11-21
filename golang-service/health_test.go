package main

import (
	"context"
	"errors"
	"testing"

	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

type fakeRedis struct{ err error }

func (f *fakeRedis) Ping(ctx context.Context) *redis.StatusCmd {
	return redis.NewStatusResult("PONG", f.err)
}

func healthStatus(t *testing.T, ctx context.Context, hs interface {
	Check(context.Context, *healthpb.HealthCheckRequest) (*healthpb.HealthCheckResponse, error)
}, service string) healthpb.HealthCheckResponse_ServingStatus {
	t.Helper()
	resp, err := hs.Check(ctx, &healthpb.HealthCheckRequest{Service: service})
	if err != nil {
		t.Fatalf("check %q: %v", service, err)
	}
	return resp.GetStatus()
}

func TestReadyWhenRedisAnswers(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	hs := startHealth(ctx, grpc.NewServer(), &fakeRedis{})

	if got := healthStatus(t, ctx, hs, ""); got != healthpb.HealthCheckResponse_SERVING {
		t.Errorf("readiness = %v, want SERVING", got)
	}
	if got := healthStatus(t, ctx, hs, livenessService); got != healthpb.HealthCheckResponse_SERVING {
		t.Errorf("liveness = %v, want SERVING", got)
	}
}

func TestNotReadyButAliveWhenRedisDown(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	hs := startHealth(ctx, grpc.NewServer(), &fakeRedis{err: errors.New("connection refused")})

	if got := healthStatus(t, ctx, hs, ""); got != healthpb.HealthCheckResponse_NOT_SERVING {
		t.Errorf("readiness = %v, want NOT_SERVING", got)
	}
	// Liveness stays SERVING: restarting the Go service wouldn't fix Redis
	if got := healthStatus(t, ctx, hs, livenessService); got != healthpb.HealthCheckResponse_SERVING {
		t.Errorf("liveness = %v, want SERVING", got)
	}
}

func TestShutdownReportsNotServing(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	hs := startHealth(ctx, grpc.NewServer(), &fakeRedis{})
	hs.Shutdown()

	if got := healthStatus(t, ctx, hs, ""); got != healthpb.HealthCheckResponse_NOT_SERVING {
		t.Errorf("after shutdown readiness = %v, want NOT_SERVING", got)
	}
}
