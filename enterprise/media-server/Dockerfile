FROM golang:1.22-alpine AS builder

RUN apk add --no-cache git gcc musl-dev

WORKDIR /build

# Copy module files and download dependencies (layer caching).
COPY go.mod go.sum* ./
RUN if [ -f go.sum ]; then go mod download; fi

# Build the binary (go mod tidy ensures go.sum is present).
COPY . .
RUN go mod tidy && CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o chatwoot-media-server ./cmd/server/

# ---

FROM alpine:3.19

RUN apk add --no-cache ca-certificates wget

COPY --from=builder /build/chatwoot-media-server /usr/local/bin/

RUN mkdir -p /recordings

EXPOSE 4000
EXPOSE 10000-12000/udp

HEALTHCHECK --interval=10s --timeout=5s --retries=3 \
  CMD wget --spider -q http://localhost:4000/health || exit 1

ENTRYPOINT ["chatwoot-media-server"]
