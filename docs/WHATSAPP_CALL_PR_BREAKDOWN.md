# WhatsApp Calling — PR Breakdown Plan

> **Branch:** `feat/whatsapp-call` → **Base:** `develop`
> **Date:** 2026-04-14 (updated)
> **Goal:** Split the monolithic feature branch into **8 backend + 1 frontend = 9 mergeable PRs**, each covering a single concept.

---

## Merge Order & Dependency Graph

```
BACKEND                                         FRONTEND

PR-1: Call Model + Migration ✅ MERGED
  │
  ├── PR-2: Meta API Provider Methods
  │     │
  │     ├── PR-3: Inbound Webhook Pipeline
  │     │     │
  │     │     └── PR-4: Call Service +
  │     │           Controller + Routes ──────► PR-9: All Frontend Changes
  │     │                                       (API, Store, WebRTC, Widget,
  │     └─────────────────────────────────►      Bubble, Outbound UI,
  │                                              ActionCable, Settings,
  ├── PR-5: Transcription Pipeline               Voice Guard, i18n, Feature Flag)
  │
  ├── PR-6: Feature Flag + Enterprise Gating
  │
  ├── PR-7: OSS Touchpoints (webhook job refactor + ActionCable fix)
  │
  └── PR-8: Inbox Calling Config (provider_config + serializer)
```

---

## Backend PRs

### PR-1: Call Model + Migration + Error Classes ✅ MERGED

> **Status:** Merged via PR #14026 (`feat/voice-call-model` branch).

**Files included:** `db/migrate/20260408170902_create_calls.rb`, `enterprise/app/models/call.rb`, association concerns, `enterprise/lib/whatsapp/call_errors.rb`, `config/features.yml` (whatsapp_call flag definition).

**No action required — already in `develop`.**

---

### PR-2: Meta Cloud API Provider Methods

**Concept:** Low-level HTTP methods that communicate with Meta's WhatsApp Cloud API v22.0 for voice calls. No business logic — just the raw API client layer.

**Files:**

| File | Action | Lines |
|------|--------|-------|
| `enterprise/app/services/whatsapp/providers/whatsapp_cloud_call_methods.rb` | NEW | ~85 |
| `enterprise/app/services/enterprise/whatsapp/providers/whatsapp_cloud_service.rb` | MODIFY | +include |
| `enterprise/app/services/enterprise/whatsapp/facebook_api_client.rb` | MODIFY | +`calls` to webhook fields |

**Methods provided:**
```
pre_accept_call(call_id)           → 200 OK (keeps call alive for SDP exchange)
accept_call(call_id, sdp_answer)   → 200 OK
reject_call(call_id)               → 200 OK
terminate_call(call_id)            → 200 OK
initiate_call(to, sdp_offer)       → {call_id, sdp_answer, ice_servers}
send_call_permission_request(to)   → 200 OK (interactive permission template)
```

**Dependencies:** PR-1 ✅ (merged).

**Risk:** Low. Methods exist but are dormant until consumers ship.

---

### PR-3: Inbound Webhook Pipeline

**Concept:** The complete server-side flow for processing incoming call webhooks from Meta: event routing → call creation → message building → ActionCable broadcasting.

**Files:**

| File | Action | Lines |
|------|--------|-------|
| `enterprise/app/services/whatsapp/incoming_call_service.rb` | NEW | ~211 |
| `enterprise/app/services/whatsapp/call_message_builder.rb` | NEW | ~108 |
| `enterprise/app/services/whatsapp/call_permission_reply_service.rb` | NEW | ~61 |
| `enterprise/app/jobs/enterprise/webhooks/whatsapp_events_job.rb` | NEW | ~40 |

**How it works:**
1. Meta sends webhook with `calls` field → `WhatsappEventsJob` routes to `IncomingCallService`
2. `IncomingCallService` creates/updates `Call` record based on event type (`connect` or `terminate`)
3. `CallMessageBuilder` creates `voice_call` content-type messages in the conversation
4. ActionCable broadcasts `whatsapp_call.incoming` / `whatsapp_call.ended` to the account channel
5. For `call_permission_reply` interactive messages → `CallPermissionReplyService` handles opt-in

**Key detail:** `IncomingCallService` does NOT call Meta's API — it only processes incoming data. No dependency on PR-2.

**Dependencies:** PR-1 ✅ (merged), PR-7 (OSS touchpoints for `prepend_mod_with` hook).

**Risk:** Medium. The webhook event routing (`prepend_mod_with` in the enterprise job) overrides `handle_message_events`. Must ensure `super` delegation doesn't break existing message processing.

---

### PR-4: Call Service + Controller + Routes

**Concept:** The REST API surface for agent-driven call actions (accept, reject, terminate, initiate) and the service orchestrating those actions.

**Files:**

| File | Action | Lines |
|------|--------|-------|
| `enterprise/app/services/whatsapp/call_service.rb` | NEW | ~109 |
| `enterprise/app/controllers/api/v1/accounts/whatsapp_calls_controller.rb` | NEW | ~142 |
| `config/routes.rb` | MODIFY | +resources |
| `enterprise/app/models/enterprise/conversation.rb` | MODIFY | +`allowed_keys?` for `call_status` |

**Endpoints:**

| Method | Path | Action | Description |
|--------|------|--------|-------------|
| GET | `/api/v1/accounts/:account_id/whatsapp_calls/:id` | show | Get call details (SDP offer, ICE servers) |
| POST | `/api/v1/accounts/:account_id/whatsapp_calls/:id/accept` | accept | Accept with SDP answer |
| POST | `/api/v1/accounts/:account_id/whatsapp_calls/:id/reject` | reject | Reject the call |
| POST | `/api/v1/accounts/:account_id/whatsapp_calls/:id/terminate` | terminate | End active call |
| POST | `/api/v1/accounts/:account_id/whatsapp_calls/initiate` | initiate | Start outbound call |
| POST | `/api/v1/accounts/:account_id/whatsapp_calls/:id/upload_recording` | upload_recording | Upload recording blob |

**CallService flow (accept):**
```
pre_accept_call → WebRTC SDP exchange → accept_call (with SDP fix: actpass→active) → update status → broadcast
```

**Dependencies:** PR-1 ✅ (merged), PR-2 (Meta API methods), PR-3 (CallMessageBuilder).

**Risk:** Medium. The controller's `initiate` action handles the permission flow (error 138006 → `send_call_permission_request`). The `upload_recording` action enqueues `CallTranscriptionJob` (PR-5). If PR-5 hasn't merged, temporarily guard the enqueue.

---

### PR-5: Recording Upload + Transcription Pipeline

**Concept:** Async transcription of call recordings using OpenAI Whisper.

**Files:**

| File | Action | Lines |
|------|--------|-------|
| `enterprise/app/services/whatsapp/call_transcription_service.rb` | NEW | ~82 |
| `enterprise/app/jobs/whatsapp/call_transcription_job.rb` | NEW | ~15 |

**Pipeline:**
```
Browser records audio (MediaRecorder) → upload_recording endpoint →
ActiveStorage attachment → CallTranscriptionJob →
CallTranscriptionService → OpenAI Whisper (whisper-1, temp 0.4) →
call.transcript + message.content_attributes updated
```

**Gating:** Requires `captain_integration` feature flag + usage limits check. Inherits from `Llm::LegacyBaseOpenAiService`.

**Error handling:** Retries on `ActiveStorage::FileNotFoundError`, discards on `Faraday::BadRequestError`.

**Dependencies:** PR-1 ✅ (merged). Can merge before or with PR-4.

**Risk:** Low. Fully async, failure-tolerant. No impact on call flow if transcription fails.

---

### PR-6: Feature Flag + Enterprise Gating

**Concept:** Ensure the `whatsapp_call` feature flag is properly checked at all entry points.

**What it covers:**
- Controller: `ensure_whatsapp_call_enabled` before_action
- IncomingCallService: `account.feature_enabled?('whatsapp_call')` check
- CallPermissionReplyService: same check
- Inbox-level toggle: `provider_config['calling_enabled']` on Channel::Whatsapp

> **Note:** The feature flag definition in `config/features.yml` shipped with PR-1. This PR adds the runtime guard logic across services and controllers. May be bundled into PR-4 if too small standalone.

---

### PR-7: OSS Touchpoints

**Concept:** Minimal changes to OSS (non-enterprise) files required for the calling feature to work.

**Files:**

| File | Action | Lines | Change |
|------|--------|-------|--------|
| `app/jobs/webhooks/whatsapp_events_job.rb` | MODIFY | ~10 | Add `prepend_mod_with` hook + extract `handle_message_events` |
| `app/listeners/action_cable_listener.rb` | MODIFY | ~2 | Nil safety fix in `typing_event_listener_tokens` |

**Why separate:** These are the only two OSS Ruby files modified. Keeping them in a dedicated PR makes review clear — reviewers can verify the `super` delegation path and ensure existing message processing isn't broken.

> **Note:** The `handle_message_events` extraction from the webhook job also supports the `smb_message_echoes` feature (PR #13371). If that's already merged to `develop`, this extraction may already exist. Check before creating this PR.

**Dependencies:** None. Should merge early (before PR-3 which depends on the `prepend_mod_with` hook).

**Risk:** Low but critical to verify. The `super` call path must be tested to ensure non-call webhooks still process correctly.

---

### PR-8: Inbox Calling Config (provider_config + serializer)

**Concept:** Backend support for the per-inbox `calling_enabled` toggle in `provider_config` for WhatsApp Cloud channels.

**What it covers:**
- Allow `calling_enabled` in strong params for Channel::Whatsapp updates
- Expose `calling_enabled` in inbox serializer response
- Ensure `provider_config` merge (not overwrite) when updating

**Dependencies:** PR-1 ✅ (merged).

**Risk:** Low. Purely additive config key — no behavior change if not set.

---

## Frontend PR

### PR-9: All Frontend Changes (Combined)

**Concept:** The complete frontend implementation — API client, store, WebRTC engine, UI widgets, ActionCable integration, message bubble enhancements, outbound calling, inbox settings toggle, voice helper guard, i18n, and feature flag registration.

**Files:**

| File | Action | Lines | Layer |
|------|--------|-------|-------|
| `app/javascript/dashboard/api/whatsappCalls.js` | NEW | ~43 | API client |
| `app/javascript/dashboard/stores/whatsappCalls.js` | NEW | ~94 | State management |
| `app/javascript/dashboard/featureFlags.js` | MODIFY | +2 | Feature flag |
| `app/javascript/dashboard/i18n/locale/en/whatsappCall.json` | NEW | ~20 | i18n |
| `app/javascript/dashboard/i18n/locale/en/index.js` | MODIFY | +1 | i18n |
| `app/javascript/dashboard/helper/voice.js` | MODIFY | ~20 | Voice guard |
| `app/javascript/dashboard/composables/useWhatsappCallSession.js` | NEW | ~406 | WebRTC engine |
| `app/javascript/dashboard/helper/actionCable.js` | MODIFY | +5 handlers | Real-time events |
| `app/javascript/dashboard/components/widgets/WhatsappCallWidget.vue` | NEW | ~216 | Call widget UI |
| `app/javascript/dashboard/routes/dashboard/Dashboard.vue` | MODIFY | +import | Widget mount |
| `app/javascript/dashboard/components-next/message/bubbles/VoiceCall.vue` | MODIFY | ~145 | Message bubble |
| `app/javascript/dashboard/i18n/locale/en/conversation.json` | MODIFY | +6 keys | i18n |
| `app/javascript/dashboard/components/widgets/conversation/ConversationHeader.vue` | MODIFY | ~130 | Outbound calling |
| `app/javascript/dashboard/routes/dashboard/settings/inbox/settingsPage/ConfigurationPage.vue` | MODIFY | ~20 | Inbox settings |
| `app/javascript/dashboard/i18n/locale/en/inboxMgmt.json` | MODIFY | +3 keys | i18n |

**Key components:**

1. **API Client** — `show`, `accept`, `reject`, `terminate`, `initiate`, `uploadRecording`
2. **Pinia Store** — Module-scoped WebRTC objects (non-serializable) outside reactive state
3. **WebRTC Composable** — `useWhatsappCallSession()`, `acceptWhatsappCallById()`, `startCallRecording()`
4. **ActionCable Events** — `incoming`, `accepted`, `ended`, `outbound_connected`, `permission_granted`
5. **Floating Widget** — Incoming/active call states with accept/reject/mute/hangup
6. **VoiceCall Bubble** — Accept button, recording player, transcript toggle, "answered by" display
7. **Outbound UI** — Phone icon in ConversationHeader, full WebRTC offer/answer flow
8. **Inbox Toggle** — `calling_enabled` checkbox in WhatsApp Cloud inbox settings
9. **Voice Guard** — Prevents WhatsApp call messages from triggering Twilio store

**Backend prerequisites:** PR-4 (REST endpoints), PR-3 (ActionCable broadcasts), PR-8 (inbox config).

**Risk:** ⚠️ HIGH — Largest PR. Review focus areas:
- Duplicated ICE gathering logic in ConversationHeader vs composable
- Missing `onUnmounted` cleanup for outbound calls in ConversationHeader
- `console.log` left in ConversationHeader ICE state logging
- Hardcoded STUN server with no backend-provided config
- Recording mimeType `audio/webm;codecs=opus` with no browser feature detection
- Bare string in ActionCable `onWhatsappCallPermissionGranted` (should use i18n)
- Frontend feature flag declared but unused (gated server-side only)

**Estimated size:** ~1,200 lines across 15 files.

---

## Recommended Merge Sequence

### Phase 1: Foundation (Week 1)

| Order | PR | Type | Depends On | Est. Size |
|-------|-----|------|------------|-----------|
| — | **PR-1:** Call Model + Migration | Backend | None | ✅ MERGED |
| 1 | **PR-7:** OSS Touchpoints | Backend | None | ~12 lines |
| 2 | **PR-8:** Inbox Calling Config | Backend | PR-1 ✅ | ~30 lines |

### Phase 2: Backend Services (Week 1-2)

| Order | PR | Type | Depends On | Est. Size |
|-------|-----|------|------------|-----------|
| 3 | **PR-2:** Meta API Provider Methods | Backend | PR-1 ✅ | ~90 lines |
| 4 | **PR-3:** Inbound Webhook Pipeline | Backend | PR-1 ✅, PR-7 | ~420 lines |
| 5 | **PR-5:** Transcription Pipeline | Backend | PR-1 ✅ | ~97 lines |
| 6 | **PR-6:** Feature Flag Gating | Backend | PR-1 ✅ | ~20 lines |

### Phase 3: Backend API + Frontend (Week 2-3)

| Order | PR | Type | Depends On | Est. Size |
|-------|-----|------|------------|-----------|
| 7 | **PR-4:** Call Service + Controller + Routes | Backend | PR-2, PR-3, PR-5 | ~260 lines |
| 8 | **PR-9:** All Frontend Changes | Frontend | PR-4, PR-3, PR-8 | ~1,200 lines |

---

## Parallel Merge Opportunities

These PRs have no dependencies on each other and can be reviewed/merged in parallel:

- **PR-7, PR-8** — independent foundation PRs
- **PR-2, PR-3, PR-5, PR-6** — all depend only on PR-1 (merged) and/or PR-7

---

## Issues Found During Analysis

| # | Issue | Severity | PR Affected |
|---|-------|----------|-------------|
| 1 | **Duplicated ICE gathering logic** — `waitForOutboundIceGathering` in ConversationHeader vs `waitForIceGatheringComplete` in composable | Medium | PR-9 |
| 2 | **No `onUnmounted` cleanup** for outbound calls in ConversationHeader | Medium | PR-9 |
| 3 | **Feature flag unused on frontend** — `FEATURE_FLAGS.WHATSAPP_CALL` declared but no component checks it | Low | PR-9 |
| 4 | **Bare string in ActionCable** — `onWhatsappCallPermissionGranted` uses template literal instead of i18n key | Low | PR-9 |
| 5 | **Hardcoded STUN server** — `stun:stun.l.google.com:19302` with no backend-provided config | Low | PR-9 |
| 6 | **Recording mimeType assumption** — `audio/webm;codecs=opus` with no browser feature detection | Low | PR-9 |
| 7 | **`console.log` left in** — ICE state logging in ConversationHeader | Low | PR-9 |

---

## Cherry-Pick Strategy

Since the branch has ~270+ commits (including develop merges), cherry-picking individual commits won't work cleanly. Instead:

1. **For each PR**, create a new branch from `develop`
2. **Copy the specific files** from `feat/whatsapp-call` using:
   ```bash
   git checkout feat/whatsapp-call -- path/to/file1 path/to/file2
   ```
3. **For modified files** (routes.rb, actionCable.js, etc.), manually apply only the relevant diff hunks
4. **Run tests** for each PR independently before opening

---

## Testing Checklist Per PR

| PR | Test Strategy |
|----|---------------|
| PR-2 | Unit test Meta API methods with WebMock/VCR stubs |
| PR-3 | Integration test: simulate Meta webhook payload → verify Call record + message created |
| PR-4 | Request specs: hit each endpoint, verify response + side effects |
| PR-5 | Unit test: mock OpenAI API, verify transcript stored on call + message |
| PR-6 | Verify feature flag gating blocks unauthorized accounts |
| PR-7 | Verify existing WhatsApp message webhook processing still works |
| PR-8 | Verify inbox serializer includes `calling_enabled` |
| PR-9 | `pnpm test` on store + manual E2E: inbound call, outbound call, recording, settings toggle |
