package main

// Health checks over the standard gRPC health protocol (grpc.health.v1):
//
//   service "liveness"            always SERVING while the process runs   -> Kubernetes liveness probe
//   service "" and "token.TokenService"
//                                 SERVING only while Redis answers         -> Kubernetes readiness probe
//
// The image is distroless (no shell, no curl), so `token-server -healthcheck`
// checks the local server itself; Docker Compose uses that as its healthcheck.

import (
	"context"
	"fmt"
	"os"
	"time"

	pb "token-service/proto"

	"github.com/redis/go-redis/v9"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/health"
	healthpb "google.golang.org/grpc/health/grpc_health_v1"
)

const livenessService = "liveness"

type pinger interface {
	Ping(ctx context.Context) *redis.StatusCmd
}

// startHealth registers the health service and keeps readiness in step with Redis.
func startHealth(ctx context.Context, s *grpc.Server, rdb pinger) *health.Server {
	hs := health.NewServer()
	healthpb.RegisterHealthServer(s, hs)
	hs.SetServingStatus(livenessService, healthpb.HealthCheckResponse_SERVING)

	ready, first := false, true
	check := func() {
		pingCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
		defer cancel()
		err := rdb.Ping(pingCtx).Err()
		now := err == nil
		if first || now != ready { // log the first result and every change, not every check
			if now {
				logger.Info("ready: Redis answers")
			} else {
				logger.Warn("not ready: Redis does not answer", "error", err.Error())
			}
		}
		ready, first = now, false
		status := healthpb.HealthCheckResponse_NOT_SERVING
		if ready {
			status = healthpb.HealthCheckResponse_SERVING
		}
		for _, svc := range []string{"", pb.TokenService_ServiceDesc.ServiceName} {
			hs.SetServingStatus(svc, status)
		}
	}

	check()
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				check()
			}
		}
	}()
	return hs
}

// runHealthcheck asks the local server whether it is ready. Exit code 0 = ready.
func runHealthcheck(addr string) int {
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fmt.Fprintln(os.Stderr, "healthcheck:", err)
		return 1
	}
	defer conn.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	resp, err := healthpb.NewHealthClient(conn).Check(ctx, &healthpb.HealthCheckRequest{Service: ""})
	if err != nil {
		fmt.Fprintln(os.Stderr, "healthcheck:", err)
		return 1
	}
	if resp.GetStatus() != healthpb.HealthCheckResponse_SERVING {
		fmt.Fprintln(os.Stderr, "healthcheck: not serving:", resp.GetStatus())
		return 1
	}
	return 0
}

func envOr(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}
