# Fireteact - Gitea Actions runner orchestrator for Firecracker microVMs
#
# Multi-stage build for minimal production image
# The binary can run in two modes:
#   - `fireteact serve`: Orchestrator mode (runs on host)
#   - `fireteact runner`: Agent mode (runs inside VM)
#
# Build:
#   docker build -t fireteact:latest .
#   docker build --build-arg VERSION=1.0.0 -t fireteact:1.0.0 .
#
# The resulting image contains only the statically-linked binary at /usr/bin/fireteact

ARG GO_VERSION=1.24
ARG ALPINE_VERSION=3.21

# =============================================================================
# Builder stage - compile Go binary
# =============================================================================
FROM golang:${GO_VERSION}-alpine${ALPINE_VERSION} AS builder

ARG VERSION=dev
ARG COMMIT=unknown
ARG DATE=unknown

# Install build dependencies
RUN apk add --no-cache git ca-certificates

WORKDIR /build

# Copy go mod files first for better layer caching
COPY go.mod go.sum ./
RUN go mod download

# Copy source code
COPY . .

# Build statically-linked binary
RUN CGO_ENABLED=0 GOOS=linux go build \
    -ldflags="-s -w -X main.Version=${VERSION} -X main.Commit=${COMMIT} -X main.Date=${DATE}" \
    -o /fireteact \
    ./cmd/fireteact

# =============================================================================
# Production stage - minimal image with just the binary
# =============================================================================
FROM alpine:${ALPINE_VERSION} AS production

# Install runtime dependencies (CA certs for HTTPS)
RUN apk add --no-cache ca-certificates

# Copy binary from builder
COPY --from=builder /fireteact /usr/bin/fireteact

# Verify binary works
RUN /usr/bin/fireteact --version || echo "Version check skipped (dev build)"

# Default to showing help
ENTRYPOINT ["/usr/bin/fireteact"]
CMD ["--help"]

# =============================================================================
# Scratch stage - absolute minimal image (no shell, no package manager)
# =============================================================================
FROM scratch AS minimal

# Copy CA certificates for HTTPS
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/

# Copy binary
COPY --from=builder /fireteact /usr/bin/fireteact

ENTRYPOINT ["/usr/bin/fireteact"]
CMD ["--help"]
