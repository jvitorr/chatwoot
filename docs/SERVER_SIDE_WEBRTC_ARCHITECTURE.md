# Server-Side WebRTC Architecture for WhatsApp Calling

## Executive Summary

This document designs a migration from browser-based WebRTC to server-side WebRTC for
Chatwoot's WhatsApp Calling feature. The new architecture places a **Pion-based Go
sidecar** (called `chatwoot-media-server`) between Meta's media servers and the agent's
browser. This gives us call persistence across page reloads, server-side recording,
and centralized call lifecycle management -- all without modifying the existing Rails
application server in a language-incompatible way.

---

## Table of Contents

1. [Technology Recommendation](#1-technology-recommendation)
2. [System Architecture](#2-system-architecture)
3. [Component Interaction Flows](#3-component-interaction-flows)
4. [Inbound Call Flow](#4-inbound-call-flow)
5. [Outbound Call Flow](#5-outbound-call-flow)
6. [Recording Pipeline](#6-recording-pipeline)
7. [Frontend-to-Backend Audio Relay](#7-frontend-to-backend-audio-relay)
8. [Call Lifecycle and Reconnection](#8-call-lifecycle-and-reconnection)
9. [Database Schema Changes](#9-database-schema-changes)
10. [File Structure](#10-file-structure)
11. [Deployment Architecture](#11-deployment-architecture)
12. [Scalability Analysis](#12-scalability-analysis)
13. [Security Considerations](#13-security-considerations)
14. [Pros, Cons, and Trade-offs](#14-pros-cons-and-trade-offs)
15. [Migration Path](#15-migration-path)

---

## 1. Technology Recommendation

### Evaluation Matrix

| Criterion                    | Janus (C)  | mediasoup (Node) | Pion (Go)      | GStreamer+WebRTC (C) |
|------------------------------|------------|-------------------|----------------|----------------------|
| WebRTC standard compliance   | Full       | Full (SFU only)   | Full           | Full                 |
| Can act as WebRTC endpoint   | Yes        | No (SFU, not endpoint) | Yes        | Yes                  |
| SDP offer/answer handling    | Plugin API | JS API            | Native Go API  | GStreamer pipeline   |
| Audio mixing/recording       | Plugins    | External           | Manual + Opus  | Native pipelines     |
| Operational complexity       | High (C, plugins, Lua) | Medium  | Low            | High (pipelines)     |
| Docker image size            | ~200 MB    | ~150 MB           | ~15-30 MB      | ~300 MB              |
| Concurrent call capacity     | High       | High              | Very high      | High                 |
| Memory per call              | ~5 MB      | ~3 MB             | ~1-2 MB        | ~8 MB                |
| Language interop with Rails  | HTTP/WS    | HTTP/WS           | HTTP/gRPC      | CLI/HTTP             |
| Community / maintenance      | Active     | Active            | Very active    | Active               |
| Learning curve for team      | Steep      | Moderate          | Moderate       | Steep                |

### Recommendation: Pion (Go sidecar)

**Pion** is the best fit for this use case. Here is the rationale:

1. **Full WebRTC endpoint capability.** Pion can hold an `RTCPeerConnection` on the
   server side -- it is not just an SFU. It can receive Meta's SDP offer, generate an
   SDP answer, and establish a direct SRTP audio session with Meta's media servers.
   mediasoup cannot do this; it is an SFU that only forwards packets between peers.

2. **Lightweight.** A statically-compiled Go binary produces a Docker image under 30 MB.
   No plugin system, no Lua, no native dependency chain. This matters for Chatwoot's
   self-hosted deployment model.

3. **Audio recording is straightforward.** Pion gives access to raw RTP packets and
   decoded Opus frames. Writing them to an OGG/Opus container (or decoding to PCM for
   WAV) is well-documented in Pion's examples. No GStreamer pipeline needed.

4. **Excellent concurrency.** Go's goroutine model handles thousands of concurrent
   connections with minimal memory overhead. Each active call consumes approximately
   1-2 MB of memory (RTP buffers + SRTP context).

5. **Clean integration surface.** The Go sidecar exposes a simple HTTP/gRPC API that
   Rails calls. No shared memory, no FFI, no process spawning.

6. **Active ecosystem.** Pion has 13k+ GitHub stars, weekly releases, and an active
   Discord. The `pion/webrtc`, `pion/rtp`, `pion/opus`, and `pion/interceptor`
   packages cover all requirements.

### Why not the others

- **Janus**: Overkill. Requires maintaining C plugins, Lua scripting, and a complex
  configuration. Designed for multi-party video conferencing, not 1:1 audio relay.
- **mediasoup**: Cannot act as a WebRTC endpoint. It is an SFU that forwards media
  between browser peers. Meta expects to negotiate with a single WebRTC peer, not a
  forwarding unit.
- **GStreamer**: Powerful but heavy. Pipeline-based architecture is great for complex
  media processing, but adds significant operational complexity for what is
  fundamentally a simple audio relay + recording task.

---

## 2. System Architecture

### High-Level Diagram

```
                                                    CHATWOOT SERVER
                                    ┌─────────────────────────────────────────────────────┐
                                    │                                                     │
 ┌──────────────┐                   │  ┌────────────────┐       ┌──────────────────────┐  │
 │   WhatsApp   │  Webhook          │  │                │ HTTP  │                      │  │
 │   Contact    │  (signaling)      │  │   Rails App    │◄─────►│  chatwoot-media-     │  │
 │              │─────────────────────►│   (Puma/       │       │  server (Pion Go)    │  │
 └──────┬───────┘                   │  │    Sidekiq)    │       │                      │  │
        │                           │  │                │       │  Holds WebRTC peers: │  │
        │                           │  └───────┬────────┘       │  - Meta-side peer    │  │
        │                           │          │                │  - Agent-side peer   │  │
        │                           │          │ ActionCable    │  - Recording engine  │  │
        │                           │          │ (WebSocket)    │                      │  │
        │   ┌────────────────────┐  │          │                └──────────┬───────────┘  │
        │   │   Meta Media       │  │          │                          │               │
        │   │   Servers          │  │          │                  SRTP    │ SRTP          │
        │   │                    │  │          │             (Meta side)  │ (Agent side)  │
        └──►│  Routes audio      │◄═══════════╪══════════════════════════╡               │
            │  between endpoints │  │          │                         │               │
            └────────────────────┘  │  ┌───────▼────────┐               │               │
                                    │  │   Agent's      │◄══════════════╡               │
                                    │  │   Browser      │  WebRTC audio │               │
                                    │  │   (Vue.js)     │  (SRTP)       │               │
                                    │  │                │               │               │
                                    │  └────────────────┘               │               │
                                    │                                   │               │
                                    │                     ┌─────────────▼───────────┐   │
                                    │                     │   Recording Pipeline     │   │
                                    │                     │                         │   │
                                    │                     │   OGG/Opus file         │   │
                                    │                     │   → ActiveStorage       │   │
                                    │                     └─────────────────────────┘   │
                                    └─────────────────────────────────────────────────────┘
```

### Two-Peer Bridge Architecture

The media server maintains **two independent WebRTC peer connections per call** and
bridges audio between them:

```
  Meta Media Servers                chatwoot-media-server              Agent Browser
  ════════════════                  ═══════════════════                 ══════════════
                         SRTP                                  SRTP
  ┌──────────────┐  ◄═══════════►  ┌──────────────┐  ◄═══════════►  ┌──────────────┐
  │              │                  │              │                  │              │
  │  Meta's      │    Peer A        │  Pion Go     │    Peer B        │  Browser     │
  │  WebRTC      │    (Meta-side    │  process     │    (Agent-side   │  WebRTC      │
  │  endpoint    │     connection)  │              │     connection)  │  RTCPeerConn │
  │              │                  │              │                  │              │
  └──────────────┘                  │  ┌────────┐  │                  └──────────────┘
                                    │  │ Audio   │  │
                                    │  │ Bridge  │  │
                                    │  │         │  │
                                    │  │ A→B     │  │
                                    │  │ B→A     │  │
                                    │  │         │  │
                                    │  │ +Record │  │
                                    │  └────────┘  │
                                    └──────────────┘
```

**Why two peers instead of one:**

Meta's WebRTC endpoint negotiates a standard peer connection. The agent's browser also
needs a standard peer connection. The media server sits in the middle as a "back-to-back
user agent" (B2BUA), forwarding RTP packets between the two peers while also tapping
into the streams for recording.

This is a well-established pattern in VoIP (analogous to a SIP B2BUA). Each peer
connection is independent: Meta does not know about the agent, the agent does not know
about Meta. The media server handles codec negotiation, SRTP encryption/decryption, and
RTP forwarding for both sides.

---

## 3. Component Interaction Flows

### Component Responsibilities

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                                                                                     │
│  RAILS APP (existing, modified)                                                    │
│  ─────────────────────────────                                                     │
│  - Receives Meta webhooks (call connect/terminate events)                          │
│  - Manages Call model lifecycle (DB records, status transitions)                   │
│  - Delegates SDP handling to media server via internal HTTP API                    │
│  - Broadcasts ActionCable events to agent browsers                                 │
│  - Stores recordings in ActiveStorage after media server delivers them             │
│  - Runs transcription jobs (unchanged)                                             │
│                                                                                     │
│  CHATWOOT-MEDIA-SERVER (new, Go/Pion)                                              │
│  ────────────────────────────────────                                               │
│  - Holds Meta-side WebRTC peer connection (Peer A)                                 │
│  - Holds Agent-side WebRTC peer connection (Peer B)                                │
│  - Bridges audio packets between Peer A and Peer B                                 │
│  - Records both audio streams to disk (OGG/Opus)                                  │
│  - Manages ICE/STUN/TURN for both peers                                            │
│  - Exposes HTTP API for Rails to control call sessions                             │
│  - Reports call events back to Rails via HTTP callbacks                            │
│                                                                                     │
│  AGENT BROWSER (modified)                                                          │
│  ────────────────────────                                                          │
│  - Establishes WebRTC peer connection to media server (NOT to Meta directly)       │
│  - Sends/receives audio via standard WebRTC (getUserMedia + RTCPeerConnection)     │
│  - No longer handles recording (server does it)                                    │
│  - Can reconnect to an active call after page reload                               │
│  - Receives SDP offer from media server via ActionCable, responds with answer      │
│                                                                                     │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### Media Server Internal HTTP API

The Go sidecar exposes the following HTTP endpoints, accessible only from the Rails
process (bound to localhost or internal network):

```
POST   /sessions                    Create a new call session
POST   /sessions/:id/meta-sdp      Set Meta's SDP offer and get server's SDP answer
POST   /sessions/:id/agent-offer   Get SDP offer for agent-side peer
POST   /sessions/:id/agent-answer  Set agent's SDP answer for agent-side peer
POST   /sessions/:id/terminate     Tear down both peers and finalize recording
GET    /sessions/:id/status        Get session status (peers connected, ICE state)
GET    /sessions/:id/recording     Download the finalized recording file
DELETE /sessions/:id               Force-destroy a session

POST   /sessions/:id/agent-reconnect  Generate new agent-side offer for reconnection
```

Authentication between Rails and the media server uses a shared secret token passed as
a Bearer header, configured via environment variable `MEDIA_SERVER_AUTH_TOKEN`.

---

## 4. Inbound Call Flow

```
  WhatsApp              Meta                 Chatwoot            Media              Agent
  Contact              Cloud                 Backend             Server             Browser
    │                    │                     │                    │                   │
 1. │── Dials ──────────►│                     │                    │                   │
    │  business #        │                     │                    │                   │
    │                    │                     │                    │                   │
 2. │                    │── Webhook ──────────►│                    │                   │
    │                    │  event: connect      │                    │                   │
    │                    │  {id, from,          │                    │                   │
    │                    │   sdp_offer}         │                    │                   │
    │                    │                     │                    │                   │
 3. │                    │               ┌─────┴──────┐             │                   │
    │                    │               │ Incoming    │             │                   │
    │                    │               │ CallService │             │                   │
    │                    │               │             │             │                   │
    │                    │               │ a. Contact  │             │                   │
    │                    │               │ b. Convo    │             │                   │
    │                    │               │ c. Call rec │             │                   │
    │                    │               └─────┬──────┘             │                   │
    │                    │                     │                    │                   │
 4. │                    │                     │── POST /sessions ─►│                   │
    │                    │                     │   {call_id,        │                   │
    │                    │                     │    meta_sdp_offer} │                   │
    │                    │                     │                    │                   │
 5. │                    │                     │              ┌─────┴──────┐            │
    │                    │                     │              │ Create     │            │
    │                    │                     │              │ Peer A     │            │
    │                    │                     │              │ (Meta-side)│            │
    │                    │                     │              │            │            │
    │                    │                     │              │ Set remote │            │
    │                    │                     │              │ desc (SDP  │            │
    │                    │                     │              │ offer)     │            │
    │                    │                     │              │            │            │
    │                    │                     │              │ Create     │            │
    │                    │                     │              │ answer     │            │
    │                    │                     │              │ + ICE      │            │
    │                    │                     │              │ gather     │            │
    │                    │                     │              └─────┬──────┘            │
    │                    │                     │                    │                   │
 6. │                    │                     │◄── {sdp_answer,   │                   │
    │                    │                     │     session_id}    │                   │
    │                    │                     │                    │                   │
 7. │                    │                     │  Store session_id  │                   │
    │                    │                     │  in Call.meta      │                   │
    │                    │                     │                    │                   │
    │                    │                     │  NOTE: Do NOT send │                   │
    │                    │                     │  SDP answer to Meta│                   │
    │                    │                     │  yet. Wait for     │                   │
    │                    │                     │  agent to accept.  │                   │
    │                    │                     │                    │                   │
 8. │                    │                     │── ActionCable ─────────────────────────►│
    │                    │                     │  whatsapp_call.incoming                 │
    │                    │                     │  {id, call_id, caller, conversation_id} │
    │                    │                     │  (NO sdp_offer -- agent doesn't need it)│
    │                    │                     │                    │                   │
 9. │                    │                     │                    │            ┌──────┴───┐
    │                    │                     │                    │            │ Widget:  │
    │                    │                     │                    │            │ "Incoming│
    │                    │                     │                    │            │  call"   │
    │                    │                     │                    │            │ [Accept] │
    │                    │                     │                    │            │ [Reject] │
    │                    │                     │                    │            └──────┬───┘
    │                    │                     │                    │                   │
    │                    │                     │                    │    Agent clicks    │
    │                    │                     │                    │    "Accept"        │
    │                    │                     │                    │                   │
10. │                    │                     │◄── POST /accept ──────────────────────│
    │                    │                     │   {call_id}        │                   │
    │                    │                     │   (NO sdp_answer   │                   │
    │                    │                     │    from browser!)   │                   │
    │                    │                     │                    │                   │
11. │                    │               ┌─────┴──────┐             │                   │
    │                    │               │ CallService│             │                   │
    │                    │               │ (row lock) │             │                   │
    │                    │               │            │             │                   │
    │                    │               │ Validate   │             │                   │
    │                    │               │ still ring │             │                   │
    │                    │               └─────┬──────┘             │                   │
    │                    │                     │                    │                   │
12. │                    │◄── pre_accept ──────│                    │                   │
    │                    │    + accept          │                    │                   │
    │                    │    (SDP from media   │                    │                   │
    │                    │     server, stored   │                    │                   │
    │                    │     in Call.meta)    │                    │                   │
    │                    │                     │                    │                   │
13. │◄════════════ Audio (SRTP) ═══════════════════════════════════►│ (Peer A)         │
    │                    │                     │                    │                   │
    │                    │                     │                    │                   │
14. │                    │                     │── POST /sessions/  │                   │
    │                    │                     │   :id/agent-offer ►│                   │
    │                    │                     │                    │                   │
15. │                    │                     │              ┌─────┴──────┐            │
    │                    │                     │              │ Create     │            │
    │                    │                     │              │ Peer B     │            │
    │                    │                     │              │ (agent-    │            │
    │                    │                     │              │  side)     │            │
    │                    │                     │              │            │            │
    │                    │                     │              │ Create     │            │
    │                    │                     │              │ SDP offer  │            │
    │                    │                     │              │ for agent  │            │
    │                    │                     │              └─────┬──────┘            │
    │                    │                     │                    │                   │
16. │                    │                     │◄── {sdp_offer} ───│                   │
    │                    │                     │                    │                   │
17. │                    │                     │── ActionCable ─────────────────────────►│
    │                    │                     │  whatsapp_call.agent_offer              │
    │                    │                     │  {sdp_offer, ice_servers}               │
    │                    │                     │                    │                   │
18. │                    │                     │                    │            ┌──────┴───┐
    │                    │                     │                    │            │getUserMe-│
    │                    │                     │                    │            │dia(audio)│
    │                    │                     │                    │            │          │
    │                    │                     │                    │            │setRemote-│
    │                    │                     │                    │            │Desc(offer│
    │                    │                     │                    │            │from media│
    │                    │                     │                    │            │server)   │
    │                    │                     │                    │            │          │
    │                    │                     │                    │            │createAns-│
    │                    │                     │                    │            │wer + ICE │
    │                    │                     │                    │            └──────┬───┘
    │                    │                     │                    │                   │
19. │                    │                     │◄── POST /agent-answer ────────────────│
    │                    │                     │   {sdp_answer}     │                   │
    │                    │                     │                    │                   │
20. │                    │                     │── POST /sessions/  │                   │
    │                    │                     │   :id/agent-answer►│                   │
    │                    │                     │                    │                   │
21. │                    │                     │              ┌─────┴──────┐            │
    │                    │                     │              │ Set agent  │            │
    │                    │                     │              │ SDP answer │            │
    │                    │                     │              │ on Peer B  │            │
    │                    │                     │              │            │            │
    │                    │                     │              │ Bridge     │            │
    │                    │                     │              │ audio:     │            │
    │                    │                     │              │ A <-> B    │            │
    │                    │                     │              │            │            │
    │                    │                     │              │ Start      │            │
    │                    │                     │              │ recording  │            │
    │                    │                     │              └─────┬──────┘            │
    │                    │                     │                    │                   │
22. │◄══════ Audio (Meta ↔ Media Server) ════►│◄══ Audio (Media Server ↔ Browser) ══►│
    │                    │                     │                    │                   │
    │  Agent hears customer, customer hears agent. Recording captures both.           │
```

### Key Differences from Current Architecture

| Aspect                       | Current (browser WebRTC)              | New (server WebRTC)                    |
|------------------------------|---------------------------------------|----------------------------------------|
| Who answers Meta's SDP       | Agent's browser                       | Media server (Pion)                    |
| Audio path                   | Meta <-> Browser (direct)             | Meta <-> Media Server <-> Browser      |
| Accept API payload           | Browser sends `sdp_answer`            | Browser sends nothing (just call ID)   |
| SDP answer source            | Browser's RTCPeerConnection           | Media server's Pion peer               |
| Agent-side connection        | N/A (direct to Meta)                  | Separate WebRTC peer (Peer B)          |
| Recording                    | Browser MediaRecorder                 | Media server OGG/Opus writer           |
| Survives page reload         | No (active call dies)                 | Yes (Peer A stays up, Peer B reconnects)|
| SDP fix (actpass -> active)  | Backend string replacement            | Media server generates correct SDP     |

---

## 5. Outbound Call Flow

```
  Agent                 Chatwoot              Media               Meta              WhatsApp
  Browser               Backend               Server              Cloud             Contact
    │                     │                     │                    │                   │
 1. │── Click phone icon  │                     │                    │                   │
    │                     │                     │                    │                   │
 2. │── POST /initiate ──►│                     │                    │                   │
    │  {conversation_id}  │                     │                    │                   │
    │  (NO sdp_offer      │                     │                    │                   │
    │   from browser!)    │                     │                    │                   │
    │                     │                     │                    │                   │
 3. │                     │── POST /sessions ──►│                    │                   │
    │                     │  {call_id: temp,    │                    │                   │
    │                     │   direction: out}   │                    │                   │
    │                     │                     │                    │                   │
 4. │                     │              ┌──────┴───────┐            │                   │
    │                     │              │ Create Peer A │            │                   │
    │                     │              │ (Meta-side)   │            │                   │
    │                     │              │               │            │                   │
    │                     │              │ Create SDP    │            │                   │
    │                     │              │ offer for     │            │                   │
    │                     │              │ Meta          │            │                   │
    │                     │              └──────┬───────┘            │                   │
    │                     │                     │                    │                   │
 5. │                     │◄── {sdp_offer,      │                    │                   │
    │                     │     session_id}     │                    │                   │
    │                     │                     │                    │                   │
 6. │                     │── initiate_call ────────────────────────►│                   │
    │                     │  {to, sdp_offer     │                    │── Rings phone ──►│
    │                     │   from media server}│                    │                   │
    │                     │                     │                    │                   │
    │                     │◄── {call_id} ───────────────────────────│                   │
    │                     │                     │                    │                   │
 7. │                     │  Create Call record  │                    │                   │
    │                     │  (outgoing, ringing) │                    │                   │
    │                     │  Store session_id    │                    │                   │
    │                     │                     │                    │                   │
 8. │◄── {status: calling,│                     │                    │                   │
    │     call_id, id}    │                     │                    │                   │
    │                     │                     │                    │                   │
    │  Widget: "Ringing.."│                     │                    │                   │
    │                     │                     │                    │                   │
    │                     │                     │               Contact answers          │
    │                     │                     │                    │◄─────────────────│
    │                     │                     │                    │                   │
 9. │                     │◄── Webhook ─────────────────────────────│                   │
    │                     │  event: connect     │                    │                   │
    │                     │  {call_id,          │                    │                   │
    │                     │   sdp_answer}       │                    │                   │
    │                     │                     │                    │                   │
10. │                     │── POST /sessions/   │                    │                   │
    │                     │   :id/meta-sdp      │                    │                   │
    │                     │   {sdp_answer}     ►│                    │                   │
    │                     │                     │                    │                   │
11. │                     │              ┌──────┴───────┐            │                   │
    │                     │              │ Set Meta's   │            │                   │
    │                     │              │ SDP answer   │            │                   │
    │                     │              │ on Peer A    │            │                   │
    │                     │              └──────┬───────┘            │                   │
    │                     │                     │                    │                   │
12. │◄══════════ Audio (Meta ↔ Media Server, Peer A) ══════════════►│                   │
    │                     │                     │                    │                   │
    │            (Now set up Peer B for agent)  │                    │                   │
    │                     │                     │                    │                   │
13-21.  [Same agent-side SDP exchange as inbound steps 14-22]       │                   │
    │                     │                     │                    │                   │
22. │◄══ Audio (Media Server ↔ Browser, Peer B) ══►│               │                   │
    │                     │                     │                    │                   │
    │  Full duplex audio: Agent <-> Media Server <-> Meta <-> Contact                  │
```

---

## 6. Recording Pipeline

### Architecture

```
            chatwoot-media-server
  ┌──────────────────────────────────────────────────────┐
  │                                                      │
  │   Peer A (Meta)                Peer B (Agent)        │
  │   ┌─────────┐                 ┌─────────┐           │
  │   │ Remote   │                 │ Remote   │           │
  │   │ track    │─────┐     ┌────│ track    │           │
  │   │ (customer│     │     │    │ (agent   │           │
  │   │  audio)  │     │     │    │  audio)  │           │
  │   └─────────┘     │     │    └─────────┘           │
  │                    │     │                           │
  │              ┌─────▼─────▼──────┐                   │
  │              │   Recording Mux   │                   │
  │              │                   │                   │
  │              │  Option A:        │                   │
  │              │  Single mixed     │                   │
  │              │  OGG/Opus file    │                   │
  │              │                   │                   │
  │              │  Option B:        │                   │
  │              │  Two separate     │                   │
  │              │  tracks (stereo:  │                   │
  │              │  L=customer,      │                   │
  │              │  R=agent)         │                   │
  │              │                   │                   │
  │              └────────┬─────────┘                   │
  │                       │                             │
  │                       ▼                             │
  │              ┌─────────────────┐                    │
  │              │ /recordings/    │                    │
  │              │ {session_id}.ogg│                    │
  │              │                 │                    │
  │              │ Written in real │                    │
  │              │ time as packets │                    │
  │              │ arrive          │                    │
  │              └─────────────────┘                    │
  │                                                      │
  └──────────────────────────────────────────────────────┘
                         │
                   On call end
                         │
                         ▼
                ┌─────────────────┐
                │ Rails callback   │
                │                 │
                │ Media server    │
                │ POSTs to Rails: │
                │ /callbacks/     │
                │ recording_ready │
                │ {session_id,    │
                │  file_path}     │
                └────────┬────────┘
                         │
                         ▼
                ┌─────────────────┐
                │ Rails downloads  │
                │ file from media  │
                │ server via       │
                │ GET /sessions/   │
                │ :id/recording    │
                │                 │
                │ Attaches to     │
                │ ActiveStorage   │
                │                 │
                │ Enqueues        │
                │ transcription   │
                │ job             │
                └─────────────────┘
```

### Recording Implementation Details

**Format:** OGG container with Opus codec. This is the native codec for WebRTC audio,
so no transcoding is needed. The Pion interceptor taps RTP packets before
encryption/after decryption and writes Opus frames into OGG pages.

**Real-time writing:** Recording starts when both peers are connected and audio is
bridged. Opus frames are written to disk as they arrive (not buffered in memory). This
means even if the media server crashes, the recording up to that point is preserved on
disk.

**Stereo separation (recommended):** Record customer audio on the left channel and
agent audio on the right channel. This enables:
- Better transcription accuracy (speaker diarization is trivial)
- Post-processing flexibility (adjust volumes, filter noise per channel)
- Compliance with regulations that require separate party recordings

**File lifecycle:**
1. File created when recording starts: `/recordings/{session_id}.ogg`
2. Appended in real time as audio packets arrive
3. Finalized (OGG trailer written) when call ends
4. Rails fetches via HTTP, attaches to ActiveStorage
5. Media server deletes local file after Rails confirms receipt

**Failure mode:** If the media server process crashes mid-recording, the OGG file on
disk is incomplete but still playable (most players handle truncated OGG). A startup
recovery routine scans for orphaned recording files and reports them to Rails.

---

## 7. Frontend-to-Backend Audio Relay

### Mechanism: Standard WebRTC (Peer B)

The agent's browser establishes a normal WebRTC peer connection -- but to the media
server instead of Meta. From the browser's perspective, it looks identical to the
current implementation:

```
  Current:   Browser <--WebRTC--> Meta Media Servers
  New:       Browser <--WebRTC--> chatwoot-media-server <--WebRTC--> Meta Media Servers
```

The browser still uses `getUserMedia`, `RTCPeerConnection`, `ontrack`, etc. The only
difference is the SDP it receives comes from the media server rather than Meta.

### SDP Exchange for Agent-Side Peer (Peer B)

```
  Rails                            Media Server                    Browser
    │                                  │                              │
    │── POST /sessions/:id/            │                              │
    │   agent-offer ──────────────────►│                              │
    │                                  │── Create Peer B              │
    │                                  │── Generate SDP offer         │
    │                                  │── Gather ICE candidates      │
    │◄── {sdp_offer, ice_servers} ─────│                              │
    │                                  │                              │
    │── ActionCable: agent_offer ──────────────────────────────────►│
    │   {sdp_offer, ice_servers}       │                              │
    │                                  │                     ┌────────┴──────┐
    │                                  │                     │getUserMedia   │
    │                                  │                     │setRemoteDesc  │
    │                                  │                     │createAnswer   │
    │                                  │                     │ICE gather     │
    │                                  │                     └────────┬──────┘
    │                                  │                              │
    │◄── POST /whatsapp_calls/:id/agent-answer ──────────────────────│
    │   {sdp_answer}                   │                              │
    │                                  │                              │
    │── POST /sessions/:id/            │                              │
    │   agent-answer ─────────────────►│                              │
    │                                  │── Set remote desc on Peer B  │
    │                                  │── Bridge audio A <-> B       │
    │                                  │── Start recording            │
    │                                  │                              │
    │                                  │◄═══════ SRTP audio ════════►│
```

### Why WebRTC (not WebSocket audio streaming)

Alternatives considered:

| Approach              | Latency    | Complexity | Browser support | Quality        |
|-----------------------|------------|------------|-----------------|----------------|
| **WebRTC (Peer B)**   | ~20-50ms   | Low        | Native          | Opus, adaptive |
| WebSocket + PCM       | ~100-200ms | High       | Manual codec    | Fixed bitrate  |
| WebSocket + Opus      | ~80-150ms  | Medium     | Manual decode   | Good           |
| HTTP chunked          | ~200-500ms | Medium     | Standard        | Variable       |

WebRTC is the clear winner:
- **Latency**: Sub-50ms, critical for real-time voice conversation
- **Codec negotiation**: Opus bitrate adaptation is automatic
- **Echo cancellation**: Built into browser WebRTC stack
- **NAT traversal**: ICE/STUN/TURN handled automatically
- **No custom audio code**: Browser handles decode/playback natively

WebSocket audio would require building a custom audio pipeline in the browser:
decoding Opus, managing jitter buffers, handling echo cancellation, and scheduling
audio playback -- all of which WebRTC already handles.

---

## 8. Call Lifecycle and Reconnection

### Call State Machine (Server-Side)

```
                              ┌─────────────┐
                              │   created    │  Media server session allocated
                              └──────┬──────┘
                                     │
                              Meta SDP exchanged (Peer A ready)
                                     │
                              ┌──────▼──────┐
                              │   ringing    │  Waiting for agent to accept
                              └──┬───┬───┬──┘
                                 │   │   │
                        accepted │   │   │ timeout / reject
                                 │   │   │
                          ┌──────▼┐  │  ┌▼──────────┐
                          │ meta_ │  │  │ no_answer  │
                          │ conn  │  │  │ / failed   │
                          └──┬────┘  │  └────────────┘
                             │       │
                   agent SDP │       │ agent never connected
                   exchanged │       │
                             │       │
                      ┌──────▼──────┐│
                      │ in_progress ││  Both peers connected, audio bridged
                      └──────┬──────┘│
                             │       │
                      ┌──────▼──────┐│
                      │agent_disconn││  Agent page reload / network issue
                      │(Peer B down)││  Peer A still holds Meta audio
                      └──┬───┬──────┘│
                         │   │       │
                reconnect│   │timeout│
                         │   │(30s)  │
                  ┌──────▼┐  │       │
                  │in_prog│  │       │
                  │(reconn│  │       │
                  │ected) │  │       │
                  └──┬────┘  │       │
                     │       │       │
                     ├───────┤       │
                     │       │       │
              ┌──────▼───────▼───────▼──┐
              │      completed          │  Call ended (any reason)
              └─────────────────────────┘
```

### Reconnection After Page Reload

This is the primary motivation for the architecture change. Here is the reconnection
flow:

```
  Agent Browser                  Rails                      Media Server
      │                           │                             │
      │ ═══ Active call ══════════╪═════════════════════════════╡
      │ (Peer B established)      │                             │ Peer A: active
      │                           │                             │ Peer B: active
      │                           │                             │ Audio: bridged
      │                           │                             │ Recording: active
      │                           │                             │
      │── Page refresh ──►        │                             │
      │  (Peer B connection dies) │                             │
      │                           │                             │
      │                           │◄── Callback: agent_disconn ─│ (Peer B ICE fails)
      │                           │                             │
      │                           │  Call status stays          │ Peer A: STILL ACTIVE
      │                           │  "in_progress"              │ Audio from Meta: still
      │                           │  Start 30s reconnect timer  │  flowing (into void)
      │                           │                             │ Recording: paused
      │                           │                             │  (agent track silent)
      │                           │                             │
      │── Page loads              │                             │
      │   Vue mounts              │                             │
      │                           │                             │
      │── GET /whatsapp_calls/    │                             │
      │   active ─────────────────►│                             │
      │                           │                             │
      │◄── {call in progress,     │                             │
      │     call_id, id}          │                             │
      │                           │                             │
      │  Widget auto-shows:       │                             │
      │  "Call in progress -      │                             │
      │   Reconnecting..."        │                             │
      │                           │                             │
      │── POST /whatsapp_calls/   │                             │
      │   :id/reconnect ──────────►│                             │
      │                           │                             │
      │                           │── POST /sessions/:id/       │
      │                           │   agent-reconnect ──────────►│
      │                           │                             │
      │                           │                      ┌──────┴──────┐
      │                           │                      │ Tear down   │
      │                           │                      │ old Peer B  │
      │                           │                      │             │
      │                           │                      │ Create new  │
      │                           │                      │ Peer B      │
      │                           │                      │             │
      │                           │                      │ Generate    │
      │                           │                      │ new SDP     │
      │                           │                      │ offer       │
      │                           │                      └──────┬──────┘
      │                           │                             │
      │                           │◄── {sdp_offer} ────────────│
      │                           │                             │
      │◄── ActionCable: agent_offer│                             │
      │   {sdp_offer, ice_servers}│                             │
      │                           │                             │
      │  getUserMedia (mic)       │                             │
      │  setRemoteDescription     │                             │
      │  createAnswer + ICE       │                             │
      │                           │                             │
      │── POST /agent-answer ─────►│                             │
      │  {sdp_answer}             │                             │
      │                           │── POST /sessions/:id/       │
      │                           │   agent-answer ─────────────►│
      │                           │                             │
      │                           │                      ┌──────┴──────┐
      │                           │                      │ Set answer  │
      │                           │                      │ on new      │
      │                           │                      │ Peer B      │
      │                           │                      │             │
      │                           │                      │ Re-bridge   │
      │                           │                      │ audio       │
      │                           │                      │             │
      │                           │                      │ Resume      │
      │                           │                      │ recording   │
      │                           │                      └──────┴──────┘
      │                           │                             │
      │◄══════════ Audio restored (< 2 seconds gap) ════════════╡
      │                           │                             │
      │  Widget: call timer       │                             │
      │  resumes from server-     │                             │
      │  tracked duration         │                             │
```

### Key Reconnection Details

1. **Reconnect window:** The media server holds Peer A (Meta-side) for 30 seconds
   after Peer B (agent-side) disconnects. If the agent reconnects within that window,
   the call continues seamlessly. If the timeout expires, the media server tells Rails
   to terminate the call with Meta.

2. **Audio gap:** The customer hears silence during the reconnection (typically 1-3
   seconds for a page reload). This is acceptable for a page reload scenario. The
   media server could optionally play a hold tone to the Meta side during disconnection.

3. **Timer continuity:** The call duration timer is tracked server-side
   (`Call.started_at`). The frontend calculates elapsed time from `started_at` rather
   than running a local timer. On reconnection, the widget immediately shows the correct
   elapsed time.

4. **Recording continuity:** The recording file on disk continues to receive the
   customer's audio during the agent disconnect period. The agent's channel is silent
   during the gap. When the agent reconnects, their audio resumes in the recording.

5. **Multiple reconnections:** Each reconnection creates a new Peer B. There is no
   limit on the number of reconnections during a single call.

### Multi-Agent Visibility

The existing pattern is preserved:

- When a call is ringing, all agents in the account see the incoming call widget
- When one agent accepts, ActionCable `whatsapp_call.accepted` dismisses the call from
  all other agents' widgets
- The accepting agent's browser is the only one that establishes Peer B
- If the accepting agent's Peer B disconnects and they do not reconnect within 30s,
  the call could optionally be re-offered to other agents (future enhancement)

### Media Server Restart

If the Go media server process crashes or restarts:

1. All active Peer A and Peer B connections are lost
2. The media server has no persistent state -- all sessions are in-memory
3. On startup, it scans `/recordings/` for orphaned files and reports them to Rails
4. Rails detects the loss via HTTP health check failure or callback timeout
5. Rails terminates all `in_progress` calls associated with the failed media server
6. Recordings up to the crash point are preserved on disk

For high availability, multiple media server instances can run behind a load balancer
with session affinity (sticky sessions by `session_id`). Redis can optionally store
session metadata for cross-instance recovery, but this adds complexity and is not
recommended for the initial implementation.

---

## 9. Database Schema Changes

### Migration: Add media_session_id to calls

```
add_column :calls, :media_session_id, :string
add_index  :calls, :media_session_id
```

The `media_session_id` is the unique identifier for the session on the Go media server.
Rails uses it to make API calls to the media server for a given call.

### Updated Call.meta structure

```json
{
  "media_session_id": "sess_abc123",
  "meta_sdp_offer": "v=0\r\n...",
  "meta_sdp_answer": "v=0\r\n...",
  "agent_sdp_offer": "v=0\r\n...",
  "agent_sdp_answer": "v=0\r\n...",
  "ice_servers": [{"urls": "stun:stun.l.google.com:19302"}],
  "agent_reconnect_count": 0,
  "recording_file": "sess_abc123.ogg"
}
```

### New InstallationConfig keys

| Key                          | Type    | Description                                    |
|------------------------------|---------|------------------------------------------------|
| `MEDIA_SERVER_URL`           | string  | Internal URL of the media server (e.g., `http://media:4000`) |
| `MEDIA_SERVER_AUTH_TOKEN`    | string  | Shared secret for Rails <-> media server auth  |
| `MEDIA_SERVER_STUN_SERVERS`  | string  | Comma-separated STUN server URLs               |
| `MEDIA_SERVER_TURN_SERVERS`  | string  | Comma-separated TURN server URLs               |
| `MEDIA_SERVER_TURN_USERNAME` | string  | TURN server username                           |
| `MEDIA_SERVER_TURN_PASSWORD` | string  | TURN server password                           |

---

## 10. File Structure

### New Go sidecar (separate repository or monorepo subdirectory)

```
enterprise/media-server/
├── Dockerfile
├── go.mod
├── go.sum
├── main.go                          # Entry point, HTTP server setup
├── config/
│   └── config.go                    # Environment variable parsing
├── api/
│   ├── handler.go                   # HTTP route definitions
│   ├── middleware.go                 # Auth token validation
│   ├── session_handler.go           # POST /sessions, GET /sessions/:id
│   ├── meta_sdp_handler.go          # POST /sessions/:id/meta-sdp
│   ├── agent_handler.go             # agent-offer, agent-answer, agent-reconnect
│   └── recording_handler.go         # GET /sessions/:id/recording
├── session/
│   ├── manager.go                   # Session lifecycle (create, find, cleanup)
│   ├── session.go                   # Single call session (two peers + bridge)
│   ├── peer.go                      # WebRTC peer connection wrapper
│   └── bridge.go                    # RTP packet forwarding between peers
├── recording/
│   ├── recorder.go                  # OGG/Opus file writer
│   ├── ogg_writer.go                # Low-level OGG container writing
│   └── cleanup.go                   # Orphaned file detection on startup
├── callback/
│   └── rails_client.go              # HTTP client for callbacks to Rails
└── recordings/                      # Runtime directory for recording files
    └── .gitkeep
```

### Modified Rails files (enterprise)

```
enterprise/
├── app/
│   ├── controllers/api/v1/accounts/
│   │   └── whatsapp_calls_controller.rb     # MODIFIED: new endpoints
│   │       # - accept: no longer receives sdp_answer from browser
│   │       # - new: reconnect action
│   │       # - new: agent_answer action
│   │       # - remove: upload_recording (server handles it)
│   │
│   ├── services/whatsapp/
│   │   ├── call_service.rb                  # MODIFIED: delegates SDP to media server
│   │   ├── incoming_call_service.rb         # MODIFIED: creates media session
│   │   ├── media_server_client.rb           # NEW: HTTP client for media server API
│   │   ├── call_recording_service.rb        # NEW: fetches recording from media server
│   │   └── call_reconnect_service.rb        # NEW: handles agent reconnection
│   │
│   ├── jobs/whatsapp/
│   │   ├── call_recording_fetch_job.rb      # NEW: async fetch recording on call end
│   │   └── call_transcription_job.rb        # UNCHANGED
│   │
│   └── models/
│       └── call.rb                          # MODIFIED: add media_session_id accessor
│
├── config/
│   └── media_server.yml                     # Media server connection config
```

### Modified frontend files

```
app/javascript/dashboard/
├── composables/
│   └── useWhatsappCallSession.js            # HEAVILY MODIFIED
│       # - No longer sends SDP to Meta
│       # - Receives SDP offer from media server via ActionCable
│       # - Sends SDP answer to Rails (which forwards to media server)
│       # - No longer handles recording
│       # - Adds reconnection logic
│       # - beforeunload no longer terminates call (just disconnects Peer B)
│
├── stores/
│   └── whatsappCalls.js                     # MODIFIED
│       # - New state: isReconnecting, reconnectAttempts
│       # - New action: handleAgentOffer (for reconnection)
│       # - Remove: outbound WebRTC state (moved to server)
│
├── api/
│   └── whatsappCalls.js                     # MODIFIED
│       # - accept: no sdp_answer parameter
│       # - new: agentAnswer(callId, sdpAnswer)
│       # - new: reconnect(callId)
│       # - remove: uploadRecording
│       # - new: getActiveCall()
│
├── components/widgets/
│   └── WhatsappCallWidget.vue               # MODIFIED
│       # - Reconnection UI state
│       # - Timer from server-tracked started_at
│
├── helper/
│   └── actionCable.js                       # MODIFIED
│       # - Handle new event: whatsapp_call.agent_offer
│       # - Handle new event: whatsapp_call.agent_disconnected
```

---

## 11. Deployment Architecture

### Docker Compose Addition

```yaml
# Added to docker-compose.yml
services:
  media-server:
    build:
      context: ./enterprise/media-server
      dockerfile: Dockerfile
    ports:
      - "4000:4000"      # Internal HTTP API (Rails communication)
      - "10000-10100:10000-10100/udp"  # RTP/SRTP media ports
    environment:
      - AUTH_TOKEN=${MEDIA_SERVER_AUTH_TOKEN}
      - STUN_SERVERS=stun:stun.l.google.com:19302
      - TURN_SERVERS=${TURN_SERVERS:-}
      - TURN_USERNAME=${TURN_USERNAME:-}
      - TURN_PASSWORD=${TURN_PASSWORD:-}
      - RAILS_CALLBACK_URL=http://web:3000
      - RECORDINGS_DIR=/recordings
      - LOG_LEVEL=info
      - UDP_PORT_MIN=10000
      - UDP_PORT_MAX=10100
    volumes:
      - media-recordings:/recordings
    networks:
      - chatwoot
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "wget", "--spider", "-q", "http://localhost:4000/health"]
      interval: 10s
      timeout: 5s
      retries: 3

volumes:
  media-recordings:
```

### Procfile Addition

```
media: ./enterprise/media-server/chatwoot-media-server
```

### Network Architecture

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │                        Docker Network                               │
  │                                                                     │
  │  ┌──────────┐   ┌──────────┐   ┌──────────────┐   ┌────────────┐  │
  │  │  web      │   │  worker  │   │ media-server │   │  redis     │  │
  │  │  (Rails)  │   │ (Sidekiq)│   │   (Pion Go)  │   │            │  │
  │  │  :3000    │   │          │   │   :4000 HTTP  │   │  :6379     │  │
  │  │          ◄────────────────────►              │   │            │  │
  │  │          │   │          │   │   :10000-10100│   │            │  │
  │  └────┬─────┘   └──────────┘   │   UDP (media) │   └────────────┘  │
  │       │                        └───────┬──────┘                    │
  │       │                                │                           │
  └───────┼────────────────────────────────┼───────────────────────────┘
          │                                │
          │ :3000 (HTTPS via LB)           │ :10000-10100/UDP
          │                                │ (must be exposed to internet
          │                                │  for WebRTC ICE connectivity)
          ▼                                ▼
   ┌─────────────┐                ┌──────────────────┐
   │   Internet   │                │    Internet       │
   │  (browsers,  │                │  (Meta servers,   │
   │   webhooks)  │                │   agent browsers)  │
   └─────────────┘                └──────────────────┘
```

### Critical: UDP Port Exposure

The media server MUST have UDP ports exposed to the internet for WebRTC ICE to work.
This is because:

1. **Meta-side (Peer A):** Meta's media servers send SRTP packets to the media server's
   public IP/port. The media server must be reachable from Meta's infrastructure.

2. **Agent-side (Peer B):** The agent's browser sends SRTP packets to the media server.
   If the agent is behind a NAT, STUN handles discovery, but the media server must still
   have publicly-accessible UDP ports.

If UDP ports cannot be directly exposed (e.g., behind a restrictive firewall or
cloud load balancer that does not support UDP), a **TURN server** is required as a
relay. The media server's ICE configuration should include TURN credentials for both
Peer A and Peer B.

### STUN/TURN Configuration

| Component      | STUN needed?                     | TURN needed?                         |
|----------------|----------------------------------|--------------------------------------|
| Peer A (Meta)  | Yes (discover server's public IP)| Only if Meta can't reach server UDP  |
| Peer B (Agent) | Yes (standard)                   | If agent is behind restrictive NAT   |

Recommended setup:
- Deploy a TURN server (coturn) alongside the media server
- Or use a managed TURN service (Twilio Network Traversal, Cloudflare TURN)
- Configure TURN credentials in environment variables

---

## 12. Scalability Analysis

### Per-Call Resource Consumption (Media Server)

| Resource       | Per call     | Notes                                           |
|----------------|--------------|--------------------------------------------------|
| Memory         | ~2-3 MB      | Two peer connections, RTP buffers, SRTP contexts |
| CPU            | ~0.5-1%      | Packet forwarding + Opus frame copying (no transcoding) |
| Bandwidth      | ~100 kbps    | Opus audio, both directions (~50kbps each way)   |
| Disk I/O       | ~12 KB/s     | Recording write (Opus @ 48kbps / 8 = 6KB/s * 2 streams) |
| UDP ports      | 4 per call   | 2 for Peer A (RTP + RTCP), 2 for Peer B          |
| File handles   | 3 per call   | 2 sockets + 1 recording file                     |

### Capacity Estimates (Single Media Server Instance)

| Server Size     | RAM    | CPU   | Concurrent Calls | Notes                        |
|-----------------|--------|-------|-------------------|------------------------------|
| Small (2 CPU)   | 2 GB   | 2 core| ~50               | Suitable for most deployments|
| Medium (4 CPU)  | 4 GB   | 4 core| ~200              | Mid-size contact centers     |
| Large (8 CPU)   | 8 GB   | 8 core| ~500              | Large deployments            |

The bottleneck is typically network bandwidth, not CPU or memory. At 100 kbps per
call, 500 concurrent calls require ~50 Mbps of sustained bandwidth.

### Horizontal Scaling

For deployments exceeding 500 concurrent calls:

```
                    ┌─────────────────┐
                    │   Rails App     │
                    │                 │
                    │ Routes calls to │
                    │ media servers   │
                    │ via consistent  │
                    │ hashing on      │
                    │ call_id         │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
       ┌──────▼──────┐ ┌────▼────────┐ ┌──▼──────────┐
       │ media-srv-1 │ │ media-srv-2 │ │ media-srv-3 │
       │ :4000       │ │ :4001       │ │ :4002       │
       │ UDP 10000-  │ │ UDP 10100-  │ │ UDP 10200-  │
       │     10099   │ │     10199   │ │     10299   │
       └─────────────┘ └─────────────┘ └─────────────┘
```

Each media server instance gets a unique range of UDP ports. Rails assigns calls to
instances using consistent hashing on `call_id`. The media server URL is stored in
`Call.meta['media_server_url']` so Rails always routes to the correct instance.

---

## 13. Security Considerations

### Internal API Authentication

```
Rails ──── Bearer {MEDIA_SERVER_AUTH_TOKEN} ────► Media Server
```

The shared secret is configured via environment variable. The media server validates
the token on every request. This is sufficient for co-located services on the same
Docker network.

### SRTP Encryption

All audio is encrypted via SRTP (Secure Real-time Transport Protocol). Pion handles
DTLS key exchange automatically as part of the WebRTC handshake. The media server
decrypts incoming SRTP from one peer and re-encrypts it for the other peer. Audio
is briefly in plaintext within the media server's memory during forwarding.

### Recording Security

- Recording files are stored on a Docker volume, not in a web-accessible directory
- Files are transferred to Rails via internal HTTP and stored in ActiveStorage
- ActiveStorage enforces authentication for blob downloads
- Recording files are deleted from the media server after successful transfer

### ICE Candidate Filtering

The media server should filter ICE candidates to avoid exposing internal network
topology. Only `srflx` (server-reflexive) and `relay` (TURN) candidates should be
included in SDP offers to agent browsers. `host` candidates revealing internal IPs
should be stripped.

### Rate Limiting

The media server should enforce:
- Maximum concurrent sessions per account (configurable, default: 10)
- Maximum session duration (configurable, default: 2 hours)
- Session creation rate limit (configurable, default: 5 per minute per account)

---

## 14. Pros, Cons, and Trade-offs

### Pros

1. **Call persistence across page reloads.** The primary goal. The Meta-side WebRTC
   connection is held by the server; the agent can reconnect within 30 seconds.

2. **Reliable server-side recording.** No dependency on browser memory. Recording is
   written to disk in real time. Even if the browser crashes, the recording up to that
   point is saved.

3. **Centralized call lifecycle.** Rails and the media server fully control the call.
   The browser is a "dumb terminal" for audio I/O. This simplifies state management
   and reduces frontend complexity.

4. **No SDP fix needed in Rails.** The media server generates its own SDP answers using
   Pion, which produces correct `a=setup:active` natively. The `actpass` -> `active`
   string replacement hack is eliminated.

5. **Foundation for advanced features.** Server-side audio access enables:
   - Real-time transcription (stream audio to STT service)
   - Call transfer (redirect Peer B to a different agent)
   - Conference calls (mix multiple Peer B connections)
   - Hold music (play audio file into Peer A while agent is disconnected)
   - Supervisory monitoring (add a listen-only Peer C)

6. **Recording format upgrade.** OGG/Opus with stereo channel separation (customer L,
   agent R) improves transcription accuracy and post-processing flexibility vs the
   current single-channel WebM blob.

### Cons

1. **Increased latency.** Audio passes through an additional hop (media server). Expected
   additional latency: 1-5ms within the same datacenter. Unlikely to be perceptible
   for voice calls (human perception threshold ~40ms).

2. **New infrastructure component.** The Go sidecar is a new process to deploy, monitor,
   and maintain. It adds operational complexity. Teams unfamiliar with Go need to learn
   the codebase for troubleshooting.

3. **UDP port management.** WebRTC requires UDP ports exposed to the internet. This is
   non-trivial in cloud environments with TCP-only load balancers. May require
   additional infrastructure (dedicated UDP-capable load balancer, or direct IP exposure).

4. **Double encryption overhead.** Audio is SRTP-encrypted on both Peer A and Peer B.
   The media server decrypts and re-encrypts every packet. This adds minimal CPU
   overhead (~0.5% per call) but is architecturally unavoidable for a B2BUA.

5. **Single point of failure.** If the media server crashes, all active calls drop. The
   recovery is recordings on disk and Rail terminating lingering calls, but the calls
   themselves cannot be recovered. Mitigated by health checks and automatic restart.

6. **Increased bandwidth.** The media server doubles bandwidth consumption because it
   receives audio from Meta AND sends it to the agent (and vice versa). In the browser-
   direct model, Chatwoot's server uses zero media bandwidth.

### Trade-offs Accepted

| Trade-off                           | Justification                                  |
|-------------------------------------|------------------------------------------------|
| +1 network hop latency              | <5ms, imperceptible for voice                  |
| New Go service to maintain          | Pion is stable; service is small (~2000 LoC)   |
| UDP ports exposed                   | Standard WebRTC requirement; TURN as fallback  |
| Double bandwidth                    | ~100kbps/call is trivial for modern infra       |
| Recordings briefly on local disk    | Cleaned up after ActiveStorage transfer         |

---

## 15. Migration Path

### Phase 1: Build Media Server (2-3 weeks)

**Goal:** Standalone Go binary that can hold a WebRTC peer and record audio.

- Implement session management (create, find, destroy)
- Implement Peer A: accept SDP offer, generate SDP answer, hold SRTP connection
- Implement Peer B: generate SDP offer, accept SDP answer
- Implement audio bridge (forward RTP packets A <-> B)
- Implement OGG/Opus recording
- Implement HTTP API with auth token
- Implement health check endpoint
- Write integration tests with Pion's built-in test utilities
- Dockerize

### Phase 2: Rails Integration (1-2 weeks)

**Goal:** Rails delegates SDP handling to media server; recording fetched server-side.

- Add `Whatsapp::MediaServerClient` service
- Modify `IncomingCallService` to create media session on webhook
- Modify `CallService#pre_accept_and_accept` to use server-generated SDP
- Add `CallReconnectService`
- Add `CallRecordingFetchJob`
- Add new controller actions: `reconnect`, `agent_answer`
- Remove `upload_recording` action
- Add ActionCable event: `whatsapp_call.agent_offer`
- Add media server health check to deployment monitoring
- Feature flag: `whatsapp_call_server_media` (separate from `whatsapp_call`)

### Phase 3: Frontend Migration (1-2 weeks)

**Goal:** Browser connects to media server (Peer B) instead of Meta directly.

- Modify `useWhatsappCallSession.js`:
  - Accept flow: wait for `agent_offer` ActionCable event instead of using Meta's SDP
  - Send `agent_answer` to Rails instead of Meta's SDP answer
  - Remove `MediaRecorder` logic entirely
  - Add reconnection on page load: detect active call, trigger reconnect
  - `beforeunload`: do NOT terminate call, just clean up Peer B locally
- Modify `whatsappCalls.js` store:
  - Add reconnection state
  - Handle `agent_offer` event
  - Timer from `started_at` instead of local counter
- Modify `ConversationHeader.vue` (outbound):
  - No longer generate SDP offer in browser
  - Just POST to `/initiate` without `sdp_offer`
  - Wait for `agent_offer` event after contact answers
- Remove recording-related code from frontend

### Phase 4: Cutover Strategy

**Approach:** Feature flag per account.

```ruby
# In IncomingCallService and CallService:
if account.feature_enabled?('whatsapp_call_server_media')
  # New path: delegate to media server
else
  # Legacy path: browser-direct WebRTC
end
```

```javascript
// In useWhatsappCallSession.js:
const useServerMedia = computed(() =>
  currentAccount.value?.features?.includes('whatsapp_call_server_media')
);
```

This allows:
1. Gradual rollout to test accounts first
2. Instant rollback by disabling the feature flag
3. Both paths coexist during the migration period
4. Legacy path removed once all accounts are migrated

### Phase 5: Cleanup (1 week)

After all accounts are migrated:
- Remove browser-direct WebRTC code path
- Remove `upload_recording` endpoint
- Remove `MediaRecorder` and `startCallRecording` from frontend
- Remove feature flag check (`whatsapp_call_server_media` becomes default)
- Update documentation

### Timeline Summary

| Phase | Duration | Deliverable                                         |
|-------|----------|-----------------------------------------------------|
| 1     | 2-3 wks  | Standalone media server binary, tested              |
| 2     | 1-2 wks  | Rails integration, new endpoints                    |
| 3     | 1-2 wks  | Frontend migration, reconnection                    |
| 4     | 1 wk     | Feature-flagged rollout, validation                 |
| 5     | 1 wk     | Cleanup legacy code                                 |
| **Total** | **6-9 wks** | **Full migration complete**                    |

---

## Appendix A: Alternative Approaches Considered and Rejected

### A1. WebSocket Audio Streaming (No Peer B WebRTC)

Instead of a second WebRTC peer connection to the browser, stream raw audio over
WebSocket.

**Rejected because:**
- 3-5x higher latency (WebSocket has no jitter buffer, no adaptive bitrate)
- Must build custom audio decode/playback pipeline in browser
- No browser echo cancellation (WebRTC AEC is tied to RTCPeerConnection)
- No NAT traversal (WebSocket is TCP, goes through proxies)
- Significantly more frontend code complexity

### A2. SIP Trunking (No WebRTC to Meta)

Meta supports SIP as an alternative to WebRTC for the business endpoint. Use a SIP
server (Asterisk/FreeSWITCH) instead of WebRTC.

**Rejected for initial implementation because:**
- Adds another large infrastructure component (Asterisk/FreeSWITCH)
- SIP requires dedicated infrastructure for NAT traversal (SIP ALG, RTP proxy)
- More complex debugging (SIP signaling + RTP + codec negotiation)
- May be a good Phase 2 option for enterprises already running PBX infrastructure

### A3. Browser Service Worker for Call Persistence

Use a Service Worker to hold the WebRTC peer connection, surviving page reloads.

**Rejected because:**
- Service Workers cannot access `RTCPeerConnection` (not available in SW context)
- `SharedWorker` can hold JS objects across tabs but not across page reloads
- No browser API supports WebRTC connections that survive navigation
- This is a fundamental browser architecture limitation, not a coding problem

### A4. Iframe-Based WebRTC Isolation

Put WebRTC code in a hidden iframe that persists across SPA navigation.

**Rejected because:**
- Only works for SPA navigation (Vue Router), not actual page reloads
- Fragile: iframe can be garbage-collected by browser memory pressure
- Does not solve recording reliability (still browser-dependent)
- Adds significant complexity for marginal benefit

---

## Appendix B: Media Server API Specification (Draft)

### POST /sessions

Create a new call session.

**Request:**
```json
{
  "call_id": "chatwoot_call_42",
  "account_id": 1,
  "direction": "incoming",
  "meta_sdp_offer": "v=0\r\no=- ...",
  "ice_servers": [
    {"urls": "stun:stun.l.google.com:19302"},
    {"urls": "turn:turn.example.com:3478", "username": "user", "credential": "pass"}
  ]
}
```

**Response (201):**
```json
{
  "session_id": "sess_abc123",
  "meta_sdp_answer": "v=0\r\no=- ...",
  "status": "meta_peer_ready"
}
```

For incoming calls, the response includes the SDP answer to send to Meta. For
outgoing calls, `meta_sdp_offer` is null initially; the server generates an offer
that Rails sends to Meta via `initiate_call`.

### POST /sessions/:id/agent-offer

Generate an SDP offer for the agent-side peer connection.

**Response (200):**
```json
{
  "sdp_offer": "v=0\r\no=- ...",
  "ice_servers": [...]
}
```

### POST /sessions/:id/agent-answer

Set the agent's SDP answer and begin audio bridging.

**Request:**
```json
{
  "sdp_answer": "v=0\r\no=- ..."
}
```

**Response (200):**
```json
{
  "status": "bridged",
  "recording": true
}
```

### POST /sessions/:id/agent-reconnect

Tear down old agent peer and create a new one.

**Response (200):**
```json
{
  "sdp_offer": "v=0\r\no=- ...",
  "ice_servers": [...]
}
```

### POST /sessions/:id/terminate

End the session, finalize recording.

**Response (200):**
```json
{
  "status": "terminated",
  "recording_file": "sess_abc123.ogg",
  "recording_size_bytes": 245760,
  "duration_seconds": 135
}
```

### GET /sessions/:id/recording

Download the finalized recording file.

**Response:** Binary OGG/Opus file with `Content-Type: audio/ogg`.

### GET /health

**Response (200):**
```json
{
  "status": "ok",
  "active_sessions": 12,
  "uptime_seconds": 86400
}
```
