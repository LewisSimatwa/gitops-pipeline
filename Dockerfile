# ─────────────────────────────────────────────────────────────────────────────
# Multi-stage build for the sample application.
# Replace this with your real application Dockerfile.
#
# Designed to satisfy all three Kyverno ClusterPolicies:
#   - Non-root user (USER 1000)
#   - Read-only root filesystem compatible (writes only to /tmp)
#   - No elevated capabilities needed
# ─────────────────────────────────────────────────────────────────────────────

# ── Stage 1: Build ────────────────────────────────────────────────────────────
FROM golang:1.22-alpine AS builder

WORKDIR /app

# Copy dependency files first to leverage Docker layer caching.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# Build a statically linked binary — no shared libraries needed in the final image.
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-w -s" \
    -o /app/server \
    ./cmd/server

# ── Stage 2: Runtime ──────────────────────────────────────────────────────────
# Use distroless for a minimal attack surface — no shell, no package manager.
FROM gcr.io/distroless/static:nonroot

# nonroot tag sets USER 65532 (nonroot) automatically.
# Matches the runAsUser: 1000 in the Helm chart — adjust if needed.
WORKDIR /app

COPY --from=builder /app/server /app/server

# Expose the port the app listens on.
# This must match service.targetPort in values.yaml.
EXPOSE 8080

ENTRYPOINT ["/app/server"]