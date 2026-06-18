# ── Build Stage ───────────────────────────────────────
FROM golang:1.23-alpine AS builder

# SERVICE selects which cmd/* to build: ingest | processor | query | gateway | server
ARG SERVICE=server

RUN apk add --no-cache git ca-certificates

WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-w -s" -o /replayiq-svc "./cmd/${SERVICE}"

# ── Runtime Stage ──────────────────────────────────────
FROM alpine:3.19
RUN apk add --no-cache curl ca-certificates
WORKDIR /app
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /replayiq-svc /replayiq

EXPOSE 8080 8081 8082
ENTRYPOINT ["/replayiq"]
