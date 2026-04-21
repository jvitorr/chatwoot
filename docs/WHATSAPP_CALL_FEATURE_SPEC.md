# WhatsApp Calling — Feature Spec

> **Edition:** Enterprise (Premium) | **Feature Flag:** `whatsapp_call` | **Branch:** `feat/whatsapp-call`

## What is it?

Agents can **receive and make voice calls** with WhatsApp contacts directly from the Chatwoot dashboard. Calls are browser-based (WebRTC) — no Twilio, no phone hardware, zero telephony cost.

Calls are **automatically recorded** and **transcribed** (OpenAI Whisper), and appear inline in the conversation thread.

---

## How it works (30-second version)

```
                          SIGNALING                              AUDIO
                     (who calls whom,                     (actual voice data)
                      accept/reject)

  ┌──────────┐    REST / Webhooks     ┌──────────────┐
  │ WhatsApp │◄──────────────────────►│   Chatwoot   │
  │ Contact  │                        │   Backend    │
  └────┬─────┘                        └──────┬───────┘
       │                                     │ ActionCable (WebSocket)
       │                                     │
       │      ┌────────────────┐      ┌──────▼───────┐
       └─────►│  Meta Media    │◄════►│   Agent's    │
              │  Servers       │ SRTP │   Browser    │
              └────────────────┘      └──────────────┘

  Key insight: Chatwoot backend handles signaling only.
              Audio flows directly between browser and Meta.
```

---

## Call lifecycle

```
  ┌─────────┐     ┌──────────┐     ┌────────┐     ┌────────────┐
  │ RINGING │────►│ ACCEPTED │────►│ ENDED  │────►│ TRANSCRIBED│
  └─────────┘     └──────────┘     └────────┘     └────────────┘
       │
       ├──► REJECTED
       ├──► MISSED (30s timeout)
       └──► FAILED
```

---

## Inbound call flow

```
Customer dials business number
        │
        ▼
Meta sends webhook ──► IncomingCallService
                        ├── Find/create contact & conversation
                        ├── Create Call record (status: ringing)
                        ├── Create voice_call message
                        └── Broadcast via ActionCable
                                │
                                ▼
                    All agents see floating widget
                    with Accept / Reject buttons
                                │
                      Agent clicks Accept
                        ├── Browser requests mic (getUserMedia)
                        ├── WebRTC peer connection created
                        ├── SDP answer generated + sent to backend
                        └── Backend relays to Meta API
                                │
                                ▼
                    Audio flows (Meta servers ↔ Browser)
                    Recording starts automatically
                                │
                      Call ends (either side hangs up)
                        ├── Recording uploaded
                        └── Transcription triggered (async)
```

## Outbound call flow

```
Agent clicks phone icon in conversation header
        │
        ▼
Browser creates WebRTC offer ──► POST /whatsapp_calls/initiate
                                        │
                                 ┌──────┴──────┐
                                 │             │
                              Success      Error 138006
                                 │         (no permission)
                                 │             │
                                 │      Send permission request
                                 │      to customer via WhatsApp
                                 │             │
                                 │      Customer approves ──► retry call
                                 │
                          Customer's phone rings
                                 │
                          Meta webhook with SDP answer
                                 │
                          Audio connected + recording starts
```

## Call permission flow

Meta requires customers to **opt-in** before a business can call them. If the customer hasn't opted in:

1. Agent tries to call → Meta returns error `138006`
2. Chatwoot auto-sends an interactive permission request to the customer
3. Customer approves on WhatsApp
4. Agent retries the call → succeeds
5. Rate-limited: 1 permission request per 5 minutes per conversation

---

## UI touchpoints

| Where | What |
|-------|------|
| **Conversation Header** | Phone icon to initiate outbound calls |
| **Floating Widget** (bottom-right) | Incoming call notification (accept/reject), active call controls (mute/hangup/timer) |
| **Message Bubble** (VoiceCall type) | Call status, duration, recording audio player, transcript (expandable), "answered by" agent |
| **Inbox Settings** | Toggle to enable/disable calling per WhatsApp inbox |

---

## Data model

```
calls table
├── account_id, inbox_id, conversation_id
├── message_id, accepted_by_agent_id
├── provider (enum: twilio=0, whatsapp=1)
├── direction (enum: incoming=0, outgoing=1)
├── status (ringing → accepted → ended)
├── duration_seconds, end_reason
├── meta (jsonb: SDP offer/answer, ICE servers)
├── transcript (text)
└── recording (ActiveStorage attachment)
```

Voice calls create messages with `content_type: 'voice_call'` containing call metadata in `content_attributes`.

---

## API endpoints

**Base:** `POST /api/v1/accounts/:account_id/whatsapp_calls`

| Endpoint | What it does |
|----------|-------------|
| `GET /:id` | Get call details (SDP offer, ICE servers, caller info) |
| `POST /:id/accept` | Accept call with SDP answer |
| `POST /:id/reject` | Reject incoming call |
| `POST /:id/terminate` | End active call |
| `POST /initiate` | Start outbound call with SDP offer |
| `POST /:id/upload_recording` | Upload recorded audio blob |

## ActionCable events

| Event | When |
|-------|------|
| `whatsapp_call.incoming` | New inbound call (all agents receive) |
| `whatsapp_call.accepted` | Call accepted (dismisses widget for other agents) |
| `whatsapp_call.ended` | Call terminated |
| `whatsapp_call.outbound_connected` | Outbound call answered by customer |
| `whatsapp_call.permission_granted` | Customer approved call permission |

---

## Recording & transcription

```
Agent mic ──┐
            ├──► AudioContext mixer ──► MediaRecorder ──► WebM blob
Remote audio┘                                                │
                                                       Upload to server
                                                             │
                                                    ActiveStorage attachment
                                                             │
                                              CallTranscriptionJob (async)
                                                             │
                                                   OpenAI Whisper API
                                                    (whisper-1, temp 0.4)
                                                             │
                                                    Transcript stored on
                                                    call + message bubble
```

**Requires:** `captain_integration` feature flag + OpenAI API key configured.

---

## Enterprise architecture

All calling code lives under `enterprise/`. Integration with OSS via `prepend_mod_with`:

```
enterprise/app/
├── controllers/api/v1/accounts/whatsapp_calls_controller.rb
├── models/call.rb
├── services/whatsapp/
│   ├── call_service.rb              (accept/reject/terminate orchestration)
│   ├── incoming_call_service.rb     (webhook processing)
│   ├── call_message_builder.rb      (voice_call message creation)
│   ├── call_permission_reply_service.rb
│   ├── call_transcription_service.rb
│   └── providers/whatsapp_cloud_call_methods.rb  (Meta API HTTP layer)
└── jobs/
    ├── whatsapp/call_transcription_job.rb
    └── enterprise/webhooks/whatsapp_events_job.rb
```

**OSS changes (minimal):** `WhatsappEventsJob` gets a `prepend_mod_with` hook + `ActionCableListener` nil safety fix.

---

## Key technical details

| Topic | Detail |
|-------|--------|
| **SDP fix** | Meta requires `a=setup:active` but WebRTC generates `a=setup:actpass` — rewritten server-side |
| **ICE gathering** | 10s timeout, default STUN: `stun:stun.l.google.com:19302` |
| **Module-scope WebRTC** | `RTCPeerConnection`/`MediaStream` stored outside Pinia (not serializable) |
| **Multi-agent routing** | All agents see incoming call; first to accept wins, others get dismissed |
| **Page unload** | Active calls terminated via `fetch({ keepalive: true })` on `beforeunload` |
| **Recording format** | `audio/webm;codecs=opus`, chunked at 1s intervals |

---

## Limitations

| Constraint | Why |
|------------|-----|
| Browser-only | WebRTC requires a browser — no mobile app or SIP phones |
| No rejoin after refresh | P2P connection (unlike Twilio's conference model) |
| Audio only | Meta API doesn't support video calling |
| One call per agent | Single active call at a time |
| Client-side recording | Lost if browser crashes mid-call |
| No TURN server | May fail behind restrictive firewalls blocking UDP |
| Customer opt-in needed | Outbound calls require Meta's permission flow |

---

## WhatsApp vs Twilio comparison

| | WhatsApp Calling | Twilio Voice |
|---|---|---|
| **Model** | Peer-to-peer (browser ↔ Meta) | Conference (Twilio media server) |
| **Cost** | Free | Per-minute billing |
| **Rejoin** | Not possible | Yes (conference persists) |
| **Recording** | Client-side (browser) | Server-side (Twilio) |
| **Video** | Not supported | Possible |
| **SIP phones** | Not supported | Supported |

---

## How to test

1. Enable `whatsapp_call` feature flag on account
2. Enable calling in WhatsApp Cloud inbox settings
3. Test inbound: call the business WhatsApp number → widget appears → accept → audio flows
4. Test outbound: click phone icon in conversation → customer answers → audio flows
5. Verify: recording uploads, transcript appears in message bubble
6. Verify: multiple agents see incoming call, first-to-accept wins

---

*See [PR Breakdown](./WHATSAPP_CALL_PR_BREAKDOWN.md) for the 9-PR implementation plan.*
