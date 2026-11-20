# ---- Stage 1: build a static binary ----
FROM golang:1.24-alpine AS builder

WORKDIR /src

# Dependencies first, so they're cached between builds
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# Static binary, no debug symbols, no local paths baked in
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/token-server .

# ---- Stage 2: minimal runtime ----
# distroless/static: no shell, no package manager, just the binary and CA certs
FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /out/token-server /token-server

# Numeric non-root user (65532 = "nonroot"), so Kubernetes runAsNonRoot can verify it
USER 65532:65532

EXPOSE 50051 9090
ENTRYPOINT ["/token-server"]
