import { ref, computed, watch, onUnmounted } from 'vue';
import { useI18n } from 'vue-i18n';
import {
  useWhatsappCallsStore,
  getOutboundCallState,
  cleanupOutboundCall,
} from 'dashboard/stores/whatsappCalls';
import WhatsappCallsAPI from 'dashboard/api/whatsappCalls';
import Auth from 'dashboard/api/auth';
import Timer from 'dashboard/helper/Timer';

// ── Module-level WebRTC state (shared across legacy inbound + server-relay) ──
let inboundPc = null;
let inboundStream = null;
let inboundAudio = null;

// ── Module-level recording state (legacy mode only) ──
let mediaRecorder = null;
let recordedChunks = [];
let recordingCallId = null;

function cleanupInboundWebRTC() {
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

/**
 * Start recording both local and remote audio tracks via MediaRecorder.
 * Mixes them into a single stream using AudioContext.
 * Used ONLY in legacy (browser-direct) mode.
 */
export function startCallRecording(pc, localStream, callId) {
  try {
    const ctx = new AudioContext();
    const dest = ctx.createMediaStreamDestination();

    if (localStream) {
      const localSource = ctx.createMediaStreamSource(localStream);
      localSource.connect(dest);
    }

    pc.getReceivers().forEach(receiver => {
      if (receiver.track && receiver.track.kind === 'audio') {
        const remoteStream = new MediaStream([receiver.track]);
        const remoteSource = ctx.createMediaStreamSource(remoteStream);
        remoteSource.connect(dest);
      }
    });

    recordedChunks = [];
    recordingCallId = callId;
    const recorder = new MediaRecorder(dest.stream, {
      mimeType: 'audio/webm;codecs=opus',
    });

    recorder.ondataavailable = e => {
      if (e.data.size > 0) recordedChunks.push(e.data);
    };

    mediaRecorder = recorder;
    recorder.start(1000);
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error('[WhatsApp Call] Failed to start recording:', err);
  }
}

/**
 * Stop recording and upload the audio blob to the backend.
 * Used ONLY in legacy (browser-direct) mode.
 */
function stopAndUploadRecording(callId) {
  if (!mediaRecorder || mediaRecorder.state === 'inactive') return;

  const id = callId || recordingCallId;

  mediaRecorder.onstop = () => {
    if (recordedChunks.length === 0 || !id) return;

    const blob = new Blob(recordedChunks, { type: 'audio/webm' });
    recordedChunks = [];
    recordingCallId = null;

    WhatsappCallsAPI.uploadRecording(id, blob).catch(err => {
      // eslint-disable-next-line no-console
      console.error('[WhatsApp Call] Failed to upload recording:', err);
    });
  };

  mediaRecorder.stop();
  mediaRecorder = null;
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
      console.warn(
        '[WhatsApp Call] ICE gathering timed out, sending partial SDP'
      );
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

// ── Server-relay mode detection ──
// Prefer the explicit flag set by Rails whenever it's available (call object
// from GET /whatsapp_calls/:id, inbox serializer, or the incoming ActionCable
// broadcast). Fall back to the presence of sdpOffer so legacy deployments keep
// working when the field isn't set.
function isServerRelayCall(call) {
  if (call?.mediaServerEnabled === true) return true;
  if (call?.mediaServerEnabled === false) return false;
  return !call?.sdpOffer;
}

/**
 * Handle an SDP offer from the media server (Peer B). Used in server-relay mode
 * for both inbound accept and outbound connect flows.
 *
 * Flow: getUserMedia -> RTCPeerConnection(iceServers) -> setRemoteDescription(offer)
 *       -> createAnswer -> waitForICE -> POST /agent_answer
 */
async function handleAgentOffer(callId, sdpOffer, iceServers) {
  cleanupInboundWebRTC();

  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    inboundStream = stream;

    const servers = iceServers?.length
      ? iceServers
      : [{ urls: 'stun:stun.l.google.com:19302' }];

    const pc = new RTCPeerConnection({ iceServers: servers });
    inboundPc = pc;

    stream.getTracks().forEach(track => pc.addTrack(track, stream));

    pc.ontrack = event => {
      const [remoteStream] = event.streams;
      if (!remoteStream) return;
      if (!inboundAudio) {
        const audio = document.createElement('audio');
        audio.autoplay = true;
        document.body.appendChild(audio);
        inboundAudio = audio;
      }
      inboundAudio.srcObject = remoteStream;
      inboundAudio.play().catch(() => {});

      // No client-side recording in server-relay mode — the media server records
    };

    await pc.setRemoteDescription({ type: 'offer', sdp: sdpOffer });
    const answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    await waitForIceGatheringComplete(pc);

    const completeSdp = pc.localDescription.sdp;
    await WhatsappCallsAPI.agentAnswer(callId, completeSdp);

    return { success: true };
  } catch (err) {
    cleanupInboundWebRTC();
    throw err;
  }
}

// Expose handleAgentOffer so ActionCable handler can invoke it
export { handleAgentOffer };

/**
 * Legacy mode: creates WebRTC session and posts SDP to backend (browser ↔ Meta).
 * Can be called from anywhere — composable, widget, or bubble.
 */
async function doAcceptCall(call) {
  // Server-relay mode: just POST /accept without SDP. Wait for agent_offer event.
  if (isServerRelayCall(call)) {
    await WhatsappCallsAPI.accept(call.id);
    return { success: true, awaitingAgentOffer: true };
  }

  // Legacy mode: full browser-side WebRTC handshake
  cleanupInboundWebRTC();

  try {
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    inboundStream = stream;

    const iceServers = call.iceServers?.length
      ? call.iceServers
      : [{ urls: 'stun:stun.l.google.com:19302' }];

    const pc = new RTCPeerConnection({ iceServers });
    inboundPc = pc;

    stream.getTracks().forEach(track => pc.addTrack(track, stream));

    pc.ontrack = event => {
      const [remoteStream] = event.streams;
      if (!remoteStream) return;
      if (!inboundAudio) {
        const audio = document.createElement('audio');
        audio.autoplay = true;
        document.body.appendChild(audio);
        inboundAudio = audio;
      }
      inboundAudio.srcObject = remoteStream;
      inboundAudio.play().catch(() => {});

      // Start recording once remote audio is available (legacy mode only)
      startCallRecording(pc, stream, call.id);
    };

    await pc.setRemoteDescription({ type: 'offer', sdp: call.sdpOffer });
    const answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    await waitForIceGatheringComplete(pc);

    const completeSdp = pc.localDescription.sdp;
    await WhatsappCallsAPI.accept(call.id, completeSdp);

    return { success: true };
  } catch (err) {
    cleanupInboundWebRTC();
    throw err;
  }
}

/**
 * Standalone function callable from VoiceCall bubble.
 * Fetches call data if needed, runs WebRTC accept, updates store.
 */
export async function acceptWhatsappCallById(callId) {
  const callsStore = useWhatsappCallsStore();

  if (callsStore.hasActiveCall) {
    return { success: false, error: 'active_call_exists' };
  }

  let call = callsStore.incomingCalls.find(
    c => c.id === callId || c.callId === String(callId)
  );

  if (!call) {
    const { data } = await WhatsappCallsAPI.show(callId);
    if (data.status !== 'ringing') {
      return { success: false, error: 'not_ringing' };
    }
    call = {
      id: data.id,
      callId: data.call_id,
      direction: data.direction,
      inboxId: data.inbox_id,
      conversationId: data.conversation_id,
      sdpOffer: data.sdp_offer,
      iceServers: data.ice_servers,
      mediaServerEnabled: data.media_server_enabled,
      caller: data.caller,
    };
    callsStore.addIncomingCall(call);
  }

  try {
    const result = await doAcceptCall(call);

    callsStore.removeIncomingCall(call.callId);

    // In server-relay mode the call becomes active but awaits the agent_offer
    // ActionCable event to complete WebRTC setup. Mark it with serverRelay flag.
    const activeCallData = {
      ...call,
      serverRelay: isServerRelayCall(call),
    };
    callsStore.setActiveCall(activeCallData);

    return { success: true, call: activeCallData, ...result };
  } catch (err) {
    callsStore.removeIncomingCall(call.callId);
    throw err;
  }
}

/**
 * Fire-and-forget terminate request using fetch + keepalive.
 * Works reliably inside beforeunload / pagehide where axios won't complete.
 * Used ONLY in legacy mode. Server-relay mode does NOT terminate on unload.
 */
function terminateCallOnUnload(callId) {
  const authData = Auth.hasAuthCookie() ? Auth.getAuthData() : {};
  const accountId =
    window.location.pathname.includes('/app/accounts') &&
    window.location.pathname.split('/')[3];
  if (!accountId) return;

  const url = `/api/v1/accounts/${accountId}/whatsapp_calls/${callId}/terminate`;
  fetch(url, {
    method: 'POST',
    keepalive: true,
    headers: {
      'Content-Type': 'application/json',
      'access-token': authData['access-token'] || '',
      'token-type': authData['token-type'] || '',
      client: authData.client || '',
      expiry: authData.expiry || '',
      uid: authData.uid || '',
    },
  }).catch(() => {});
}

// ── Composable (used by WhatsappCallWidget for floating UI + timer) ──
export function useWhatsappCallSession() {
  const { t } = useI18n();
  const callsStore = useWhatsappCallsStore();

  const isAccepting = ref(false);
  const isMuted = ref(false);
  const callError = ref(null);
  const callDuration = ref(0);
  const isReconnecting = computed(() => callsStore.isReconnecting);

  const durationTimer = new Timer(elapsed => {
    callDuration.value = callsStore.callTimerOffset + elapsed;
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

  // Register cleanup so external call-end events can teardown WebRTC
  callsStore.registerCleanupCallback(() => {
    // Only do recording cleanup in legacy mode
    if (!callsStore.isMediaServerEnabled) {
      stopAndUploadRecording();
    }
    cleanupInboundWebRTC();
    durationTimer.stop();
    callDuration.value = 0;
  });

  // On page close / reload:
  // - Legacy mode: terminate call (current behavior)
  // - Server-relay mode: just clean up local WebRTC resources, call persists
  const handleBeforeUnload = () => {
    const call = callsStore.activeCall;
    if (!call?.id) return;

    if (call.serverRelay) {
      // Server-relay: only clean up local resources, do NOT terminate
      cleanupInboundWebRTC();
    } else {
      // Legacy: terminate and clean up
      terminateCallOnUnload(call.id);
      cleanupInboundWebRTC();
    }
  };
  window.addEventListener('beforeunload', handleBeforeUnload);

  // Start timer when outbound call becomes connected
  watch(activeCall, call => {
    if (
      call?.direction === 'outbound' &&
      call?.status === 'connected' &&
      !durationTimer.intervalId
    ) {
      durationTimer.start();
    }
  });

  /**
   * Accept an incoming call — used by the floating widget buttons.
   */
  const acceptCall = async call => {
    if (isAccepting.value) return;
    isAccepting.value = true;
    callError.value = null;

    try {
      const result = await doAcceptCall(call);
      callsStore.removeIncomingCall(call.callId);

      const activeCallData = {
        ...call,
        serverRelay: isServerRelayCall(call),
      };
      callsStore.setActiveCall(activeCallData);

      // In legacy mode, WebRTC is already established so start timer now.
      // In server-relay mode, timer starts when handleAgentOffer completes
      // (triggered by the whatsapp_call.agent_offer ActionCable event).
      if (!result.awaitingAgentOffer) {
        durationTimer.start();
      }
    } catch (err) {
      callError.value =
        err.name === 'NotAllowedError'
          ? t('WHATSAPP_CALL.MIC_DENIED')
          : t('WHATSAPP_CALL.CALL_FAILED');
      // eslint-disable-next-line no-console
      console.error('[WhatsApp Call] acceptCall error:', err);
      // Note: doAcceptCall already cleans up WebRTC resources on error
    } finally {
      isAccepting.value = false;
    }
  };

  const rejectCall = async call => {
    try {
      await WhatsappCallsAPI.reject(call.id);
    } catch {
      // Best effort
    } finally {
      callsStore.removeIncomingCall(call.callId);
    }
  };

  const endActiveCall = async () => {
    const call = activeCall.value;
    if (!call) return;

    // Only upload recording in legacy mode
    if (!call.serverRelay) {
      stopAndUploadRecording(call.id);
    }

    try {
      await WhatsappCallsAPI.terminate(call.id);
    } catch {
      // Best effort
    } finally {
      cleanupInboundWebRTC();
      cleanupOutboundCall();
      // Clear state directly — do NOT use handleCallEnded here since that is
      // meant for external events (ActionCable) and would invoke cleanupCallback
      // which would duplicate the cleanup we just performed.
      callsStore.clearActiveCall();
      durationTimer.stop();
      callDuration.value = 0;
    }
  };

  const toggleMute = () => {
    const stream = inboundStream || getOutboundCallState().stream;
    if (!stream) return;
    const audioTrack = stream.getAudioTracks()[0];
    if (!audioTrack) return;
    audioTrack.enabled = !audioTrack.enabled;
    isMuted.value = !audioTrack.enabled;
  };

  const dismissIncomingCall = call => {
    callsStore.removeIncomingCall(call.callId);
  };

  /**
   * Start the duration timer. Called externally after server-relay WebRTC
   * setup completes (handleAgentOffer).
   */
  const startDurationTimer = () => {
    durationTimer.start();
  };

  onUnmounted(() => {
    window.removeEventListener('beforeunload', handleBeforeUnload);
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
    isReconnecting,
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
