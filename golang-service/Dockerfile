# Stage 1: Build the binary
FROM golang:1.24-alpine AS builder

WORKDIR /app

# Copy module files and download dependencies first (for caching)
COPY go.mod go.sum ./
RUN go mod download

# Copy the rest of the source code
COPY . .

# Build a statically linked binary
RUN CGO_ENABLED=0 GOOS=linux go build -o /token-server main.go

# Stage 2: Create the minimal production image
FROM alpine:latest

WORKDIR /

# Copy the compiled binary from the builder stage
COPY --from=builder /token-server /token-server

# Expose gRPC port and Prometheus metrics port
EXPOSE 50051 9090

CMD ["/token-server"]