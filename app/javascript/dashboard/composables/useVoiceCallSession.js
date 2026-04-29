import { ref, computed, watch, onUnmounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStoreGetters } from 'dashboard/composables/store';
import { useVoiceCallsStore } from 'dashboard/stores/voiceCalls';
import VoiceCallsAPI from 'dashboard/api/voiceCalls';
import Timer from 'dashboard/helper/Timer';
import { emitter } from 'shared/helpers/mitt';

// ─────────────────────────────────────────────────────────────────────────────
// Module-level WebRTC + recorder state. One active peer per browser tab.
// `endActiveCall` and `pagehide` race for finalize duty; `intentionallyClosing`
// disambiguates so beforeunload doesn't warn during a clean hangup.
// ─────────────────────────────────────────────────────────────────────────────
let inboundPc = null;
let inboundStream = null;
let inboundAudio = null;

let audioContext = null;
let mediaRecorder = null;
let recordingMime = null;
let recordingChunks = [];
let recordingFilename = null;
let intentionallyClosing = false;

const RECORDER_MIME_CANDIDATES = [
  'audio/webm;codecs=opus',
  'audio/webm',
  'audio/ogg;codecs=opus',
];

const DEFAULT_ICE = [{ urls: 'stun:stun.l.google.com:19302' }];

function pickRecorderMime() {
  if (typeof MediaRecorder === 'undefined') return null;
  return (
    RECORDER_MIME_CANDIDATES.find(t => MediaRecorder.isTypeSupported(t)) || null
  );
}

function teardownRecorder() {
  mediaRecorder = null;
  recordingChunks = [];
  recordingMime = null;
  recordingFilename = null;
  if (audioContext) {
    audioContext.close().catch(() => {});
    audioContext = null;
  }
}

function extensionFromMime(mime) {
  if (!mime) return 'webm';
  if (mime.startsWith('audio/webm')) return 'webm';
  if (mime.startsWith('audio/ogg')) return 'ogg';
  return 'webm';
}

// Mix the agent's mic and Meta's remote audio into a single stream so the
// resulting Blob is a real conversation rather than two interleaved channels.
// Web Audio handles the mix; we never apply gain (raw levels matter for
// Whisper's speech-detection floor).
function setupRecorder(localStream, remoteStream, callId, providerCallId) {
  if (mediaRecorder || !localStream || !remoteStream) return;
  const mime = pickRecorderMime();
  if (!mime) {
    // eslint-disable-next-line no-console
    console.warn(
      '[Voice Call] No supported MediaRecorder MIME — skipping recording'
    );
    return;
  }

  try {
    audioContext = new (window.AudioContext || window.webkitAudioContext)({
      sampleRate: 48000,
    });
    if (audioContext.state === 'suspended') {
      audioContext.resume().catch(() => {});
    }
    const localSource = audioContext.createMediaStreamSource(localStream);
    const remoteSource = audioContext.createMediaStreamSource(remoteStream);
    const mixDest = audioContext.createMediaStreamDestination();
    localSource.connect(mixDest);
    remoteSource.connect(mixDest);

    recordingMime = mime;
    recordingChunks = [];
    recordingFilename = `call_${callId}_${providerCallId || callId}.${extensionFromMime(mime)}`;

    mediaRecorder = new MediaRecorder(mixDest.stream, { mimeType: mime });
    mediaRecorder.ondataavailable = event => {
      if (event.data && event.data.size) recordingChunks.push(event.data);
    };
    // 5s timeslice keeps the in-memory blob fresh enough for the pagehide
    // beacon to capture most of the call if the user closes the tab.
    mediaRecorder.start(5000);
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[Voice Call] Recorder setup failed:', err);
    teardownRecorder();
  }
}

// stop() returns nothing useful; the final dataavailable fires on the next
// task and onstop fires after that. Wait for onstop, then assemble the blob.
async function stopRecorderAndGetBlob() {
  if (!mediaRecorder) return null;
  const mr = mediaRecorder;
  if (mr.state === 'inactive') {
    const blob = new Blob(recordingChunks, {
      type: recordingMime || 'audio/webm',
    });
    teardownRecorder();
    return { blob, filename: recordingFilename };
  }
  return new Promise(resolve => {
    const cleanup = () => {
      const blob = new Blob(recordingChunks, {
        type: recordingMime || 'audio/webm',
      });
      const filename = recordingFilename;
      teardownRecorder();
      resolve({ blob, filename });
    };
    mr.onstop = cleanup;
    try {
      mr.stop();
    } catch {
      cleanup();
    }
  });
}

function cleanupInboundWebRTC() {
  // Stop recorder first so the source nodes still see live tracks during
  // flush. Any awaited blob is the caller's problem (endActiveCall does it).
  if (mediaRecorder && mediaRecorder.state !== 'inactive') {
    try {
      mediaRecorder.stop();
    } catch {
      // ignore
    }
  }
  teardownRecorder();

  if (inboundStream) {
    inboundStream.getTracks().forEach(track => track.stop());
    inboundStream = null;
  }
  if (inboundPc) {
    inboundPc.close();
    inboundPc = null;
  }
  if (inboundAudio) {
    inboundAudio.srcObject = null;
    if (inboundAudio.parentNode) {
      inboundAudio.parentNode.removeChild(inboundAudio);
    }
    inboundAudio = null;
  }
}

function waitForIceGatheringComplete(pc) {
  return new Promise((resolve, reject) => {
    if (pc.iceGatheringState === 'complete') {
      resolve();
      return;
    }

    let timeout = null;

    const cleanup = () => {
      clearTimeout(timeout);
      pc.onicegatheringstatechange = null;
      pc.oniceconnectionstatechange = null;
    };

    timeout = setTimeout(() => {
      cleanup();
      // eslint-disable-next-line no-console
      console.warn('[Voice Call] ICE gathering timed out, sending partial SDP');
      resolve();
    }, 10000);

    pc.onicegatheringstatechange = () => {
      if (pc.iceGatheringState === 'complete') {
        cleanup();
        resolve();
      }
    };
    pc.oniceconnectionstatechange = () => {
      if (pc.iceConnectionState === 'failed') {
        cleanup();
        reject(new Error('ICE connection failed'));
      }
    };
  });
}

function attachRemoteTrackHandler(pc, callId, providerCallId) {
  pc.ontrack = event => {
    let remoteStream = event.streams && event.streams[0];
    if (!remoteStream) {
      if (!event.track) return;
      remoteStream = new MediaStream([event.track]);
    }
    if (!inboundAudio) {
      const audio = document.createElement('audio');
      audio.autoplay = true;
      document.body.appendChild(audio);
      inboundAudio = audio;
    }
    inboundAudio.srcObject = remoteStream;
    inboundAudio.play().catch(err => {
      // eslint-disable-next-line no-console
      console.warn('[Voice Call] audio.play() rejected:', err);
    });
    if (inboundStream) {
      setupRecorder(inboundStream, remoteStream, callId, providerCallId);
    }
  };
}

// Inbound: browser receives Meta's SDP offer via the voice_call.incoming
// cable event, opens its mic, builds the answer, and ships it back so Rails
// can hand it to Meta. After this returns, the agent and Meta are mid-DTLS.
async function prepareInboundAnswer({
  callId,
  providerCallId,
  sdpOffer,
  iceServers,
}) {
  cleanupInboundWebRTC();
  const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  inboundStream = stream;

  const servers = iceServers?.length ? iceServers : DEFAULT_ICE;
  const pc = new RTCPeerConnection({ iceServers: servers });
  inboundPc = pc;

  stream.getTracks().forEach(track => pc.addTrack(track, stream));
  attachRemoteTrackHandler(pc, callId, providerCallId);

  await pc.setRemoteDescription({ type: 'offer', sdp: sdpOffer });
  const answer = await pc.createAnswer();
  await pc.setLocalDescription(answer);
  await waitForIceGatheringComplete(pc);

  return pc.localDescription.sdp;
}

// Outbound: browser builds the offer locally, before any network call. Rails
// hands the offer to Meta via initiate_call; we receive Meta's SDP answer
// later via the voice_call.outbound_connected cable event.
async function prepareOutboundOffer({
  callId,
  providerCallId,
  iceServers,
} = {}) {
  cleanupInboundWebRTC();
  const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  inboundStream = stream;

  const servers = iceServers?.length ? iceServers : DEFAULT_ICE;
  const pc = new RTCPeerConnection({ iceServers: servers });
  inboundPc = pc;

  stream.getTracks().forEach(track => pc.addTrack(track, stream));
  attachRemoteTrackHandler(pc, callId, providerCallId);

  const offer = await pc.createOffer({ offerToReceiveAudio: true });
  await pc.setLocalDescription(offer);
  await waitForIceGatheringComplete(pc);

  return pc.localDescription.sdp;
}

// Apply Meta's SDP answer to the existing outbound RTCPeerConnection. Called
// from the actionCable handler when voice_call.outbound_connected lands.
async function applyOutboundAnswer(sdpAnswer) {
  if (!inboundPc) throw new Error('No active outbound RTCPeerConnection');
  if (inboundPc.signalingState !== 'have-local-offer') {
    // Already applied — duplicate cable delivery. No-op rather than detonate.
    return;
  }
  await inboundPc.setRemoteDescription({ type: 'answer', sdp: sdpAnswer });
  // Some browsers fire ontrack synchronously inside setRemoteDescription;
  // others delay it. If we already have a remote stream, kick the recorder.
  if (inboundAudio?.srcObject && inboundStream) {
    setupRecorder(inboundStream, inboundAudio.srcObject, undefined, undefined);
  }
}

export { prepareOutboundOffer, applyOutboundAnswer, cleanupInboundWebRTC };

// Standalone for the message bubble's Accept button. Branches on whether the
// store has an SDP offer (WhatsApp direct mode = always yes).
export async function acceptVoiceCallById(callId) {
  const callsStore = useVoiceCallsStore();

  if (callsStore.hasActiveCall) {
    return { success: false, error: 'active_call_exists' };
  }

  let call = callsStore.incomingCalls.find(
    c => c.id === callId || c.callId === String(callId)
  );

  let sdpOffer = call?.sdpOffer;
  let iceServers = call?.iceServers;
  let providerCallId = call?.callId;

  if (!sdpOffer) {
    const { data } = await VoiceCallsAPI.show(callId);
    if (data.status !== 'ringing') {
      return { success: false, error: 'not_ringing' };
    }
    sdpOffer = data.sdp_offer;
    iceServers = data.ice_servers;
    providerCallId = data.call_id;
    call = {
      id: data.id,
      callId: data.call_id,
      provider: data.provider,
      direction: data.direction,
      inboxId: data.inbox_id,
      conversationId: data.conversation_id,
      caller: data.caller,
      sdpOffer,
      iceServers,
    };
    callsStore.addIncomingCall(call);
  }

  if (!sdpOffer) return { success: false, error: 'missing_sdp_offer' };

  // ORDER-SENSITIVE: setActiveCall must happen synchronously before the
  // network call so the cable handler doesn't drop a frame on a null guard.
  const activeCallData = { ...call };
  callsStore.setActiveCall(activeCallData);

  try {
    const sdpAnswer = await prepareInboundAnswer({
      callId: call.id,
      providerCallId,
      sdpOffer,
      iceServers,
    });
    await VoiceCallsAPI.accept(call.id, { sdpAnswer });
    callsStore.removeIncomingCall(call.callId);
    callsStore.markActiveCallConnected();
    emitter.emit('voice_call:agent_webrtc_connected');
    return { success: true, call: activeCallData };
  } catch (err) {
    cleanupInboundWebRTC();
    callsStore.removeIncomingCall(call.callId);
    callsStore.clearActiveCall?.();
    throw err;
  }
}

// Best-effort upload. Errors are swallowed because the call has already
// completed by the time we get here; surfacing failures isn't actionable.
async function uploadRecordingBlob(callId) {
  if (!mediaRecorder && recordingChunks.length === 0) return;
  try {
    const result = await stopRecorderAndGetBlob();
    if (!result?.blob || result.blob.size === 0) return;
    await VoiceCallsAPI.uploadRecording(callId, result.blob, result.filename);
  } catch (err) {
    // eslint-disable-next-line no-console
    console.warn('[Voice Call] Recording upload failed:', err);
  }
}

// ── Composable (used by VoiceCallWidget for floating UI + timer) ──
export function useVoiceCallSession() {
  const { t } = useI18n();
  const callsStore = useVoiceCallsStore();
  const getters = useStoreGetters();
  const accountId = computed(() => getters.getCurrentAccountId.value);

  const isAccepting = ref(false);
  const isMuted = ref(false);
  const callError = ref(null);
  const callDuration = ref(0);

  const durationTimer = new Timer(elapsed => {
    callDuration.value = elapsed;
  });

  const activeCall = computed(() => callsStore.activeCall);
  const incomingCalls = computed(() => callsStore.incomingCalls);
  const hasActiveCall = computed(() => callsStore.hasActiveCall);
  const hasIncomingCall = computed(() => callsStore.hasIncomingCall);
  const firstIncomingCall = computed(() => callsStore.firstIncomingCall);

  const isOutboundRinging = computed(
    () =>
      activeCall.value?.direction === 'outbound' &&
      activeCall.value?.status === 'ringing'
  );

  const formattedCallDuration = computed(() => {
    const minutes = Math.floor(callDuration.value / 60);
    const seconds = callDuration.value % 60;
    return `${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
  });

  // Triggered when handleCallEnded fires — i.e. the OTHER side hung up
  // (Meta terminate webhook → voice_call.ended cable). Upload whatever we
  // recorded BEFORE tearing down the PC, otherwise the agent-hangup path is
  // the only one that ships audio to the server. uploadRecordingBlob
  // gathers the blob via the recorder's onstop listener and then frees the
  // recorder — only AFTER that completes do we close the PC and stop tracks.
  callsStore.registerCleanupCallback(async callId => {
    const idForUpload = callId || activeCall.value?.id;
    durationTimer.stop();
    callDuration.value = 0;
    try {
      if (idForUpload) await uploadRecordingBlob(idForUpload);
    } finally {
      cleanupInboundWebRTC();
    }
  });

  // Warn the user if they try to navigate away mid-call. The actual cleanup
  // happens in the pagehide handler — beforeunload is purely the warning.
  const handleBeforeUnload = e => {
    if (!callsStore.activeCall || intentionallyClosing) return undefined;
    e.preventDefault();
    e.returnValue = '';
    // Some browsers (older Safari/Firefox) only honour a returned string.
    // eslint-disable-next-line consistent-return
    return '';
  };

  // Fires after the user confirms close (or on tab switch). We use fetch
  // with `keepalive: true` rather than navigator.sendBeacon because Chatwoot
  // authenticates via devise-token-auth headers (`access-token`, `client`,
  // `uid`) which sendBeacon cannot attach — beacon would 401 silently.
  // fetch+keepalive sends both cookies AND custom headers and the request
  // survives page unload (capped at ~64KB body, fine for terminate).
  const handlePageHide = () => {
    const call = callsStore.activeCall;
    if (!call || intentionallyClosing) return;

    // Stop the recorder synchronously; final dataavailable already fired via
    // the 5s timeslice, so chunks[] is approximately current.
    if (mediaRecorder && mediaRecorder.state !== 'inactive') {
      try {
        mediaRecorder.stop();
      } catch {
        // ignore
      }
    }

    const sessionHeaders = (() => {
      try {
        return JSON.parse(
          decodeURIComponent(
            (document.cookie.match(/(^|;\s*)cw_d_session_info=([^;]+)/) ||
              [])[2] || '%7B%7D'
          )
        );
      } catch {
        return {};
      }
    })();
    const authHeaders = {
      'access-token': sessionHeaders['access-token'] || '',
      client: sessionHeaders.client || '',
      uid: sessionHeaders.uid || '',
      expiry: sessionHeaders.expiry || '',
      'token-type': sessionHeaders['token-type'] || 'Bearer',
    };

    if (recordingChunks.length > 0 && accountId.value) {
      try {
        const blob = new Blob(recordingChunks, {
          type: recordingMime || 'audio/webm',
        });
        const fd = new FormData();
        fd.append(
          'recording',
          blob,
          recordingFilename || `call_${call.id}.webm`
        );
        fetch(
          `/api/v1/accounts/${accountId.value}/voice_calls/${call.id}/upload_recording`,
          {
            method: 'POST',
            body: fd,
            credentials: 'include',
            keepalive: true,
            headers: authHeaders,
          }
        );
      } catch {
        // ignore
      }
    }
    if (accountId.value) {
      try {
        fetch(
          `/api/v1/accounts/${accountId.value}/voice_calls/${call.id}/terminate`,
          {
            method: 'POST',
            credentials: 'include',
            keepalive: true,
            headers: authHeaders,
          }
        );
      } catch {
        // ignore
      }
    }
    cleanupInboundWebRTC();
  };

  window.addEventListener('beforeunload', handleBeforeUnload);
  window.addEventListener('pagehide', handlePageHide);

  // Start timer when an outbound call transitions to connected.
  watch(activeCall, call => {
    if (
      call?.direction === 'outbound' &&
      call?.status === 'connected' &&
      !durationTimer.intervalId
    ) {
      durationTimer.start();
    }
  });

  // Floating-widget Accept button. Same WhatsApp-direct flow as
  // acceptVoiceCallById — see comments there.
  const acceptCall = async call => {
    if (isAccepting.value) return;
    isAccepting.value = true;
    callError.value = null;

    const sdpOffer = call.sdpOffer;
    const iceServers = call.iceServers;
    if (!sdpOffer) {
      callError.value = t('WHATSAPP_CALL.CALL_FAILED');
      isAccepting.value = false;
      return;
    }

    const activeCallData = { ...call };
    callsStore.setActiveCall(activeCallData);

    try {
      const sdpAnswer = await prepareInboundAnswer({
        callId: call.id,
        providerCallId: call.callId,
        sdpOffer,
        iceServers,
      });
      await VoiceCallsAPI.accept(call.id, { sdpAnswer });
      callsStore.removeIncomingCall(call.callId);
      callsStore.markActiveCallConnected();
      durationTimer.start();
      emitter.emit('voice_call:agent_webrtc_connected');
    } catch (err) {
      callError.value =
        err?.name === 'NotAllowedError'
          ? t('WHATSAPP_CALL.MIC_DENIED')
          : t('WHATSAPP_CALL.CALL_FAILED');
      // eslint-disable-next-line no-console
      console.error('[Voice Call] acceptCall error:', err);
      cleanupInboundWebRTC();
      callsStore.removeIncomingCall(call.callId);
      callsStore.clearActiveCall();
    } finally {
      isAccepting.value = false;
    }
  };

  const rejectCall = async call => {
    try {
      await VoiceCallsAPI.reject(call.id);
    } catch {
      // Best effort
    } finally {
      callsStore.removeIncomingCall(call.callId);
    }
  };

  const endActiveCall = async () => {
    const call = activeCall.value;
    if (!call) return;
    intentionallyClosing = true;

    try {
      await uploadRecordingBlob(call.id);
    } catch {
      // Best effort
    }

    try {
      await VoiceCallsAPI.terminate(call.id);
    } catch {
      // Best effort
    } finally {
      cleanupInboundWebRTC();
      callsStore.clearActiveCall();
      durationTimer.stop();
      callDuration.value = 0;
      intentionallyClosing = false;
    }
  };

  const toggleMute = () => {
    if (!inboundStream) return;
    const audioTrack = inboundStream.getAudioTracks()[0];
    if (!audioTrack) return;
    audioTrack.enabled = !audioTrack.enabled;
    isMuted.value = !audioTrack.enabled;
  };

  const dismissIncomingCall = call => {
    callsStore.removeIncomingCall(call.callId);
  };

  const startDurationTimer = () => {
    durationTimer.start();
  };

  onUnmounted(() => {
    window.removeEventListener('beforeunload', handleBeforeUnload);
    window.removeEventListener('pagehide', handlePageHide);
    durationTimer.stop();
  });

  return {
    activeCall,
    incomingCalls,
    hasActiveCall,
    hasIncomingCall,
    firstIncomingCall,
    isAccepting,
    isMuted,
    isOutboundRinging,
    callError,
    formattedCallDuration,
    acceptCall,
    rejectCall,
    endActiveCall,
    toggleMute,
    dismissIncomingCall,
    startDurationTimer,
  };
}
