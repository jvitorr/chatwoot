# Frontend Architecture: Server-Side WebRTC WhatsApp Calling

> Design document for migrating WhatsApp calling from browser-side WebRTC to server-side WebRTC with browser audio relay.

---

## 1. Architecture Overview

### Current model (being replaced)

```
Agent Browser                    Meta Media Servers
┌─────────────────────┐          ┌──────────────┐
│  RTCPeerConnection  │◄═══════►│  SRTP Audio   │
│  SDP offer/answer   │  direct  │              │
│  ICE candidates     │  media   │              │
│  MediaRecorder      │          │              │
│  AudioContext mixer  │          │              │
└─────────────────────┘          └──────────────┘
         ▲
         │ ActionCable (signaling only)
         ▼
┌─────────────────────┐
│  Chatwoot Backend   │
│  (relay SDP/ICE)    │
└─────────────────────┘
```

### New model

```
Agent Browser                    Chatwoot Backend                Meta Media Servers
┌──────────────────┐     WS      ┌─────────────────┐   SRTP    ┌──────────────┐
│  getUserMedia()  │────────────►│  Audio Ingest    │          │              │
│  (mic capture)   │  agent mic  │                 │          │              │
│                  │             │  RTCPeerConn    │◄════════►│  Media       │
│  AudioContext    │◄────────────│  SDP/ICE        │  direct  │  Servers     │
│  (playback)     │  remote     │  MediaRecorder  │  media   │              │
│                  │  audio      │  (server-side)  │          │              │
│  UI Controls    │             │                 │          │              │
│  (mute/hangup)  │◄───────────►│  ActionCable    │          │              │
│                  │  signaling  │  (call events)  │          │              │
└──────────────────┘             └─────────────────┘          └──────────────┘
```

Key changes:
- **WebRTC lives on the server.** The backend holds the RTCPeerConnection to Meta.
- **Browser sends mic audio** to the server over a dedicated binary WebSocket.
- **Server relays remote audio** back to the browser over the same WebSocket.
- **Recording is server-side.** No client-side MediaRecorder, no upload step.
- **Page reload does not kill the call.** The server-side connection persists; the browser just reconnects its audio stream.

---

## 2. Recommended Audio Relay Mechanism

### Evaluation of options

| Mechanism | Latency | Complexity | Browser Support | Reconnection | Verdict |
|-----------|---------|-----------|----------------|--------------|---------|
| **Dedicated binary WebSocket** | 20-50ms | Low | Universal | Trivial (new WS) | **Recommended** |
| Secondary WebRTC (browser to server) | 5-20ms | High | Universal | Hard (new SDP) | Over-engineered |
| WebTransport | 5-15ms | Medium | Chrome/Edge only | Medium | Not ready |
| ActionCable binary frames | 30-80ms | Low | Universal | Free (existing) | Too slow, not designed for media |

### Recommendation: Dedicated binary WebSocket

**Why not reuse ActionCable?** ActionCable is JSON-framed, multiplexed, and adds overhead for binary payloads. Audio needs a dedicated low-latency binary channel with no framing overhead.

**Why not a second WebRTC connection?** The entire point of this migration is to remove WebRTC complexity from the browser. Adding a browser-to-server WebRTC leg reintroduces SDP negotiation, ICE gathering, and DTLS setup -- the exact things we are eliminating.

**Why not WebTransport?** Firefox and Safari do not yet have stable support. The latency improvement over WebSocket (5-15ms vs 20-50ms) does not justify excluding a third of agents.

### Audio relay protocol design

```
Dedicated WebSocket: wss://{host}/cable/audio?call_id={id}&token={jwt}

Frame format (binary):
┌──────────┬──────────┬─────────────────────────┐
│ type (1B)│ seq (2B) │ payload (variable)       │
├──────────┼──────────┼─────────────────────────┤
│ 0x01     │ uint16   │ Opus frame (agent mic)  │  browser → server
│ 0x02     │ uint16   │ Opus frame (remote)     │  server → browser
│ 0x03     │ -        │ JSON control message    │  bidirectional
└──────────┴──────────┴─────────────────────────┘

Audio encoding:
- Codec: Opus (native to WebRTC, supported by AudioEncoder API)
- Sample rate: 48kHz mono (Opus default)
- Frame duration: 20ms (960 samples per frame)
- Bitrate: 24-32 kbps (speech-optimized)
- Frames per WebSocket message: 1 (20ms per message = 50 messages/sec)

Control messages (type 0x03):
- { "action": "mute" }
- { "action": "unmute" }
- { "action": "heartbeat" }
- { "action": "reconnected", "resumeFrom": seq }
```

**Why Opus?** It is the codec Meta uses for WhatsApp call audio. The server receives Opus from Meta's SRTP stream and can forward it directly to the browser without transcoding. The browser can also encode mic input as Opus using the WebCodecs `AudioEncoder` API (Chrome 94+, Firefox 130+, Safari 16.4+).

**Fallback for older browsers:** If `AudioEncoder` is unavailable, fall back to sending raw PCM Int16 at 16kHz (32 KB/s). The server transcodes to Opus before injecting into the WebRTC session.

---

## 3. Component Tree

```
App.vue
└── DashboardLayout.vue
    ├── ConversationHeader.vue
    │   └── [phone icon button] ──► calls store.initiateCall()
    │
    ├── MessageBubble (VoiceCall.vue)
    │   └── [accept/join button] ──► calls store.acceptCall()
    │
    └── CallWidget.vue  (fixed position, bottom-right)
        ├── IncomingCallCard.vue  (for each ringing call)
        │   ├── Avatar + caller info
        │   ├── Accept button ──► calls store.acceptCall()
        │   └── Reject button ──► calls store.rejectCall()
        │
        ├── ActiveCallCard.vue  (single active call)
        │   ├── Avatar + caller info
        │   ├── Duration timer (formattedDuration from store)
        │   ├── Mute toggle ──► calls store.toggleMute()
        │   ├── Hangup button ──► calls store.endCall()
        │   └── ReconnectingBanner.vue  (shown during audio reconnection)
        │
        └── CallErrorBanner.vue
```

### What changed vs current
- **Removed:** No WebRTC logic in any component. Components are now pure UI.
- **Simplified:** ConversationHeader no longer creates RTCPeerConnection or manages SDP. It calls a single store action.
- **Added:** `ReconnectingBanner` sub-component for the reconnection state.
- **Same:** WhatsappCallWidget stays as the floating overlay. VoiceCall.vue bubble stays as the message thread display.

---

## 4. Composable Design

The current monolithic `useWhatsappCallSession.js` (406 lines) is split into three focused composables:

### 4a. `useCallAudioStream.js` -- audio capture and playback

This composable owns the dedicated WebSocket, mic capture, and audio playback. It has zero knowledge of call signaling or UI state.

```
Module-level state (singleton, survives component remounts):
- audioSocket: WebSocket | null
- audioContext: AudioContext | null
- micStream: MediaStream | null
- audioEncoder: AudioEncoder | null  (WebCodecs)
- playbackNode: AudioWorkletNode | null
- sequenceNumber: number
- isConnected: ref(false)
- isCapturing: ref(false)

Exported function: useCallAudioStream()

Returns:
  // State
  isAudioConnected: Ref<boolean>
  isCapturing: Ref<boolean>
  isReconnecting: Ref<boolean>
  audioLevel: Ref<number>          // 0-1, for visual feedback

  // Actions
  connect(callId: string): Promise<void>
    1. Open WS to /cable/audio?call_id={callId}&token={jwt}
    2. Create AudioContext (48kHz)
    3. getUserMedia({ audio: true })
    4. Pipe mic → AudioWorkletNode (capture processor) → AudioEncoder → WS send
    5. Register WS.onmessage handler: decode Opus frames → playback buffer
    6. Start playback via AudioWorkletNode (playback processor)

  disconnect(): void
    1. Close WS
    2. Stop mic tracks
    3. Close AudioContext
    4. Reset all state

  setMuted(muted: boolean): void
    1. If muted: stop sending mic frames (but keep mic open for fast unmute)
    2. If unmuted: resume sending
    // No server round-trip needed. Simply stop emitting frames.

  reconnect(callId: string): Promise<void>
    1. Disconnect existing
    2. Connect fresh (server already has the call)
    3. Resume audio from current server buffer position
```

**AudioWorklet processors** (two small files):

`mic-capture-processor.js` -- runs on the audio thread:
```js
// Receives Float32 PCM from getUserMedia
// Posts ArrayBuffer to main thread for encoding
class MicCaptureProcessor extends AudioWorkletProcessor {
  process(inputs) {
    const input = inputs[0][0]; // mono channel
    if (input) {
      this.port.postMessage(input.buffer, [input.buffer]);
    }
    return true;
  }
}
registerProcessor('mic-capture', MicCaptureProcessor);
```

`audio-playback-processor.js` -- runs on the audio thread:
```js
// Receives decoded PCM buffers via port.postMessage
// Writes them into output for playback
// Maintains a small jitter buffer (60-100ms)
class AudioPlaybackProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buffer = []; // ring buffer of Float32Arrays
    this.port.onmessage = (e) => this.buffer.push(e.data);
  }
  process(outputs) {
    const output = outputs[0][0];
    if (this.buffer.length > 0) {
      const frame = this.buffer.shift();
      output.set(frame.subarray(0, output.length));
    }
    return true;
  }
}
registerProcessor('audio-playback', AudioPlaybackProcessor);
```

### 4b. `useCallSession.js` -- call lifecycle and UI state

This replaces the current `useWhatsappCallSession.js`. It orchestrates call signaling (via REST API) and delegates audio to `useCallAudioStream`. No WebRTC code.

```
Exported function: useCallSession()

Internally uses:
  - useWhatsappCallsStore() (Pinia)
  - useCallAudioStream()
  - Timer helper

Returns:
  // Read-only state (delegated from store)
  activeCall: ComputedRef<CallData | null>
  incomingCalls: ComputedRef<CallData[]>
  hasActiveCall: ComputedRef<boolean>
  hasIncomingCall: ComputedRef<boolean>
  firstIncomingCall: ComputedRef<CallData | null>
  isOutboundRinging: ComputedRef<boolean>

  // Session state
  isAccepting: Ref<boolean>
  isMuted: Ref<boolean>
  isReconnecting: Ref<boolean>       // NEW: true during page-reload rejoin
  callError: Ref<string | null>
  formattedCallDuration: ComputedRef<string>

  // Actions
  acceptCall(call): Promise<void>
    1. POST /whatsapp_calls/:id/accept  (NO SDP -- server handles WebRTC)
    2. store.setActiveCall(call)
    3. audioStream.connect(call.id)
    4. timer.start()

  rejectCall(call): Promise<void>
    1. POST /whatsapp_calls/:id/reject
    2. store.removeIncomingCall(call.callId)

  endCall(): Promise<void>
    1. audioStream.disconnect()
    2. POST /whatsapp_calls/:id/terminate
    3. store.clearActiveCall()
    4. timer.stop()

  toggleMute(): void
    1. audioStream.setMuted(!isMuted.value)
    2. isMuted.value = !isMuted.value

  initiateCall(conversationId): Promise<void>   // NEW: moved from ConversationHeader
    1. POST /whatsapp_calls/initiate  (NO SDP offer -- server creates its own)
    2. store.setActiveCall({ status: 'ringing', direction: 'outbound', ... })
    3. Wait for ActionCable 'whatsapp_call.outbound_connected' event
    4. audioStream.connect(call.id)
    5. timer.start()

  rejoinCall(callId): Promise<void>             // NEW: reconnection after page reload
    1. GET /whatsapp_calls/:id  → verify status is 'accepted' or 'in_progress'
    2. store.setActiveCall(callData)
    3. audioStream.connect(callId)
    4. Fetch elapsed duration from server to resume timer

  dismissIncomingCall(call): void
    1. store.removeIncomingCall(call.callId)
```

### 4c. `useCallReconnection.js` -- handles page reload during active call

```
Exported function: useCallReconnection()

Logic (runs on mount):
  1. On app startup, check: GET /whatsapp_calls/active
     - New API endpoint that returns the agent's current active call (if any)
  2. If an active call exists:
     - Set isReconnecting = true
     - Call callSession.rejoinCall(callId)
     - Set isReconnecting = false
  3. Register visibility change listener:
     - On document becoming visible after being hidden, verify audio WS is healthy
     - If WS is closed, trigger reconnect
```

---

## 5. Pinia Store Schema

The store becomes drastically simpler. All non-serializable objects (RTCPeerConnection, MediaStream, AudioContext) move out of the store entirely -- they live in `useCallAudioStream` at module scope.

### New store: `stores/whatsappCalls.js`

```js
// NO module-scoped WebRTC objects. No outboundCall state.
// The store is now purely serializable call metadata.

defineStore('whatsappCalls', {
  state: () => ({
    incomingCalls: [],       // CallData[]
    activeCall: null,        // CallData | null
    callTimerOffset: 0,      // seconds already elapsed (for reconnection)
  }),

  getters: {
    hasIncomingCall: (state) => state.incomingCalls.length > 0,
    hasActiveCall: (state) => state.activeCall !== null,
    hasWhatsappCall: (state) => state.incomingCalls.length > 0 || state.activeCall !== null,
    firstIncomingCall: (state) => state.incomingCalls[0] || null,
  },

  actions: {
    addIncomingCall(callData) { ... },
    removeIncomingCall(callId) { ... },
    setActiveCall(callData) { ... },
    clearActiveCall() { ... },
    markActiveCallConnected() { ... },
    handleCallAcceptedByOther(callId) { ... },
    handleCallEnded(callId) { ... },
    setTimerOffset(seconds) { this.callTimerOffset = seconds; },
  },
});
```

### CallData type definition

```ts
interface CallData {
  id: number;                    // server-side Call record ID
  callId: string;                // Meta's call_id
  direction: 'inbound' | 'outbound';
  status: 'ringing' | 'connected' | 'reconnecting';
  inboxId: number;
  conversationId: number;
  caller: {
    name?: string;
    phone?: string;
    avatar?: string;
  };
  // REMOVED: sdpOffer, iceServers -- no longer sent to browser
}
```

### What was removed from the store

| Old | New | Why |
|-----|-----|-----|
| `outboundCall` (module-scoped `{ pc, stream, audio, callId }`) | Gone | No WebRTC objects in browser |
| `getOutboundCallState()` | Gone | No peer connection to query |
| `setOutboundCallProperty()` | Gone | No peer connection to mutate |
| `cleanupOutboundCall()` | Gone | Audio cleanup is in `useCallAudioStream.disconnect()` |
| `cleanupCallback` | Gone | No need for cross-concern cleanup registration |
| `registerCleanupCallback()` | Gone | Store actions directly call composable |

### What was added

| New | Why |
|-----|-----|
| `callTimerOffset` | When reconnecting after page reload, the server tells us how many seconds the call has been active. The timer starts from this offset instead of 0. |

---

## 6. Reconnection Flow

This is the primary benefit of the server-side architecture. The server's WebRTC connection to Meta persists across browser page loads.

### Scenario: Agent refreshes page during active call

```
Timeline:
─────────────────────────────────────────────────────────────────►

1. Agent is on an active call (audio flowing)

2. Agent hits F5 (page reload)
   ├── beforeunload fires
   │   └── Audio WS closes (but we do NOT terminate the call)
   │       Unlike current code which calls terminateCallOnUnload()
   ├── Server detects WS disconnect
   │   └── Server continues holding the Meta WebRTC session
   │   └── Server buffers incoming remote audio (or drops it, brief gap is OK)
   └── Browser unloads

3. Page reloads, Vue app mounts
   ├── useCallReconnection() runs on mount
   │   └── GET /whatsapp_calls/active
   │       Response: { id: 42, call_id: "abc", status: "accepted",
   │                   direction: "inbound", elapsed_seconds: 47, ... }
   │
   ├── Store updated: setActiveCall(callData)
   │   UI immediately shows CallWidget with "Reconnecting..." banner
   │
   ├── callSession.rejoinCall(42)
   │   ├── audioStream.connect(42)
   │   │   ├── New WS to /cable/audio?call_id=42
   │   │   ├── getUserMedia() -- browser may re-prompt for mic
   │   │   ├── AudioContext + worklets initialized
   │   │   └── Audio flowing again
   │   │
   │   └── Timer resumes from elapsed_seconds (47)
   │       formattedCallDuration shows "00:47" and counting
   │
   └── ReconnectingBanner disappears, ActiveCallCard shows normally

4. Call continues as if nothing happened
   Total audio gap: ~2-4 seconds (page load time)
```

### Scenario: Network blip (WebSocket drops briefly)

```
1. Audio WS disconnects unexpectedly

2. useCallAudioStream detects WS close
   ├── isReconnecting = true
   ├── UI shows "Reconnecting..." in ActiveCallCard
   └── Start reconnection with exponential backoff:
       attempt 1: wait 500ms → try WS connect
       attempt 2: wait 1000ms → try WS connect
       attempt 3: wait 2000ms → try WS connect
       max 5 attempts, then show error

3. WS reconnects
   ├── isReconnecting = false
   ├── Audio resumes
   └── UI returns to normal

4. If all 5 attempts fail:
   ├── Show error: "Audio connection lost. Call is still active on server."
   └── Offer "Reconnect" button that retries
```

### Scenario: Agent opens a second tab

```
1. Call is active in Tab A

2. Agent opens Tab B (or navigates to Chatwoot in new tab)
   ├── useCallReconnection() runs
   │   └── GET /whatsapp_calls/active → returns active call
   │
   ├── Two options (backend decides):
   │   a) TRANSFER audio to new tab: Server closes Tab A's audio WS,
   │      Tab B becomes the audio source. Tab A shows "Call moved to another tab."
   │   b) BLOCK: Return { active: true, owned_by_other_session: true }
   │      Tab B shows the call widget in "view only" mode (timer, no controls)
   │
   └── Recommendation: Option (a) -- transfer. Matches user intent
       (they probably want to continue in the new tab).
```

---

## 7. File Structure

### Files to create (new)

```
app/javascript/dashboard/
├── composables/
│   ├── useCallAudioStream.js          # Audio capture, WS relay, playback
│   ├── useCallSession.js              # Call lifecycle (accept/reject/end/initiate)
│   └── useCallReconnection.js         # Page-reload reconnection logic
│
├── workers/
│   ├── mic-capture-processor.js       # AudioWorklet: mic → main thread
│   └── audio-playback-processor.js    # AudioWorklet: main thread → speaker
│
└── helpers/
    └── callAudioCodec.js              # WebCodecs Opus encode/decode helpers
```

### Files to modify

```
app/javascript/dashboard/
├── composables/
│   └── useWhatsappCallSession.js      # DELETE entirely (replaced by useCallSession.js)
│
├── stores/
│   └── whatsappCalls.js               # Simplify: remove all WebRTC state/helpers
│
├── api/
│   └── whatsappCalls.js               # Modify: remove SDP params, add active() endpoint
│
├── helper/
│   └── actionCable.js                 # Modify: simplify event handlers (no SDP relay)
│
├── components/widgets/
│   ├── WhatsappCallWidget.vue         # Minor: use new composable, add reconnection UI
│   └── conversation/
│       └── ConversationHeader.vue     # Major simplification: remove all WebRTC code
│
└── components-next/message/bubbles/
    └── VoiceCall.vue                  # Minor: acceptWhatsappCallById → store action
```

### Files to delete

```
(none explicitly deleted as files, but the following become unnecessary
 and their content is removed or replaced:)

- All RTCPeerConnection code in useWhatsappCallSession.js → replaced
- All SDP/ICE code in ConversationHeader.vue → replaced
- startCallRecording / stopAndUploadRecording → gone (server-side recording)
- terminateCallOnUnload → replaced with "do nothing" (call persists)
```

---

## 8. API Changes Required

The REST API needs small changes to support the new model:

### Modified endpoints

| Endpoint | Old | New |
|----------|-----|-----|
| `POST /:id/accept` | Sends `{ sdp_answer }` | Sends `{}` (no SDP, server handles it) |
| `POST /initiate` | Sends `{ conversation_id, sdp_offer }` | Sends `{ conversation_id }` (no SDP) |
| `POST /:id/upload_recording` | Browser uploads webm blob | **Removed** -- server records directly |

### New endpoints

| Endpoint | Purpose |
|----------|---------|
| `GET /whatsapp_calls/active` | Returns the current agent's active call (if any). Used for reconnection on page load. Returns `null` if no active call. |
| `WS /cable/audio?call_id={id}&token={jwt}` | Dedicated binary WebSocket for audio relay. Separate from ActionCable. |

### Modified ActionCable events

| Event | Old payload | New payload |
|-------|-------------|-------------|
| `whatsapp_call.incoming` | `{ ..., sdp_offer, ice_servers }` | `{ ..., }` (no SDP/ICE -- browser does not need them) |
| `whatsapp_call.outbound_connected` | `{ call_id, sdp_answer }` | `{ call_id }` (no SDP -- just signals "ready for audio WS") |

---

## 9. ActionCable Handler Changes

The `actionCable.js` handlers simplify significantly:

```
Current handlers (what changes):

onWhatsappCallIncoming:
  OLD: Store sdpOffer + iceServers in incoming call data
  NEW: Store only metadata (id, callId, direction, caller, conversationId)
       No sdpOffer, no iceServers

onWhatsappCallAccepted:
  OLD: Same
  NEW: Same (no change -- purely a signaling event)

onWhatsappCallEnded:
  OLD: Calls store.handleCallEnded which triggers cleanupCallback (WebRTC teardown)
  NEW: Calls store.handleCallEnded which is now just state cleanup
       Audio cleanup happens separately via useCallAudioStream detecting WS close

onWhatsappCallOutboundConnected:
  OLD: Gets outbound PC, calls pc.setRemoteDescription(sdp_answer)
  NEW: Calls store.markActiveCallConnected()
       Triggers useCallSession to open the audio WS
       No SDP handling at all

onWhatsappCallPermissionGranted:
  OLD: Same
  NEW: Same (no change -- purely a UI notification)
```

---

## 10. Comparison: Old vs New

### Code complexity

| Aspect | Old (browser WebRTC) | New (server relay) |
|--------|---------------------|-------------------|
| **useWhatsappCallSession.js** | 406 lines, WebRTC + recording + SDP + ICE | ~80 lines, pure call lifecycle orchestration |
| **ConversationHeader.vue (call code)** | ~100 lines of WebRTC setup in component | ~10 lines: single `store.initiateCall()` call |
| **Pinia store** | 94 lines + module-scoped `outboundCall` with PC/Stream | ~60 lines, purely serializable state |
| **actionCable.js (call handlers)** | 50 lines with SDP relay logic | ~25 lines, metadata-only event handling |
| **AudioWorklet processors** | N/A | ~30 lines each (two files), standard pattern |
| **useCallAudioStream.js** | N/A (was inline WebRTC) | ~150 lines, focused audio I/O |
| **Total frontend call code** | ~650 lines, scattered across 5 files | ~400 lines, organized in 3 composables + 2 worklets |

### Capability comparison

| Capability | Old | New |
|-----------|-----|-----|
| Call survives page reload | No | Yes |
| Call survives network blip | No (ICE restart needed) | Yes (WS reconnect) |
| Recording reliability | Low (browser crash = lost) | High (server-side) |
| Multi-tab support | Not possible | Transfer or view-only |
| Agent on mobile browser | Fragile (background tab kills WebRTC) | Better (WS more resilient) |
| TURN server needed | Yes (for restrictive NAT) | No (server has public IP) |
| Browser API surface | RTCPeerConnection, MediaRecorder, AudioContext, ICE, SDP, SRTP | getUserMedia, AudioContext, WebSocket, WebCodecs |
| Codec flexibility | Locked to WebRTC negotiation | Server can transcode |

### Latency comparison

| Path | Old | New |
|------|-----|-----|
| Agent mic to customer | ~50ms (direct P2P via SRTP) | ~70-100ms (+20-50ms WS hop to server) |
| Customer to agent speaker | ~50ms (direct P2P via SRTP) | ~70-100ms (+20-50ms WS hop from server) |

The added ~20-50ms per direction is imperceptible in voice calls (human perception threshold for audio delay is ~150ms).

### Failure mode comparison

| Failure | Old | New |
|---------|-----|-----|
| Browser crashes | Call dead, recording lost | Call continues on server, agent can rejoin |
| Network drops 5s | ICE restart attempt (often fails) | WS reconnect, brief audio gap |
| Agent closes tab | Call terminated (beforeunload) | Call persists, agent can rejoin (or timeout) |
| Server crashes | Call continues (P2P) | Call dead (single point of failure) |

The server becoming a single point of failure is mitigated by the fact that it already is the single point of failure for signaling. If the server goes down in the old model, the agent cannot accept new calls or initiate calls anyway. The incremental risk is that an *in-progress* call dies, which is manageable with standard server redundancy.

---

## 11. Migration Strategy

### Phase 1: Backend (prerequisite)
- Server-side WebRTC: RTCPeerConnection to Meta from the backend process
- Audio WebSocket endpoint: `/cable/audio` with binary frame handling
- Server-side recording with the same Opus stream
- New `GET /whatsapp_calls/active` endpoint
- Modified `POST /accept` and `POST /initiate` (no SDP params)

### Phase 2: Frontend (this document)
- Create `useCallAudioStream.js` + AudioWorklet processors
- Create `useCallSession.js` to replace `useWhatsappCallSession.js`
- Create `useCallReconnection.js`
- Simplify Pinia store
- Simplify ActionCable handlers
- Update CallWidget with reconnection UI
- Remove all WebRTC code from ConversationHeader

### Phase 3: Cleanup
- Remove `startCallRecording` / `stopAndUploadRecording` exports
- Remove `uploadRecording` API method
- Remove `sdpOffer` / `iceServers` from all frontend types
- Feature flag: `whatsapp_call_server_relay` to toggle between old/new during rollout

---

## 12. Open Questions for Backend Team

1. **Audio WebSocket authentication**: Should we use a short-lived JWT in the WS URL query param, or perform auth in the first WS frame? JWT in URL is simpler but appears in server logs.

2. **Server-side timeout**: When the browser disconnects the audio WS (page reload), how long should the server hold the Meta WebRTC session before auto-terminating? Recommendation: 30 seconds.

3. **Audio buffering during reconnection**: Should the server buffer remote audio during a WS disconnect and replay it when the browser reconnects? Or just drop those frames? Recommendation: Drop -- a 2-4 second gap is acceptable, buffering adds complexity.

4. **Opus passthrough vs transcode**: Can the server forward Meta's Opus frames directly to the browser WS, or does the SRTP decryption produce raw PCM that needs re-encoding? Direct passthrough is ideal (zero CPU cost).

5. **Multi-process deployment**: If Chatwoot runs multiple Rails processes/pods, how does the audio WS route to the process that holds the RTCPeerConnection? Sticky sessions? Redis pub/sub relay? This is a backend architecture question but affects the WS endpoint design.
