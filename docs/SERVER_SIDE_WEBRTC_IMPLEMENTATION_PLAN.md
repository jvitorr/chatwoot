# Server-Side WebRTC Migration -- Implementation Plan & Tracking

> **Feature branch:** `feat/whatsapp-call` | **Base branch:** `develop`
> **Feature flag (existing):** `whatsapp_call` | **Feature flag (new):** `whatsapp_call_server_media`
> **Created:** 2026-04-21 | **Status:** Planning

---

## Table of Contents

1. [Feature Requirements](#1-feature-requirements)
2. [Architecture Decision: WebRTC Peer B](#2-architecture-decision-webrtc-peer-b-not-websocket-audio)
3. [Current State Assessment](#3-current-state-assessment)
4. [Implementation Phases](#4-implementation-phases)
   - [Phase 1: Foundation](#phase-1-foundation--database--configuration--go-scaffold)
   - [Phase 2: Core Call Flow](#phase-2-core-call-flow)
   - [Phase 3: Recording](#phase-3-server-side-recording)
   - [Phase 4: Call Persistence & Reconnection](#phase-4-call-persistence--reconnection)
   - [Phase 5: Multi-Participant](#phase-5-multi-participant)
   - [Phase 6: Audio Injection](#phase-6-audio-injection--hold-music)
   - [Phase 7: AI Foundation](#phase-7-ai-captain-foundation)
5. [API Surface Changes](#5-api-surface-changes)
6. [Database Changes](#6-database-changes)
7. [Configuration & Environment Variables](#7-configuration--environment-variables)
8. [Risk Register](#8-risk-register)
9. [Testing Strategy](#9-testing-strategy)
10. [Rollout Plan](#10-rollout-plan)

---

## 1. Feature Requirements

Six core requirements drive this migration. Each is a hard prerequisite for considering the project complete.

### R1: End-to-End Calling Works Correctly

Inbound and outbound calls must complete the full lifecycle: ring, accept, two-way audio, hang up. The audio path changes from `Browser <-> Meta` to `Browser <-> Media Server <-> Meta`, but from the user's perspective behavior is identical. Latency increase must stay below 10ms (datacenter hop).

**Acceptance criteria:**
- Agent hears customer and customer hears agent with no perceptible quality loss.
- Outbound call flow (initiate, ring, connect, terminate) works end to end.
- Inbound call flow (webhook, ring, accept, audio, terminate) works end to end.
- SDP negotiation no longer requires the `actpass -> active` string replacement hack.

### R2: Call Persists When Browser Closes or Refreshes

The Meta-side WebRTC connection (Peer A) is held by the Go media server. When the agent's browser closes or refreshes, only the agent-side connection (Peer B) drops. The call stays alive for a configurable window (default 30 seconds), and the agent can reconnect automatically on page reload.

**Acceptance criteria:**
- Agent refreshes the page during an active call. The call does not terminate.
- On reload, the dashboard detects the active call and reconnects within 3 seconds.
- Customer hears silence (or hold tone) during the reconnection gap, not a disconnect.
- If the agent does not reconnect within 30s, the call terminates gracefully.
- The `beforeunload` handler no longer calls `terminateCallOnUnload`.

### R3: Call Recording Saved to Database / S3

Recording happens server-side in the Go media server. Both audio streams (customer via Peer A, agent via Peer B) are captured as OGG/Opus with stereo channel separation (L=customer, R=agent). On call end, Rails fetches the recording file from the media server via internal HTTP and attaches it to ActiveStorage.

**Acceptance criteria:**
- Recording is captured entirely server-side. No `MediaRecorder`, `AudioContext`, or WebM blob logic in the browser.
- Recording survives agent browser crash (server was recording the whole time).
- Recording is stereo: left channel = customer, right channel = agent.
- Recording is available in ActiveStorage within 60 seconds of call end.
- Existing transcription pipeline (`CallTranscriptionJob`) works with the new OGG/Opus format.

### R4: Multiple Frontends Can Join the Same Call

Multiple agent browser tabs or different agents can connect to the same call session. The media server supports multiple Peer B connections with roles: `active` (sends and receives audio), `listen_only` (receives audio, mic muted server-side), and `inject_only` (sends audio only, for playback systems).

**Acceptance criteria:**
- A supervisor can join an active call in listen-only mode and hear both sides.
- The primary agent's audio is not affected by a listener joining.
- A `call_participants` table tracks who is connected and their role.
- Frontend shows a participant list during active calls.

### R5: Play Song/Message to Caller

The media server can inject audio from a file (MP3, OGG, WAV) into the Meta-side peer (Peer A) as RTP packets. This enables hold music when the agent disconnects and pre-recorded announcements.

**Acceptance criteria:**
- When the agent disconnects, the customer automatically hears hold music instead of silence.
- An API endpoint allows playing an audio file to the caller mid-call.
- Audio injection does not interrupt the agent's audio when the agent is connected.
- Default hold music is configurable per account or inbox.

### R6: AI Captain Integration Readiness

The media server architecture supports tapping the audio stream for real-time AI processing. A plugin interface (`AudioConsumer`) allows external systems to receive a copy of the audio in real time. A "virtual peer" concept allows AI to inject audio (e.g., suggested responses, automated greetings) into the call.

**Acceptance criteria:**
- An `AudioConsumer` plugin interface exists in the Go media server.
- An RTP tap can stream audio to an external service (WebSocket or gRPC).
- A virtual peer can inject synthesized audio into the call.
- Rails has service hooks for AI streaming integration.
- No AI features ship in this migration -- this is the foundation only.

---

## 2. Architecture Decision: WebRTC Peer B (NOT WebSocket Audio)

### The Decision

The agent's browser connects to the Go media server via a standard WebRTC peer connection (Peer B). The browser still uses `RTCPeerConnection`, `getUserMedia`, and native audio playback -- but it peers with the Go server, not with Meta directly.

### Why WebRTC Peer B Over Binary WebSocket Relay

The alternative considered was streaming raw audio over WebSocket (binary frames of PCM or Opus). This was rejected for five reasons:

**1. Latency.** WebRTC delivers sub-50ms end-to-end latency via UDP with jitter buffers, adaptive bitrate, and congestion control built into the protocol. WebSocket runs over TCP, which adds 100-200ms of latency due to head-of-line blocking, Nagle's algorithm, and the lack of purpose-built jitter compensation. For real-time voice, this difference is audible.

**2. Echo cancellation.** Browser echo cancellation (AEC) is tightly coupled to the WebRTC stack. It operates on the `RTCPeerConnection` audio pipeline. With WebSocket audio, there is no native AEC -- it would need to be implemented manually or disabled entirely, causing echo for agents without headsets.

**3. No custom audio pipeline needed.** WebRTC handles decode, jitter buffering, volume normalization, and playback natively. WebSocket audio requires building all of this in JavaScript: decoding Opus frames, managing a playback buffer, scheduling `AudioContext` output, and handling underruns. This is hundreds of lines of fragile browser code.

**4. NAT traversal.** WebRTC handles NAT traversal automatically via ICE/STUN/TURN. WebSocket requires the server to be directly addressable on a stable URL (typically behind a reverse proxy), and does not support UDP fallback for restrictive networks.

**5. Code reuse.** The browser already has WebRTC code for the current direct-to-Meta flow. Switching to Peer B requires minimal frontend changes (different SDP source, remove recording). Switching to WebSocket audio would be a complete rewrite of the audio pipeline.

### What Changes for the Browser

| Aspect | Current (direct to Meta) | New (Peer B to media server) |
|--------|--------------------------|------------------------------|
| `RTCPeerConnection` target | Meta media servers | Go media server |
| SDP offer source | Meta webhook payload | Media server (via ActionCable) |
| SDP answer destination | Meta API (via Rails) | Media server (via Rails) |
| `MediaRecorder` | Active (browser records) | Removed (server records) |
| `beforeunload` behavior | Terminates call | Does nothing (call persists) |
| Reconnect on reload | Not possible | Automatic via `GET /active` |

### What Does NOT Change for the Browser

- Still uses `getUserMedia({ audio: true })` for microphone access.
- Still creates `RTCPeerConnection` with ICE servers.
- Still uses `ontrack` to play remote audio.
- Still uses `setRemoteDescription` and `createAnswer` for SDP exchange.
- The Vue composable API surface (`acceptCall`, `endActiveCall`, `toggleMute`) stays the same.

---

## 3. Current State Assessment

### What Exists Today (on `feat/whatsapp-call` branch)

The browser-direct WhatsApp calling feature is substantially implemented across 9 planned PRs. The following is already built or merged:

**Merged to `develop`:**
- PR-1: `Call` model, migration (`20260408170902_create_calls.rb`), error classes, feature flag definition.

**On `feat/whatsapp-call` branch (not yet merged):**
- `Whatsapp::IncomingCallService` -- processes Meta webhooks, creates Call records, broadcasts ActionCable events.
- `Whatsapp::CallService` -- accept/reject/terminate orchestration with `pre_accept_and_accept(sdp_answer)`.
- `Whatsapp::CallMessageBuilder` -- creates `voice_call` message content type.
- `Whatsapp::CallTranscriptionService` + `CallTranscriptionJob` -- OpenAI Whisper integration.
- `Whatsapp::CallPermissionReplyService` -- handles outbound call permission opt-in.
- `WhatsappCallsController` -- 6 endpoints (show, accept, reject, terminate, initiate, upload_recording).
- `WhatsappCloudCallMethods` -- Meta Cloud API provider layer.
- Frontend: API client, Pinia store, WebRTC composable, WhatsappCallWidget, VoiceCall bubble, ActionCable handlers, outbound UI in ConversationHeader.

### What Needs to Change for Server-Side WebRTC

The migration modifies existing code rather than replacing it entirely. The key changes are:

**Rails services (modify):**
- `IncomingCallService`: instead of storing Meta's SDP offer for the browser, create a media server session and store `media_session_id`.
- `CallService#pre_accept_and_accept`: no longer receives `sdp_answer` from the browser. Instead, the SDP answer comes from the media server. Orchestrates Peer B setup after accepting Meta's call.
- Controller: `accept` no longer requires `sdp_answer` parameter. New actions: `active`, `agent_answer`, `reconnect`. Remove `upload_recording`.

**Rails services (new):**
- `Whatsapp::MediaServerClient` -- HTTP client for the Go media server internal API.
- `Whatsapp::CallReconnectService` -- handles agent reconnection after page reload.
- `Whatsapp::CallRecordingFetchJob` -- Sidekiq job to fetch recording from media server on call end.

**Frontend (modify):**
- `useWhatsappCallSession.js`: remove `MediaRecorder` logic, remove `terminateCallOnUnload`, add reconnection flow, receive SDP from media server instead of Meta.
- `whatsappCalls.js` store: add reconnection state, handle `agent_offer` event.
- `whatsappCalls.js` API: remove `uploadRecording`, add `agentAnswer`, `reconnect`, `getActiveCall`.
- `ConversationHeader.vue`: outbound initiate no longer sends `sdp_offer` from browser.

**New component (Go):**
- `chatwoot-media-server` -- Pion-based sidecar handling Peer A (Meta), Peer B (agent), audio bridge, and recording.

### Known Technical Debt in Current Implementation

These issues exist in the current branch and should be resolved during or before the migration:

1. **Duplicated ICE gathering logic** -- `waitForOutboundIceGathering` in ConversationHeader duplicates `waitForIceGatheringComplete` in the composable. With Peer B, ICE gathering moves to the media server for Peer A and stays in the browser only for Peer B.
2. **No `onUnmounted` cleanup** for outbound calls in ConversationHeader. The outbound WebRTC objects (`outboundCall.pc`, `.stream`) leak if the component unmounts mid-call.
3. **Hardcoded STUN server** -- `stun:stun.l.google.com:19302` with no backend-provided configuration. The media server migration introduces proper ICE server configuration via environment variables.
4. **`console.log` left in** -- ICE state logging in ConversationHeader.
5. **Recording mimeType assumption** -- `audio/webm;codecs=opus` with no browser feature detection. Moot after migration (server records).
6. **Bare string in ActionCable** -- `onWhatsappCallPermissionGranted` uses template literal instead of i18n key.
7. **Feature flag unused on frontend** -- `FEATURE_FLAGS.WHATSAPP_CALL` declared but no component checks it.

---

## 4. Implementation Phases

### Phase 1: Foundation -- Database, Configuration, Go Scaffold

**Goal:** Infrastructure prerequisites. The media server has a health endpoint, Rails can talk to it, and the database supports media session tracking.

**Estimated effort:** 1 week

#### Database Migration

- [ ] **`db/migrate/YYYYMMDDHHMMSS_add_media_session_id_to_calls.rb`** (NEW)
  - Add `media_session_id` string column to `calls` table
  - Add index on `media_session_id`
  - Migration is backward-compatible (nullable column, no default)

#### Rails Configuration

- [ ] **`enterprise/app/services/whatsapp/media_server_client.rb`** (NEW)
  - HTTP client wrapping Faraday for communication with the Go media server
  - Methods: `create_session`, `meta_sdp`, `agent_offer`, `agent_answer`, `agent_reconnect`, `terminate`, `session_status`, `download_recording`, `health`
  - Authentication via Bearer token from `ENV['MEDIA_SERVER_AUTH_TOKEN']`
  - Timeout configuration: 5s connect, 30s read (SDP generation may involve ICE gathering)
  - Error handling: raise `Whatsapp::CallErrors::MediaServerError` on failures
  - Circuit breaker pattern: if health check fails 3 times, stop attempting new sessions

- [ ] **`config/media_server.yml`** (NEW) or environment variable approach
  - `MEDIA_SERVER_URL` (default: `http://localhost:4000`)
  - `MEDIA_SERVER_AUTH_TOKEN`
  - `MEDIA_SERVER_STUN_SERVERS` (comma-separated, default: `stun:stun.l.google.com:19302`)
  - `MEDIA_SERVER_TURN_SERVERS` (optional)
  - `MEDIA_SERVER_TURN_USERNAME` (optional)
  - `MEDIA_SERVER_TURN_PASSWORD` (optional)
  - `MEDIA_SERVER_PUBLIC_IP` (required for ICE candidate in SDP)

- [ ] **`enterprise/app/models/call.rb`** (MODIFY)
  - Add `media_session_id` accessor and convenience methods
  - Add `media_session_active?` method that checks media server status
  - Add `meta_server_url` method (for multi-instance routing in the future)

#### Go Media Server Scaffold

- [ ] **`enterprise/media-server/main.go`** (NEW)
  - HTTP server on configurable port (default 4000)
  - Graceful shutdown on SIGTERM/SIGINT
  - Structured logging (JSON format for production)

- [ ] **`enterprise/media-server/config/config.go`** (NEW)
  - Parse environment variables: `AUTH_TOKEN`, `STUN_SERVERS`, `TURN_SERVERS`, `PUBLIC_IP`, `UDP_PORT_MIN`, `UDP_PORT_MAX`, `RECORDINGS_DIR`, `RAILS_CALLBACK_URL`, `LOG_LEVEL`

- [ ] **`enterprise/media-server/api/handler.go`** (NEW)
  - Route definitions for all endpoints
  - `GET /health` returns `{"status": "ok", "active_sessions": N, "uptime_seconds": N}`

- [ ] **`enterprise/media-server/api/middleware.go`** (NEW)
  - Bearer token authentication middleware
  - Request logging middleware
  - Recovery/panic middleware

- [ ] **`enterprise/media-server/go.mod`** (NEW)
  - Module: `github.com/chatwoot/chatwoot-media-server`
  - Dependencies: `pion/webrtc/v4`, `pion/interceptor`, standard library HTTP

- [ ] **`enterprise/media-server/Dockerfile`** (NEW)
  - Multi-stage build: Go build stage + scratch/alpine runtime
  - Target image size: under 30 MB
  - Expose port 4000 (HTTP) and UDP port range

- [ ] **`docker-compose.yml`** (MODIFY) or **`docker-compose.deploy.yaml`** (MODIFY)
  - Add `media-server` service definition
  - UDP port range exposure: `10000-10100:10000-10100/udp`
  - Shared volume for recordings
  - Health check pointing to `/health`
  - Environment variables from `.env`

- [ ] **`Procfile.dev`** (MODIFY)
  - Add media server process: `media: ./enterprise/media-server/chatwoot-media-server`

#### Verification

- [ ] `GET /health` returns 200 from inside Docker network
- [ ] `MediaServerClient.new.health` returns successfully from Rails console
- [ ] Migration runs cleanly: `bundle exec rails db:migrate`
- [ ] `Call.new(media_session_id: 'test')` works

---

### Phase 2: Core Call Flow

**Goal:** Inbound and outbound calls work end-to-end through the media server. The browser peers with the Go server, not Meta directly.

**Estimated effort:** 2-3 weeks

#### Go Media Server: Peer A (Meta-side WebRTC)

- [ ] **`enterprise/media-server/session/manager.go`** (NEW)
  - Thread-safe session map (sync.RWMutex)
  - `CreateSession(callID, metaSDP, iceServers)` -- creates session and Peer A
  - `FindSession(sessionID)` -- lookup by ID
  - `DestroySession(sessionID)` -- teardown both peers
  - Periodic cleanup goroutine: destroy sessions idle for >2 hours
  - Session creation rate limit per account_id

- [ ] **`enterprise/media-server/session/session.go`** (NEW)
  - Holds Peer A, Peer B (optional), bridge, recording state
  - State machine: `created -> meta_peer_ready -> bridged -> agent_disconnected -> terminated`
  - `SetMetaSDP(offer) -> answer` -- set Meta's SDP on Peer A, return generated answer
  - `CreateAgentOffer() -> sdpOffer` -- create Peer B, generate SDP offer for agent
  - `SetAgentAnswer(answer)` -- complete Peer B, start bridge and recording
  - `AgentReconnect() -> sdpOffer` -- tear down old Peer B, create new one
  - `Terminate()` -- close both peers, finalize recording, notify Rails

- [ ] **`enterprise/media-server/session/peer.go`** (NEW)
  - Wraps `pion/webrtc.PeerConnection`
  - Configures audio-only media (no video)
  - ICE candidate handling: trickle or full gather (configurable)
  - ICE candidate filtering: strip `host` candidates from agent-facing offers
  - `OnTrack` callback registration for the bridge
  - `OnICEConnectionStateChange` callback for disconnect detection

- [ ] **`enterprise/media-server/session/bridge.go`** (NEW)
  - Forward RTP packets from Peer A remote track to Peer B local track
  - Forward RTP packets from Peer B remote track to Peer A local track
  - Tap both streams for the recording pipeline
  - Packet copying (not pointer sharing) to avoid races between bridge and recorder
  - Graceful handling of one peer disconnecting while the other stays up

#### Go Media Server: Peer B (Agent-side WebRTC)

- [ ] **Peer B creation in `session.go`** (part of session implementation above)
  - Create `PeerConnection` with STUN/TURN configuration
  - Add audio transceiver (sendrecv)
  - Generate SDP offer with ICE candidates
  - Public IP override in SDP if `MEDIA_SERVER_PUBLIC_IP` is set
  - On Peer B ICE failure: transition to `agent_disconnected`, notify Rails via callback

#### Go Media Server: HTTP API Endpoints

- [ ] **`enterprise/media-server/api/session_handler.go`** (NEW)
  - `POST /sessions` -- create session with Meta SDP, return session_id + SDP answer
  - `GET /sessions/:id/status` -- return session state, peer connection states, duration
  - `DELETE /sessions/:id` -- force-destroy session

- [ ] **`enterprise/media-server/api/meta_sdp_handler.go`** (NEW)
  - `POST /sessions/:id/meta-sdp` -- for outbound calls: set Meta's SDP answer on Peer A

- [ ] **`enterprise/media-server/api/agent_handler.go`** (NEW)
  - `POST /sessions/:id/agent-offer` -- generate SDP offer for agent browser
  - `POST /sessions/:id/agent-answer` -- set agent's SDP answer, start bridge
  - `POST /sessions/:id/agent-reconnect` -- tear down old Peer B, create new offer

- [ ] **`enterprise/media-server/api/recording_handler.go`** (NEW, stub for Phase 3)
  - `GET /sessions/:id/recording` -- download recording file (returns 404 until Phase 3)

- [ ] **`enterprise/media-server/callback/rails_client.go`** (NEW)
  - HTTP client for callbacks to Rails
  - `POST /api/internal/media_server/callbacks` with events: `agent_disconnected`, `agent_reconnected`, `session_terminated`, `recording_ready`
  - Retry logic: 3 attempts with exponential backoff
  - Authentication: same shared secret token

#### Rails: Modify IncomingCallService

- [ ] **`enterprise/app/services/whatsapp/incoming_call_service.rb`** (MODIFY)
  - In `handle_call_connect` for inbound calls:
    - After creating the Call record, call `MediaServerClient.create_session` with Meta's SDP offer
    - Store `media_session_id` on the Call record
    - Store the media server's SDP answer (to send to Meta) instead of Meta's SDP offer (for the browser)
    - The SDP answer sent to Meta comes from the media server, not the browser
  - Feature-flagged: check `whatsapp_call_server_media` flag to use new path vs legacy
  - In `broadcast_incoming_call`: do NOT include `sdp_offer` in the ActionCable payload (the browser no longer needs it for direct peering)

#### Rails: Modify CallService

- [ ] **`enterprise/app/services/whatsapp/call_service.rb`** (MODIFY)
  - `pre_accept_and_accept` no longer receives `sdp_answer` from the browser
  - New flow:
    1. Lock the call row, validate ringing state
    2. Call Meta's `pre_accept_call` with the SDP answer stored in `Call.meta` (from the media server)
    3. Call Meta's `accept_call` with the same SDP answer
    4. Update call status to `in_progress`
    5. Request agent-side SDP offer from media server: `MediaServerClient.agent_offer(media_session_id)`
    6. Broadcast `whatsapp_call.agent_offer` via ActionCable with the SDP offer and ICE servers
  - Outbound `initiate` flow:
    1. Create media session (direction: outbound, no Meta SDP yet)
    2. Get SDP offer from media server for Meta
    3. Call Meta's `initiate_call` with the media server's SDP offer
    4. On Meta's webhook with SDP answer, call `MediaServerClient.meta_sdp(session_id, sdp_answer)` to complete Peer A
    5. Then set up Peer B same as inbound
  - New method: `agent_answer(sdp_answer)` -- forwards agent's SDP answer to media server

#### New Controller Actions

- [ ] **`enterprise/app/controllers/api/v1/accounts/whatsapp_calls_controller.rb`** (MODIFY)
  - `GET /active` (NEW action) -- return the agent's currently active call (if any), used for reconnection on page load
    ```
    GET /api/v1/accounts/:account_id/whatsapp_calls/active
    Response: { id, call_id, status, conversation_id, started_at, duration_seconds } or 204 No Content
    ```
  - `POST /:id/agent_answer` (NEW action) -- receive SDP answer from agent browser, forward to media server
    ```
    POST /api/v1/accounts/:account_id/whatsapp_calls/:id/agent_answer
    Body: { sdp_answer: "..." }
    ```
  - `POST /:id/reconnect` (NEW action) -- agent reconnects to an active call after page reload
    ```
    POST /api/v1/accounts/:account_id/whatsapp_calls/:id/reconnect
    Response: { sdp_offer: "...", ice_servers: [...] }
    ```
  - `POST /:id/accept` (MODIFY) -- remove `sdp_answer` requirement from params
  - `POST /initiate` (MODIFY) -- remove `sdp_offer` requirement from params

- [ ] **`config/routes.rb`** (MODIFY)
  - Add `member` routes: `agent_answer`, `reconnect`
  - Add `collection` route: `active`

#### Rails: Internal Callbacks Controller

- [ ] **`enterprise/app/controllers/api/internal/media_server/callbacks_controller.rb`** (NEW)
  - Receives events from the Go media server
  - Authentication: validate shared secret token
  - Events handled:
    - `agent_disconnected`: broadcast `whatsapp_call.agent_disconnected` via ActionCable, start reconnect timer
    - `recording_ready`: enqueue `CallRecordingFetchJob`
    - `session_terminated`: if call not already terminated, update status and broadcast

- [ ] **`config/routes.rb`** (MODIFY)
  - Add internal API namespace for media server callbacks

#### ActionCable Event Changes

- [ ] **`app/javascript/dashboard/helper/actionCable.js`** (MODIFY)
  - Add handler for `whatsapp_call.agent_offer` -- delivers SDP offer from media server to the agent browser for Peer B setup
  - Add handler for `whatsapp_call.agent_disconnected` -- notifies other tabs/agents that the primary agent's connection dropped
  - Modify `whatsapp_call.incoming` handler -- no longer includes `sdp_offer` in payload
  - Modify `whatsapp_call.outbound_connected` handler -- no longer includes `sdp_answer` in payload (SDP exchange happens via media server)

#### Frontend Composable Refactor

- [ ] **`app/javascript/dashboard/composables/useWhatsappCallSession.js`** (MODIFY)
  - **Remove:** `startCallRecording`, `stopAndUploadRecording`, `mediaRecorder`, `recordedChunks`, `recordingCallId` -- all recording logic
  - **Remove:** `terminateCallOnUnload` -- call persists on page close
  - **Modify `doAcceptCall`:**
    - No longer receives `sdp_offer` from Meta
    - No longer calls `pc.setRemoteDescription` with Meta's offer
    - No longer calls `WhatsappCallsAPI.accept(call.id, completeSdp)`
    - New flow: call `WhatsappCallsAPI.accept(call.id)` (no SDP), then wait for `agent_offer` ActionCable event
  - **Add `handleAgentOffer(sdpOffer, iceServers)`:**
    - Called when `whatsapp_call.agent_offer` event arrives
    - `getUserMedia({ audio: true })`
    - Create `RTCPeerConnection` with provided `iceServers`
    - `setRemoteDescription(offer)` with media server's SDP offer
    - `createAnswer()` + ICE gathering
    - POST SDP answer to `WhatsappCallsAPI.agentAnswer(callId, sdpAnswer)`
  - **Modify `beforeunload` handler:**
    - Do NOT call `terminateCallOnUnload`
    - Just clean up the local `RTCPeerConnection` and `MediaStream` (Peer B dies naturally)
  - **Remove** `startCallRecording` call from `pc.ontrack` handler

- [ ] **`app/javascript/dashboard/stores/whatsappCalls.js`** (MODIFY)
  - Add state: `isReconnecting` (boolean), `reconnectAttempts` (number)
  - Add action: `handleAgentOffer(payload)` -- stores the SDP offer and triggers the composable
  - Add action: `setReconnecting(value)` -- manages reconnection UI state
  - Remove: outbound call `sdp_offer` handling (the browser no longer generates the initial offer for outbound)
  - Add action: `handleAgentDisconnected(callId)` -- handles notification that agent connection dropped (for multi-tab awareness)

- [ ] **`app/javascript/dashboard/api/whatsappCalls.js`** (MODIFY)
  - `accept(callId)` -- remove `sdpAnswer` parameter
  - `initiate(conversationId)` -- remove `sdpOffer` parameter
  - **Add:** `agentAnswer(callId, sdpAnswer)` -- POST SDP answer to new endpoint
  - **Add:** `reconnect(callId)` -- POST to reconnect endpoint
  - **Add:** `getActiveCall()` -- GET active call for current agent
  - **Remove:** `uploadRecording(callId, blob)`

- [ ] **`app/javascript/dashboard/components/widgets/conversation/ConversationHeader.vue`** (MODIFY)
  - Remove outbound `RTCPeerConnection` creation and SDP offer generation
  - Remove `waitForOutboundIceGathering` (duplicated ICE logic)
  - Remove `console.log` statements for ICE state
  - Outbound initiate now just calls `WhatsappCallsAPI.initiate(conversationId)` with no SDP
  - Wait for `agent_offer` event (same as inbound) after contact answers

#### Verification

- [ ] Inbound call: Meta webhook -> media server session -> agent accepts -> audio flows through media server
- [ ] Outbound call: agent initiates -> media server creates offer -> Meta receives -> contact answers -> audio flows
- [ ] SDP exchange does not require `actpass -> active` string replacement
- [ ] Both browser-direct (legacy) and server-media paths work when feature-flagged

---

### Phase 3: Server-Side Recording

**Goal:** Recording happens entirely on the Go media server. Browser recording code is removed. Recordings are fetched by Rails on call end.

**Estimated effort:** 1 week

#### Go Media Server: Recording Pipeline

- [ ] **`enterprise/media-server/recording/recorder.go`** (NEW)
  - Receives decoded Opus frames from both Peer A and Peer B via the bridge's tap
  - Writes frames into OGG/Opus container in real time
  - Stereo separation: Peer A (customer) on left channel, Peer B (agent) on right channel
  - File path: `/recordings/{session_id}.ogg`
  - Starts when both peers are connected and bridge is active
  - Pauses agent channel (writes silence) when Peer B is disconnected (reconnection gap)
  - Finalizes (writes OGG trailer) when session terminates

- [ ] **`enterprise/media-server/recording/ogg_writer.go`** (NEW)
  - Low-level OGG page construction
  - Handles page sequencing, checksums, and granule position tracking
  - Based on Pion's `oggreader`/`oggwriter` examples

- [ ] **`enterprise/media-server/recording/cleanup.go`** (NEW)
  - On startup: scan `/recordings/` for orphaned files (sessions that no longer exist)
  - Report orphaned files to Rails via callback
  - Delete orphaned files older than 24 hours

- [ ] **`enterprise/media-server/api/recording_handler.go`** (MODIFY -- implement the stub from Phase 2)
  - `GET /sessions/:id/recording` -- stream the finalized OGG file with `Content-Type: audio/ogg`
  - `POST /sessions/:id/terminate` response now includes `recording_file`, `recording_size_bytes`, `duration_seconds`

#### Rails: Recording Fetch Job

- [ ] **`enterprise/app/jobs/whatsapp/call_recording_fetch_job.rb`** (NEW)
  - Triggered by `recording_ready` callback from media server
  - Downloads recording from `MediaServerClient.download_recording(session_id)`
  - Attaches to `call.recording` via ActiveStorage
  - Updates the message bubble with recording URL via `CallMessageBuilder.update_recording_url!`
  - Enqueues `CallTranscriptionJob` after successful attachment
  - Retry: 3 attempts with exponential backoff
  - On final failure: log error, mark call with `recording_fetch_failed` in meta

#### Rails: Remove Browser Upload Path

- [ ] **`enterprise/app/controllers/api/v1/accounts/whatsapp_calls_controller.rb`** (MODIFY)
  - Remove `upload_recording` action (behind feature flag -- keep for legacy path)
  - Remove `attach_recording_and_enqueue_transcription` private method (behind feature flag)

#### Frontend: Remove Recording Code

- [ ] **`app/javascript/dashboard/composables/useWhatsappCallSession.js`** (MODIFY)
  - Remove `startCallRecording` export
  - Remove `stopAndUploadRecording` function
  - Remove `mediaRecorder`, `recordedChunks`, `recordingCallId` module-level variables
  - Remove `startCallRecording(pc, stream, call.id)` call from `ontrack` handler
  - Remove `stopAndUploadRecording()` from cleanup callback and `endActiveCall`

- [ ] **`app/javascript/dashboard/api/whatsappCalls.js`** (MODIFY)
  - Remove `uploadRecording` method (if not already removed in Phase 2)

#### Verification

- [ ] Call completes -> recording appears in ActiveStorage within 60 seconds
- [ ] Recording is OGG/Opus format, playable in browser audio player
- [ ] Recording has stereo channels (customer left, agent right)
- [ ] Transcription job runs successfully on the new format
- [ ] Browser has zero recording-related code when `whatsapp_call_server_media` is enabled
- [ ] Agent browser crash mid-call -> recording is still captured up to the crash point

---

### Phase 4: Call Persistence & Reconnection

**Goal:** Calls survive browser close/refresh. Automatic reconnection on page reload.

**Estimated effort:** 1-2 weeks

#### Go Media Server: Disconnect Detection & Hold

- [ ] **`enterprise/media-server/session/session.go`** (MODIFY)
  - On Peer B ICE connection state `disconnected` or `failed`:
    - Transition session state to `agent_disconnected`
    - Keep Peer A alive (Meta audio continues to flow into the bridge's buffer)
    - Start reconnect timeout (configurable, default 30s)
    - Callback to Rails: `agent_disconnected` event
    - If hold music is configured (Phase 6), start playing it to Peer A
  - On reconnect timeout expiry:
    - Callback to Rails: `session_terminated` with reason `agent_reconnect_timeout`
    - Terminate session

- [ ] **`enterprise/media-server/session/session.go`** (MODIFY -- reconnect logic)
  - `AgentReconnect()`:
    - Tear down old Peer B (close connection, release resources)
    - Create new Peer B with fresh SDP offer
    - On successful answer: re-bridge audio, resume recording
    - Callback to Rails: `agent_reconnected` event
    - Increment reconnect counter on session

#### Rails: Reconnection Support

- [ ] **`enterprise/app/services/whatsapp/call_reconnect_service.rb`** (NEW)
  - Called from `WhatsappCallsController#reconnect`
  - Validates: call is `in_progress`, call has `media_session_id`, requesting agent is the accepted agent
  - Calls `MediaServerClient.agent_reconnect(media_session_id)`
  - Returns new SDP offer for the agent browser
  - Broadcasts `whatsapp_call.agent_offer` via ActionCable

- [ ] **`enterprise/app/controllers/api/v1/accounts/whatsapp_calls_controller.rb`** (MODIFY -- `active` action)
  - `GET /active`: find the current user's active call (status `in_progress`, `accepted_by_agent_id` = current_user.id)
  - Return call details including `media_session_id`, `started_at`, `conversation_id`
  - Used by the frontend on page load to detect if a call needs reconnection

#### Frontend: Reconnection Composable

- [ ] **`app/javascript/dashboard/composables/useCallReconnection.js`** (NEW)
  - On mount: call `WhatsappCallsAPI.getActiveCall()`
  - If active call exists:
    - Set store state: `isReconnecting = true`
    - Show reconnection UI: "Call in progress -- Reconnecting..."
    - Call `WhatsappCallsAPI.reconnect(callId)`
    - Handle `agent_offer` event (same flow as initial accept)
    - On success: `isReconnecting = false`, show active call UI with correct timer
    - On failure: offer "Retry" button or end call
  - Timer continuity: calculate elapsed time from `started_at` returned by server, not local state

- [ ] **`app/javascript/dashboard/composables/useWhatsappCallSession.js`** (MODIFY)
  - **Remove `terminateCallOnUnload`** function entirely
  - **Modify `handleBeforeUnload`:**
    - Do NOT terminate the call
    - Clean up local WebRTC resources (close `RTCPeerConnection`, stop `MediaStream` tracks)
    - The media server detects Peer B disconnect via ICE and handles it
  - **Add reconnection integration:**
    - On composable mount, check for active call via `useCallReconnection`
    - If reconnecting, skip the incoming call widget and go straight to active call UI

- [ ] **`app/javascript/dashboard/stores/whatsappCalls.js`** (MODIFY)
  - Add `isReconnecting` state
  - Add `reconnectAttempts` counter
  - `handleAgentDisconnected(callId)`: set `isReconnecting = true` if this is our active call

- [ ] **`app/javascript/dashboard/components/widgets/WhatsappCallWidget.vue`** (MODIFY)
  - Add reconnecting state to the widget UI
  - Show "Reconnecting..." with a spinner instead of the normal call controls
  - Display server-tracked call duration (from `started_at`) instead of local timer

#### Verification

- [ ] Agent refreshes page during active call -> call does not terminate
- [ ] On reload, dashboard shows "Reconnecting..." and audio resumes within 3 seconds
- [ ] Call duration timer is continuous (no reset on reconnect)
- [ ] Customer hears silence (or hold tone) during the 1-3 second gap
- [ ] If agent does not reconnect within 30s, call terminates and Meta receives hangup
- [ ] Multiple reconnections work (refresh 5 times in a row)
- [ ] Recording is continuous across reconnections (single file, agent channel silent during gaps)

---

### Phase 5: Multi-Participant

**Goal:** Multiple agents can join the same call with different roles.

**Estimated effort:** 2 weeks

#### Database

- [ ] **`db/migrate/YYYYMMDDHHMMSS_create_call_participants.rb`** (NEW)
  ```
  create_table :call_participants do |t|
    t.bigint :call_id, null: false
    t.bigint :user_id, null: false
    t.string :role, null: false, default: 'active'  # active, listen_only, inject_only
    t.string :peer_id  # media server peer identifier
    t.datetime :joined_at
    t.datetime :left_at
    t.timestamps
  end
  add_index :call_participants, [:call_id, :user_id], unique: true
  add_index :call_participants, :call_id
  ```

- [ ] **`enterprise/app/models/call_participant.rb`** (NEW)
  - `belongs_to :call`
  - `belongs_to :user`
  - Validations: role inclusion, uniqueness of user per call
  - Scopes: `active`, `connected` (where `left_at` is nil)

- [ ] **`enterprise/app/models/call.rb`** (MODIFY)
  - `has_many :call_participants`
  - `has_many :participants, through: :call_participants, source: :user`

#### Go Media Server: Multi-Peer Support

- [ ] **`enterprise/media-server/session/session.go`** (MODIFY)
  - Support multiple Peer B connections per session (keyed by `peer_id`)
  - Each peer has a role:
    - `active`: bidirectional audio (current single-agent behavior)
    - `listen_only`: receives mixed audio from Peer A + all active peers, does not transmit
    - `inject_only`: can send audio into the mix but does not receive
  - Audio bridge modification: mix audio from Peer A + all active peer B connections, send mixed output to each peer

- [ ] **`enterprise/media-server/session/mixer.go`** (NEW)
  - Audio mixer: combine Opus frames from multiple sources
  - For each output peer: mix all other sources (exclude self to prevent echo)
  - Efficient: only active when multiple active peers exist, otherwise pass-through

#### Rails: Join/Leave Endpoints

- [ ] **`enterprise/app/controllers/api/v1/accounts/whatsapp_calls_controller.rb`** (MODIFY)
  - `POST /:id/join` -- join an active call as listener or active participant
  - `POST /:id/leave` -- leave the call (close your Peer B)
  - `GET /:id/participants` -- list current participants and their roles

- [ ] **`enterprise/app/services/whatsapp/call_participant_service.rb`** (NEW)
  - `join(call, user, role)`: create participant record, request peer from media server
  - `leave(call, user)`: update participant record, disconnect peer on media server
  - Authorization: only agents with access to the conversation can join

#### Frontend: Participant List

- [ ] **`app/javascript/dashboard/components/widgets/WhatsappCallParticipants.vue`** (NEW)
  - Show list of connected participants with their roles
  - "Join as listener" button for supervisors
  - Uses Tailwind for styling, Composition API with `<script setup>`

#### Verification

- [ ] Supervisor joins active call in listen_only mode and hears both sides
- [ ] Primary agent's audio quality unaffected by listener joining
- [ ] `call_participants` table accurately reflects join/leave events
- [ ] Participant list UI updates in real time via ActionCable

---

### Phase 6: Audio Injection / Hold Music

**Goal:** The media server can play audio files to the caller. Hold music plays automatically when the agent disconnects.

**Estimated effort:** 1-2 weeks

#### Go Media Server: Audio File Injection

- [ ] **`enterprise/media-server/audio/decoder.go`** (NEW)
  - Decode audio files (MP3, OGG, WAV) to PCM
  - Resample to 48kHz mono (Opus input format)
  - Use Go standard library + minimal decoder packages

- [ ] **`enterprise/media-server/audio/encoder.go`** (NEW)
  - Encode PCM frames to Opus
  - Package Opus frames as RTP packets with correct timestamps

- [ ] **`enterprise/media-server/audio/injector.go`** (NEW)
  - `InjectFile(session, filePath, loop bool)` -- decode file, encode to Opus, inject RTP packets into Peer A's send track
  - `StopInjection(session)` -- stop current injection
  - Loop support for hold music (seamless restart when file ends)
  - Mixing: if agent is connected, mix injected audio with agent audio. If agent is disconnected, injected audio is the only source.

- [ ] **`enterprise/media-server/session/session.go`** (MODIFY)
  - On agent disconnect: if hold music path is configured, automatically start injection
  - On agent reconnect: stop hold music injection, resume agent audio bridge

- [ ] **`enterprise/media-server/api/audio_handler.go`** (NEW)
  - `POST /sessions/:id/play_audio` -- trigger audio file playback
    ```
    Body: { file_path: "/audio/hold_music.ogg", loop: true }
    ```
  - `POST /sessions/:id/stop_audio` -- stop current playback

#### Rails: Audio Asset Management

- [ ] **Model or ActiveStorage approach for audio assets** (decision needed)
  - Option A: `CallAudioAsset` model with ActiveStorage attachment + account_id
  - Option B: Pre-deploy audio files to the media server's filesystem
  - Recommendation: Option B for MVP (simpler), Option A for production
  - Default hold music file ships with the media server Docker image

- [ ] **`enterprise/app/controllers/api/v1/accounts/whatsapp_calls_controller.rb`** (MODIFY)
  - `POST /:id/play_audio` -- trigger audio playback for a call
  - Parameters: `audio_asset_id` or `audio_type` (e.g., "hold_music")

#### Configuration

- [ ] **Hold music configuration:**
  - Default file: bundled with media server Docker image at `/audio/default_hold_music.ogg`
  - Environment variable: `HOLD_MUSIC_PATH` (override default)
  - Future: per-account or per-inbox configuration via `CallAudioAsset` model

#### Verification

- [ ] Agent disconnects -> customer hears hold music within 2 seconds
- [ ] Agent reconnects -> hold music stops, agent audio resumes
- [ ] `play_audio` API endpoint plays a file to the caller mid-call
- [ ] Audio injection mixes correctly with agent audio when both are present

---

### Phase 7: AI Captain Foundation

**Goal:** The architecture supports real-time audio streaming for AI processing. No AI features ship -- this is infrastructure only.

**Estimated effort:** 1-2 weeks

#### Go Media Server: Plugin Interface

- [ ] **`enterprise/media-server/plugin/consumer.go`** (NEW)
  - `AudioConsumer` interface:
    ```go
    type AudioConsumer interface {
        OnAudioFrame(sessionID string, source string, frame []byte, timestamp uint32)
        OnSessionStart(sessionID string, metadata map[string]string)
        OnSessionEnd(sessionID string)
    }
    ```
  - Registry: `RegisterConsumer(name string, consumer AudioConsumer)`
  - Bridge modification: after forwarding each RTP packet, call all registered consumers

- [ ] **`enterprise/media-server/plugin/rtp_tap.go`** (NEW)
  - `RTPTap` implementation of `AudioConsumer`
  - Streams decoded audio frames to an external service via WebSocket or gRPC
  - Configurable target URL
  - Buffering: ring buffer to handle temporary target unavailability
  - Backpressure: drop frames if buffer is full (real-time audio cannot wait)

- [ ] **`enterprise/media-server/session/virtual_peer.go`** (NEW)
  - "Virtual peer" concept: a peer that exists only in software (no browser, no external WebRTC)
  - Can inject audio into the bridge (e.g., TTS output from AI)
  - Can receive audio from the bridge (e.g., for STT input)
  - Registered as a special participant with role `ai`

#### Rails: AI Service Hooks

- [ ] **`enterprise/app/services/whatsapp/call_ai_streaming_service.rb`** (NEW, stub)
  - Interface for connecting a call session to AI Captain
  - Methods: `start_streaming(call)`, `stop_streaming(call)`, `inject_audio(call, audio_data)`
  - Stub implementation that logs actions -- actual AI integration is a separate project

#### Verification

- [ ] `AudioConsumer` interface compiles and can be registered
- [ ] RTP tap successfully streams audio frames to a test WebSocket endpoint
- [ ] Virtual peer can inject audio that the customer hears
- [ ] Rails AI service hooks exist and are callable (even though they are stubs)

---

## 5. API Surface Changes

### New Go Media Server Internal HTTP API

All endpoints are internal-only, authenticated via Bearer token.

| Method | Path | Phase | Description |
|--------|------|-------|-------------|
| `GET` | `/health` | 1 | Health check with active session count |
| `POST` | `/sessions` | 2 | Create session with Meta SDP, return SDP answer |
| `POST` | `/sessions/:id/meta-sdp` | 2 | Set Meta's SDP answer (outbound calls) |
| `POST` | `/sessions/:id/agent-offer` | 2 | Generate SDP offer for agent browser |
| `POST` | `/sessions/:id/agent-answer` | 2 | Set agent's SDP answer, start audio bridge |
| `POST` | `/sessions/:id/agent-reconnect` | 4 | Tear down old Peer B, create new SDP offer |
| `POST` | `/sessions/:id/terminate` | 2 | End session, finalize recording |
| `GET` | `/sessions/:id/status` | 2 | Session state, peer ICE states, duration |
| `GET` | `/sessions/:id/recording` | 3 | Download finalized recording file |
| `DELETE` | `/sessions/:id` | 2 | Force-destroy session |
| `POST` | `/sessions/:id/play_audio` | 6 | Play audio file to caller |
| `POST` | `/sessions/:id/stop_audio` | 6 | Stop current audio playback |

### New/Modified Rails API Endpoints

| Method | Path | Phase | Change | Description |
|--------|------|-------|--------|-------------|
| `GET` | `/api/v1/accounts/:id/whatsapp_calls/active` | 2 | NEW | Get agent's currently active call |
| `POST` | `/api/v1/accounts/:id/whatsapp_calls/:id/accept` | 2 | MODIFY | No longer requires `sdp_answer` param |
| `POST` | `/api/v1/accounts/:id/whatsapp_calls/:id/agent_answer` | 2 | NEW | Forward agent's SDP answer to media server |
| `POST` | `/api/v1/accounts/:id/whatsapp_calls/:id/reconnect` | 4 | NEW | Reconnect to active call after page reload |
| `POST` | `/api/v1/accounts/:id/whatsapp_calls/initiate` | 2 | MODIFY | No longer requires `sdp_offer` param |
| `POST` | `/api/v1/accounts/:id/whatsapp_calls/:id/upload_recording` | 3 | REMOVE | Server records now; endpoint deprecated |
| `POST` | `/api/v1/accounts/:id/whatsapp_calls/:id/join` | 5 | NEW | Join call as participant |
| `POST` | `/api/v1/accounts/:id/whatsapp_calls/:id/leave` | 5 | NEW | Leave call |
| `GET` | `/api/v1/accounts/:id/whatsapp_calls/:id/participants` | 5 | NEW | List call participants |
| `POST` | `/api/v1/accounts/:id/whatsapp_calls/:id/play_audio` | 6 | NEW | Play audio to caller |
| `POST` | `/api/internal/media_server/callbacks` | 2 | NEW | Receive events from media server |

### Modified ActionCable Events

| Event | Phase | Change | Payload Diff |
|-------|-------|--------|-------------|
| `whatsapp_call.incoming` | 2 | MODIFY | Remove `sdp_offer` and `ice_servers` (browser no longer needs Meta's SDP) |
| `whatsapp_call.agent_offer` | 2 | NEW | `{ call_id, sdp_offer, ice_servers }` -- media server's SDP offer for Peer B |
| `whatsapp_call.agent_disconnected` | 4 | NEW | `{ call_id, reconnect_timeout_seconds }` |
| `whatsapp_call.agent_reconnected` | 4 | NEW | `{ call_id }` |
| `whatsapp_call.outbound_connected` | 2 | MODIFY | Remove `sdp_answer` (SDP goes through media server) |
| `whatsapp_call.participant_joined` | 5 | NEW | `{ call_id, user_id, role }` |
| `whatsapp_call.participant_left` | 5 | NEW | `{ call_id, user_id }` |

---

## 6. Database Changes

### Migration 1: Add media_session_id to calls (Phase 1)

```ruby
class AddMediaSessionIdToCalls < ActiveRecord::Migration[7.0]
  def change
    add_column :calls, :media_session_id, :string
    add_index :calls, :media_session_id
  end
end
```

**Backward compatibility:** The column is nullable with no default. Existing calls (from the browser-direct path) will have `media_session_id = nil`. The feature flag `whatsapp_call_server_media` determines which path is used.

### Migration 2: Create call_participants (Phase 5)

```ruby
class CreateCallParticipants < ActiveRecord::Migration[7.0]
  def change
    create_table :call_participants do |t|
      t.bigint :call_id, null: false
      t.bigint :user_id, null: false
      t.string :role, null: false, default: 'active'
      t.string :peer_id
      t.datetime :joined_at
      t.datetime :left_at
      t.timestamps
    end

    add_index :call_participants, [:call_id, :user_id], unique: true
    add_index :call_participants, :call_id
    add_foreign_key :call_participants, :calls
    add_foreign_key :call_participants, :users
  end
end
```

### Model Changes Summary

| Model | Phase | Change |
|-------|-------|--------|
| `Call` | 1 | Add `media_session_id` attribute, `media_session_active?` method |
| `Call` | 5 | Add `has_many :call_participants` and `has_many :participants` |
| `CallParticipant` | 5 | New model with `belongs_to :call`, `belongs_to :user` |

### Index Summary

| Table | Index | Phase | Purpose |
|-------|-------|-------|---------|
| `calls` | `media_session_id` | 1 | Lookup call by media server session |
| `call_participants` | `[call_id, user_id]` (unique) | 5 | Prevent duplicate join |
| `call_participants` | `call_id` | 5 | List participants for a call |

---

## 7. Configuration & Environment Variables

### Required (Phase 1)

| Variable | Example | Description |
|----------|---------|-------------|
| `MEDIA_SERVER_URL` | `http://media:4000` | Internal URL where Rails reaches the Go media server |
| `MEDIA_SERVER_AUTH_TOKEN` | `ms_secret_token_abc123` | Shared secret for mutual authentication |
| `MEDIA_SERVER_PUBLIC_IP` | `203.0.113.50` | Public IP for ICE candidates in SDP offers to agents |

### Required (Go Media Server)

| Variable | Example | Description |
|----------|---------|-------------|
| `AUTH_TOKEN` | `ms_secret_token_abc123` | Must match `MEDIA_SERVER_AUTH_TOKEN` in Rails |
| `RAILS_CALLBACK_URL` | `http://web:3000` | Internal URL for callbacks to Rails |
| `RECORDINGS_DIR` | `/recordings` | Directory for recording files (Docker volume) |
| `UDP_PORT_MIN` | `10000` | Lowest UDP port for WebRTC media |
| `UDP_PORT_MAX` | `10100` | Highest UDP port for WebRTC media |
| `PUBLIC_IP` | `203.0.113.50` | Public IP for ICE candidate generation |
| `LOG_LEVEL` | `info` | Logging verbosity: debug, info, warn, error |

### Optional

| Variable | Default | Description |
|----------|---------|-------------|
| `MEDIA_SERVER_STUN_SERVERS` | `stun:stun.l.google.com:19302` | Comma-separated STUN server URLs |
| `MEDIA_SERVER_TURN_SERVERS` | (none) | Comma-separated TURN server URLs |
| `MEDIA_SERVER_TURN_USERNAME` | (none) | TURN server authentication username |
| `MEDIA_SERVER_TURN_PASSWORD` | (none) | TURN server authentication password |
| `RECONNECT_TIMEOUT_SECONDS` | `30` | How long to hold Peer A after Peer B disconnects |
| `MAX_SESSION_DURATION_SECONDS` | `7200` | Maximum call duration before forced termination |
| `MAX_SESSIONS_PER_ACCOUNT` | `10` | Concurrent call limit per account |
| `HOLD_MUSIC_PATH` | `/audio/default_hold_music.ogg` | Path to default hold music file |

### Self-Hosted Deployment Note

Self-hosted users must ensure:

1. **UDP ports are exposed.** The media server needs direct UDP access from the internet for both Meta's media servers (Peer A) and agent browsers (Peer B). Cloud load balancers that only support TCP will not work for the media path.
2. **Public IP is configured.** The `MEDIA_SERVER_PUBLIC_IP` / `PUBLIC_IP` must be the IP address reachable from the internet. Without this, ICE candidates in SDP will contain private IPs and connections will fail.
3. **TURN server is deployed** if UDP is blocked. A TURN relay (e.g., coturn) handles this scenario by relaying media over TCP/TLS. TURN adds latency but guarantees connectivity.

---

## 8. Risk Register

### R1: Go Media Server as Single Point of Failure

**Severity:** High | **Likelihood:** Medium | **Phase:** All

**Description:** If the Go media server process crashes, all active calls drop immediately. Both Peer A (Meta) and Peer B (agent) connections are lost. There is no automatic recovery of in-progress calls.

**Mitigation:**
- Health checks with automatic container restart (Docker `restart: unless-stopped`)
- Recording files on disk survive crashes (written in real-time, not buffered)
- Rails detects media server failure via health check timeout and terminates orphaned calls
- Startup recovery routine scans for orphaned recordings and reports them to Rails
- Phase 2+ consideration: run multiple media server instances with session affinity

**Residual risk:** Calls in progress at crash time are lost. Acceptable for initial deployment given low concurrent call volumes.

### R2: Meta SDP Compatibility with Pion

**Severity:** High | **Likelihood:** Low-Medium | **Phase:** 2

**Description:** Meta's WebRTC implementation may produce SDP offers/answers with non-standard extensions or codec configurations that Pion cannot parse or negotiate. The current browser-based approach works because Chrome's WebRTC stack is highly tolerant of SDP variations.

**Mitigation:**
- Capture real Meta SDP offers/answers from the existing system for testing
- Pion supports standard SDP; most compatibility issues are in video (not audio)
- Build SDP logging and comparison tooling in the media server
- Fallback: if Pion cannot negotiate, the feature flag allows instant rollback to browser-direct

**Detection:** Integration test with captured real-world SDP from Meta.

### R3: UDP Port Exposure for Self-Hosted Deployments

**Severity:** Medium | **Likelihood:** High | **Phase:** 1

**Description:** Many self-hosted Chatwoot deployments run behind cloud load balancers or reverse proxies that only support TCP. WebRTC requires UDP for media transport. Without UDP access, calls will fail to establish audio.

**Mitigation:**
- TURN server support as fallback (relay media over TCP/TLS)
- Clear documentation on network requirements
- `MEDIA_SERVER_PUBLIC_IP` configuration for NAT environments
- Health check in Rails UI: test media server reachability from agent browser

**Residual risk:** Self-hosted users in highly restrictive networks may need to deploy a TURN server, adding operational complexity.

### R4: No Test Coverage on Existing Call Code

**Severity:** Medium | **Likelihood:** High | **Phase:** All

**Description:** The existing WhatsApp calling code on `feat/whatsapp-call` has no automated test coverage. The PR breakdown document lists testing strategies per PR, but no specs have been written. Modifying untested code increases regression risk.

**Mitigation:**
- Write integration specs for `IncomingCallService` and `CallService` before modifying them
- Use WebMock to stub Meta API calls and media server HTTP calls
- Add request specs for controller endpoints
- Frontend: add unit tests for the Pinia store actions
- Manual testing checklist for each phase (see Section 9)

### R5: Recording Format Change Breaks Transcription

**Severity:** Medium | **Likelihood:** Low | **Phase:** 3

**Description:** The current recording format is `audio/webm;codecs=opus`. The new format is `audio/ogg;codecs=opus`. OpenAI's Whisper API accepts both formats, but the file extension and content type change may affect downstream processing.

**Mitigation:**
- Verify OpenAI Whisper accepts OGG/Opus files (documentation confirms this)
- Test with a sample OGG recording before deploying
- The `CallTranscriptionService` sends the file to OpenAI as a binary upload -- the content type header is what matters, not the extension

### R6: Increased Latency in Audio Path

**Severity:** Low | **Likelihood:** Low | **Phase:** 2

**Description:** Audio now passes through an extra hop (media server). This adds 1-5ms of latency within the same datacenter. The human perception threshold for voice latency is approximately 40ms (one-way) before conversation becomes awkward.

**Mitigation:**
- Deploy media server on the same host/network as the Rails application
- Monitor actual latency via WebRTC stats API in the browser
- Pion's RTP forwarding is zero-copy within the process (no transcoding)

**Residual risk:** Cross-region deployments (Rails in US, media server in EU) would add significant latency. Documentation should recommend co-location.

### R7: Feature Flag Complexity During Migration

**Severity:** Low | **Likelihood:** Medium | **Phase:** 2-4

**Description:** Two feature flags will coexist: `whatsapp_call` (enables calling) and `whatsapp_call_server_media` (routes through media server). Both Rails services and frontend composables must check the flag and maintain two code paths during the transition.

**Mitigation:**
- Clear naming convention: all new-path code checks `whatsapp_call_server_media`
- Both paths share the same controller actions (the flag determines internal routing)
- Plan a cleanup phase (Phase 5 of the original PR breakdown becomes the cleanup phase after rollout)
- Time-box the migration: legacy path removed within 4 weeks of full rollout

### R8: Go Language Expertise

**Severity:** Low | **Likelihood:** Medium | **Phase:** 1-2

**Description:** The Chatwoot team primarily works in Ruby and JavaScript. The Go media server introduces a new language to the stack. Debugging, code review, and on-call support require Go knowledge.

**Mitigation:**
- The media server is small (~2000 lines of Go) and narrowly scoped
- Pion has extensive documentation and examples
- Structured logging makes troubleshooting possible without deep Go knowledge
- The media server is stateless (no database, no persistent state) -- restart fixes most issues

---

## 9. Testing Strategy

### Unit Tests

#### Go Media Server

| Component | Test Approach | Phase |
|-----------|--------------|-------|
| Session manager | Create/find/destroy sessions, verify thread safety | 2 |
| SDP handling | Feed real Meta SDP offers, verify valid answers generated | 2 |
| Audio bridge | Mock two peers, verify packets forwarded bidirectionally | 2 |
| OGG recorder | Feed Opus frames, verify valid OGG file produced | 3 |
| Reconnection | Simulate Peer B disconnect/reconnect, verify Peer A stays up | 4 |
| Audio decoder | Decode sample MP3/OGG files, verify PCM output | 6 |

Use Pion's `webrtc.NewAPI()` with `SettingEngine` for deterministic testing without real network.

#### Rails

| Component | Test Approach | Phase |
|-----------|--------------|-------|
| `MediaServerClient` | WebMock stubs for all media server endpoints | 1 |
| `IncomingCallService` (new path) | Stub `MediaServerClient`, verify session created and SDP stored | 2 |
| `CallService` (new path) | Stub `MediaServerClient`, verify accept flow without browser SDP | 2 |
| `CallReconnectService` | Stub `MediaServerClient.agent_reconnect`, verify ActionCable broadcast | 4 |
| `CallRecordingFetchJob` | Stub `MediaServerClient.download_recording`, verify ActiveStorage attachment | 3 |
| Callbacks controller | Verify correct handling of `agent_disconnected`, `recording_ready` events | 2 |

#### Frontend

| Component | Test Approach | Phase |
|-----------|--------------|-------|
| Pinia store actions | Vitest: verify state transitions for `handleAgentOffer`, `setReconnecting` | 2 |
| API client methods | Vitest: verify correct HTTP calls for new endpoints | 2 |
| `useCallReconnection` | Vitest: mock API calls, verify reconnection flow | 4 |

### Integration Tests

| Scenario | Approach | Phase |
|----------|----------|-------|
| Full inbound call | Rails request spec: simulate webhook -> verify media server called -> verify ActionCable events | 2 |
| Full outbound call | Rails request spec: POST initiate -> verify media server called -> simulate Meta webhook | 2 |
| Recording fetch | Sidekiq spec: trigger job -> verify file downloaded and attached | 3 |
| Reconnection flow | Rails request spec: GET active -> POST reconnect -> verify media server called | 4 |

### Manual Testing Checklist

#### Phase 2: Core Call Flow

- [ ] **Inbound call happy path:** WhatsApp contact calls business number -> incoming call widget appears -> agent accepts -> two-way audio works -> agent hangs up -> call record updated
- [ ] **Outbound call happy path:** Agent clicks phone icon -> contact's phone rings -> contact answers -> two-way audio works -> either side hangs up
- [ ] **Multi-agent routing:** Two agents online -> both see incoming call -> first to accept wins -> other agent's widget dismisses
- [ ] **Call rejection:** Agent rejects incoming call -> call marked as failed -> Meta notified
- [ ] **Feature flag isolation:** Disable `whatsapp_call_server_media` -> calls use browser-direct path -> enable flag -> calls use media server path

#### Phase 3: Recording

- [ ] **Recording captured:** Complete a call -> recording appears in message bubble within 60s
- [ ] **Recording quality:** Play the recording -> both sides are audible -> stereo separation works
- [ ] **Transcription:** Recording triggers transcription job -> transcript appears in message bubble
- [ ] **Browser crash:** Agent force-quits browser during call -> call continues via media server -> recording includes audio up to the point of browser crash

#### Phase 4: Reconnection

- [ ] **Page refresh:** Agent refreshes page during call -> dashboard shows "Reconnecting..." -> audio resumes within 3s -> call timer continues from correct duration
- [ ] **Browser close and reopen:** Agent closes browser -> reopens Chatwoot within 30s -> active call detected -> reconnection succeeds
- [ ] **Reconnect timeout:** Agent disconnects and does NOT reconnect within 30s -> call terminates -> customer hears disconnect tone -> Meta receives hangup
- [ ] **Multiple refreshes:** Agent refreshes 5 times rapidly -> each reconnection succeeds -> single continuous recording

#### Phase 5: Multi-Participant

- [ ] **Supervisor listen:** Supervisor clicks "Join as listener" on active call -> hears both sides -> agent and customer are unaware
- [ ] **Participant list:** Join UI shows connected participants and their roles in real time

#### Phase 6: Audio Injection

- [ ] **Hold music:** Agent disconnects (page close) -> customer hears hold music within 2s -> agent reconnects -> hold music stops -> normal audio resumes
- [ ] **On-demand playback:** Agent triggers "Play message" -> customer hears the audio file -> agent audio resumes after file completes

---

## 10. Rollout Plan

### Feature Flag Strategy

Two flags control the rollout:

| Flag | Purpose | Default |
|------|---------|---------|
| `whatsapp_call` | Enables WhatsApp calling (existing) | Off |
| `whatsapp_call_server_media` | Routes calls through media server instead of browser-direct | Off |

Both flags must be enabled for the new architecture to be used. If `whatsapp_call_server_media` is disabled, the system falls back to the browser-direct path (current behavior).

### Rollout Phases

**Stage 1: Internal testing (1 week)**
- Enable both flags on the Chatwoot team's internal account
- Conduct all manual testing checklist items
- Monitor media server health, latency, and recording quality

**Stage 2: Beta accounts (1-2 weeks)**
- Enable `whatsapp_call_server_media` on 5-10 volunteer customer accounts
- Monitor for regressions: call success rate, recording completeness, reconnection reliability
- Gather feedback on audio quality and latency

**Stage 3: General availability (1 week)**
- Enable `whatsapp_call_server_media` for all accounts with `whatsapp_call` enabled
- Monitor dashboards for 1 week

**Stage 4: Legacy cleanup (1 week)**
- Remove browser-direct WebRTC code path
- Remove `upload_recording` endpoint
- Remove `MediaRecorder` and `startCallRecording` from frontend
- Remove `whatsapp_call_server_media` feature flag (server-media becomes the only path)
- Remove `terminateCallOnUnload` function
- Remove `fix_sdp_setup` method (the `actpass -> active` hack)

### Rollback Procedure

If issues are discovered after enabling `whatsapp_call_server_media`:

1. Disable the `whatsapp_call_server_media` feature flag on affected accounts (instant, no deploy needed)
2. All new calls will use the browser-direct path
3. Active calls through the media server will continue until they end naturally
4. No data migration needed -- the `media_session_id` column is additive

### Monitoring

Key metrics to track during rollout:

| Metric | Source | Alert Threshold |
|--------|--------|----------------|
| Media server health | `/health` endpoint | 3 consecutive failures |
| Call setup success rate | Rails logs (CallService errors) | Below 95% |
| Average call setup time | Rails logs (webhook to audio bridged) | Above 5 seconds |
| Recording fetch success rate | `CallRecordingFetchJob` success/failure | Below 98% |
| Reconnection success rate | `CallReconnectService` success/failure | Below 90% |
| Media server memory usage | Docker stats / Prometheus | Above 80% of limit |
| Active session count | `/health` endpoint | Above 80% of capacity |
| UDP port utilization | Media server metrics | Above 80% of range |

---

## Appendix A: Timeline Summary

| Phase | Duration | Key Deliverable | Dependencies |
|-------|----------|----------------|--------------|
| 1: Foundation | 1 week | DB migration, MediaServerClient, Go scaffold with health endpoint | None |
| 2: Core Call Flow | 2-3 weeks | End-to-end inbound + outbound calls through media server | Phase 1 |
| 3: Recording | 1 week | Server-side recording, remove browser recording | Phase 2 |
| 4: Reconnection | 1-2 weeks | Call persistence across page reload, automatic reconnect | Phase 2 |
| 5: Multi-Participant | 2 weeks | Supervisor listen, participant management | Phase 2 |
| 6: Audio Injection | 1-2 weeks | Hold music, on-demand audio playback | Phase 4 |
| 7: AI Foundation | 1-2 weeks | Plugin interface, RTP tap, virtual peer | Phase 2 |
| **Total** | **9-13 weeks** | **Full migration with all 6 requirements met** | |

Phases 3, 4, 5, 6, and 7 can be parallelized after Phase 2 is complete. The critical path is: Phase 1 -> Phase 2 -> Phase 4 (reconnection is the primary motivation for the migration).

**Minimum viable migration (R1 + R2 + R3):** Phases 1 + 2 + 3 + 4 = 5-7 weeks.

---

## Appendix B: File Inventory

Complete list of files created or modified, grouped by component.

### New Files

| File | Phase | Component |
|------|-------|-----------|
| `db/migrate/YYYYMMDDHHMMSS_add_media_session_id_to_calls.rb` | 1 | Rails |
| `enterprise/app/services/whatsapp/media_server_client.rb` | 1 | Rails |
| `enterprise/app/services/whatsapp/call_reconnect_service.rb` | 4 | Rails |
| `enterprise/app/services/whatsapp/call_participant_service.rb` | 5 | Rails |
| `enterprise/app/services/whatsapp/call_ai_streaming_service.rb` | 7 | Rails |
| `enterprise/app/jobs/whatsapp/call_recording_fetch_job.rb` | 3 | Rails |
| `enterprise/app/controllers/api/internal/media_server/callbacks_controller.rb` | 2 | Rails |
| `enterprise/app/models/call_participant.rb` | 5 | Rails |
| `db/migrate/YYYYMMDDHHMMSS_create_call_participants.rb` | 5 | Rails |
| `app/javascript/dashboard/composables/useCallReconnection.js` | 4 | Frontend |
| `app/javascript/dashboard/components/widgets/WhatsappCallParticipants.vue` | 5 | Frontend |
| `enterprise/media-server/main.go` | 1 | Go |
| `enterprise/media-server/go.mod` | 1 | Go |
| `enterprise/media-server/config/config.go` | 1 | Go |
| `enterprise/media-server/api/handler.go` | 1 | Go |
| `enterprise/media-server/api/middleware.go` | 1 | Go |
| `enterprise/media-server/api/session_handler.go` | 2 | Go |
| `enterprise/media-server/api/meta_sdp_handler.go` | 2 | Go |
| `enterprise/media-server/api/agent_handler.go` | 2 | Go |
| `enterprise/media-server/api/recording_handler.go` | 2 | Go |
| `enterprise/media-server/api/audio_handler.go` | 6 | Go |
| `enterprise/media-server/session/manager.go` | 2 | Go |
| `enterprise/media-server/session/session.go` | 2 | Go |
| `enterprise/media-server/session/peer.go` | 2 | Go |
| `enterprise/media-server/session/bridge.go` | 2 | Go |
| `enterprise/media-server/session/mixer.go` | 5 | Go |
| `enterprise/media-server/session/virtual_peer.go` | 7 | Go |
| `enterprise/media-server/recording/recorder.go` | 3 | Go |
| `enterprise/media-server/recording/ogg_writer.go` | 3 | Go |
| `enterprise/media-server/recording/cleanup.go` | 3 | Go |
| `enterprise/media-server/callback/rails_client.go` | 2 | Go |
| `enterprise/media-server/audio/decoder.go` | 6 | Go |
| `enterprise/media-server/audio/encoder.go` | 6 | Go |
| `enterprise/media-server/audio/injector.go` | 6 | Go |
| `enterprise/media-server/plugin/consumer.go` | 7 | Go |
| `enterprise/media-server/plugin/rtp_tap.go` | 7 | Go |
| `enterprise/media-server/Dockerfile` | 1 | Go |

### Modified Files

| File | Phase | Change Summary |
|------|-------|---------------|
| `enterprise/app/models/call.rb` | 1, 5 | Add `media_session_id`, participant association |
| `enterprise/app/services/whatsapp/incoming_call_service.rb` | 2 | Create media session instead of storing SDP for browser |
| `enterprise/app/services/whatsapp/call_service.rb` | 2 | Accept without browser SDP, orchestrate Peer B setup |
| `enterprise/app/controllers/api/v1/accounts/whatsapp_calls_controller.rb` | 2, 3, 4, 5, 6 | New actions, remove upload_recording |
| `config/routes.rb` | 2, 4, 5 | New routes for agent_answer, reconnect, active, join, leave, callbacks |
| `app/javascript/dashboard/composables/useWhatsappCallSession.js` | 2, 3, 4 | Remove recording, remove terminateCallOnUnload, add reconnection |
| `app/javascript/dashboard/stores/whatsappCalls.js` | 2, 4 | Add reconnection state, handle agent_offer |
| `app/javascript/dashboard/api/whatsappCalls.js` | 2, 3 | New methods, remove uploadRecording |
| `app/javascript/dashboard/helper/actionCable.js` | 2, 4, 5 | New event handlers |
| `app/javascript/dashboard/components/widgets/WhatsappCallWidget.vue` | 4 | Reconnection UI |
| `app/javascript/dashboard/components/widgets/conversation/ConversationHeader.vue` | 2 | Remove browser SDP generation for outbound |
| `docker-compose.yml` or `docker-compose.deploy.yaml` | 1 | Add media-server service |
| `Procfile.dev` | 1 | Add media-server process |
