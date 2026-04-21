# chatwoot-media-server

A Pion WebRTC media server sidecar for Chatwoot's WhatsApp Calling feature. It acts as a back-to-back user agent (B2BUA) between Meta's media servers and the agent's browser, providing call persistence across page reloads, server-side recording, and centralized call lifecycle management.

## Architecture

The media server maintains two independent WebRTC peer connections per call:

- **Peer A (Meta-side):** Receives the customer's audio from Meta and sends the agent's audio back.
- **Peer B (Agent-side):** Receives the agent's microphone audio and sends the customer's audio to the browser.

An audio bridge forwards RTP packets between the two peers while simultaneously recording both streams to OGG/Opus files.

## Build

```bash
# Local build
go build -o chatwoot-media-server ./cmd/server/

# Docker build
docker build -t chatwoot-media-server .
```

## Run

```bash
# Locally
AUTH_TOKEN=secret RAILS_CALLBACK_URL=http://localhost:3000 ./chatwoot-media-server

# Docker
docker run -p 4000:4000 -p 10000-10100:10000-10100/udp \
  -e AUTH_TOKEN=secret \
  -e RAILS_CALLBACK_URL=http://rails:3000 \
  -v media-recordings:/recordings \
  chatwoot-media-server
```

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AUTH_TOKEN` | (empty) | Shared secret for Bearer token auth. Empty disables auth (dev only). |
| `RAILS_CALLBACK_URL` | `http://localhost:3000` | Base URL for Rails callbacks. |
| `STUN_SERVERS` | `stun:stun.l.google.com:19302` | Comma-separated STUN server URLs. |
| `TURN_SERVERS` | (empty) | Comma-separated TURN server URLs. |
| `TURN_USERNAME` | (empty) | TURN credential username. |
| `TURN_PASSWORD` | (empty) | TURN credential password. |
| `PUBLIC_IP` | (empty) | Server's public IP for ICE candidates. |
| `UDP_PORT_MIN` | `10000` | Lower bound of UDP port range. |
| `UDP_PORT_MAX` | `12000` | Upper bound of UDP port range. |
| `RECORDINGS_DIR` | `/recordings` | Directory for recording files. |
| `HTTP_PORT` | `4000` | HTTP API listen port. |
| `LOG_LEVEL` | `info` | Log level (debug, info, warn, error). |
| `MAX_SESSION_DURATION` | `7200` | Max call duration in seconds (2 hours). |
| `RECONNECT_TIMEOUT` | `30` | Seconds to wait for agent reconnect. |
| `MAX_CONCURRENT_SESSIONS` | `0` | Max active sessions (0 = unlimited). |

## API

All endpoints except `/health` require a `Authorization: Bearer <token>` header.

### Sessions

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/sessions` | Create session (Meta SDP offer -> Peer A) |
| `GET` | `/sessions/:id` | Get session status |
| `POST` | `/sessions/:id/agent-offer` | Generate agent-side SDP offer (Peer B) |
| `POST` | `/sessions/:id/agent-answer` | Set agent's SDP answer, complete Peer B |
| `POST` | `/sessions/:id/agent-reconnect` | Tear down old Peer B, create new one |
| `POST` | `/sessions/:id/terminate` | End call, finalize recording |
| `GET` | `/sessions/:id/recording` | Download recording (binary OGG) |
| `DELETE` | `/sessions/:id` | Cleanup session and files |

### Multi-participant

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/sessions/:id/peers` | Add a peer |
| `DELETE` | `/sessions/:id/peers/:peer_id` | Remove a peer |
| `PATCH` | `/sessions/:id/peers/:peer_id/role` | Change peer role |

### Audio Injection

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/sessions/:id/inject-audio` | Start audio injection |
| `DELETE` | `/sessions/:id/inject-audio/:inj_id` | Stop injection |

### System

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check (no auth) |
| `GET` | `/metrics` | Session metrics |

### Example: Create Session (Incoming Call)

```bash
curl -X POST http://localhost:4000/sessions \
  -H "Authorization: Bearer secret" \
  -H "Content-Type: application/json" \
  -d '{
    "call_id": "call_123",
    "account_id": "1",
    "direction": "incoming",
    "meta_sdp_offer": "v=0\r\no=- ...",
    "ice_servers": [{"urls": ["stun:stun.l.google.com:19302"]}]
  }'
```

Response:

```json
{
  "session_id": "sess_20240101120000_1",
  "meta_sdp_answer": "v=0\r\no=- ...",
  "status": "created"
}
```

## Recording

Recordings are written in real time as OGG/Opus files to the configured recordings directory. Three files are produced per call:

- `{session_id}.ogg` -- Combined audio for playback
- `{session_id}_customer.ogg` -- Customer channel only (for transcription)
- `{session_id}_agent.ogg` -- Agent channel only (for transcription)

On call termination, a callback is sent to Rails which fetches the recording via `GET /sessions/:id/recording` and stores it in ActiveStorage.

## Deployment

Add to `docker-compose.yml`:

```yaml
media-server:
  build:
    context: ./enterprise/media-server
  ports:
    - "4000:4000"
    - "10000-10100:10000-10100/udp"
  environment:
    - AUTH_TOKEN=${MEDIA_SERVER_AUTH_TOKEN}
    - RAILS_CALLBACK_URL=http://web:3000
    - STUN_SERVERS=stun:stun.l.google.com:19302
    - RECORDINGS_DIR=/recordings
    - UDP_PORT_MIN=10000
    - UDP_PORT_MAX=10100
  volumes:
    - media-recordings:/recordings
  restart: unless-stopped
```

UDP ports must be exposed to the internet for WebRTC connectivity. If direct UDP exposure is not possible, configure a TURN server as a relay.
