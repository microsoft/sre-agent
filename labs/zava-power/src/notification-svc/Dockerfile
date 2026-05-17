# ---------- build stage ----------
FROM golang:1.22-alpine AS builder

WORKDIR /app
COPY go.mod ./
# no external deps, skip go mod download
COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o notification-svc .

# ---------- runtime stage ----------
FROM alpine:3.19

RUN apk --no-cache add ca-certificates

WORKDIR /app
COPY --from=builder /app/notification-svc .

EXPOSE 8080

# NOTE: REQUIRED_CONFIG must be provided at runtime or the container
# will exit immediately (CrashLoopBackOff in Kubernetes — Scenario 4).
ENTRYPOINT ["./notification-svc"]
