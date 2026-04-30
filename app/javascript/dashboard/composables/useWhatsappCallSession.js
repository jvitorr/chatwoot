import { ref } from 'vue';
import WhatsappCallsAPI from 'dashboard/api/channel/whatsapp/whatsappCallsAPI';

// Browser ↔ Meta WebRTC is a singleton — only one PeerConnection at a time can
// hold the user's mic. Module-level state lets cable handlers and the pagehide
// listener reach the live session without prop-drilling refs through composables.
let pc = null;
let localStream = null;
let remoteStream = null;
let mediaRecorder = null;
let recorderChunks = [];
let audioContext = null;
let activeCallId = null;
let intentionallyClosing = false;

const RECORDING_TIMESLICE_MS = 5000;
const ICE_GATHER_TIMEOUT_MS = 10000;
const RECORDER_MIME_CANDIDATES = [
  'audio/webm;codecs=opus',
  'audio/webm',
  'audio/ogg;codecs=opus',
];

const waitForIceGatheringComplete = peer =>
  new Promise(resolve => {
    if (peer.iceGatheringState === 'complete') {
      resolve();
      return;
    }
    const timer = setTimeout(resolve, ICE_GATHER_TIMEOUT_MS);
    peer.addEventListener('icegatheringstatechange', () => {
      if (peer.iceGatheringState === 'complete') {
        clearTimeout(timer);
        resolve();
      }
    });
  });

const cleanup = () => {
  if (mediaRecorder && mediaRecorder.state !== 'inactive') {
    try {
      mediaRecorder.stop();
    } catch (_) {
      /* noop */
    }
  }
  if (audioContext && audioContext.state !== 'closed') {
    audioContext.close().catch(() => {});
  }
  if (localStream) localStream.getTracks().forEach(t => t.stop());
  if (remoteStream) remoteStream.getTracks().forEach(t => t.stop());
  if (pc) pc.close();

  pc = null;
  localStream = null;
  remoteStream = null;
  mediaRecorder = null;
  recorderChunks = [];
  audioContext = null;
  activeCallId = null;
  intentionallyClosing = false;
};

const buildPeerConnection = iceServers => {
  const config = iceServers && iceServers.length ? { iceServers } : {};
  pc = new RTCPeerConnection(config);
  remoteStream = new MediaStream();
  pc.ontrack = event => {
    event.streams.forEach(stream =>
      stream.getTracks().forEach(track => remoteStream.addTrack(track))
    );
  };
  return pc;
};

// Mix local mic + remote audio via Web Audio so the recording captures both legs.
const setupRecorder = () => {
  if (!localStream || !remoteStream || mediaRecorder) return;

  audioContext = new AudioContext({ sampleRate: 48000 });
  const destination = audioContext.createMediaStreamDestination();
  audioContext.createMediaStreamSource(localStream).connect(destination);
  audioContext.createMediaStreamSource(remoteStream).connect(destination);

  const mimeType = RECORDER_MIME_CANDIDATES.find(t =>
    MediaRecorder.isTypeSupported(t)
  );
  if (!mimeType) return;

  recorderChunks = [];
  mediaRecorder = new MediaRecorder(destination.stream, { mimeType });
  mediaRecorder.ondataavailable = event => {
    if (event.data && event.data.size > 0) recorderChunks.push(event.data);
  };
  mediaRecorder.start(RECORDING_TIMESLICE_MS);
};

const stopRecorderAndUpload = async callId => {
  if (mediaRecorder && mediaRecorder.state !== 'inactive') {
    await new Promise(resolve => {
      mediaRecorder.addEventListener('stop', resolve, { once: true });
      try {
        mediaRecorder.stop();
      } catch (_) {
        resolve();
      }
    });
  }
  if (!recorderChunks.length || !callId) return;

  const blob = new Blob(recorderChunks, { type: recorderChunks[0].type });
  try {
    await WhatsappCallsAPI.uploadRecording(callId, blob);
  } catch (_) {
    /* best-effort — server-side idempotency guard handles a retry */
  }
};

export function useWhatsappCallSession() {
  const isInitiating = ref(false);
  const error = ref(null);

  const prepareInboundAnswer = async (sdpOffer, iceServers) => {
    cleanup();
    localStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    buildPeerConnection(iceServers);
    localStream.getTracks().forEach(t => pc.addTrack(t, localStream));
    await pc.setRemoteDescription({ type: 'offer', sdp: sdpOffer });
    const answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    await waitForIceGatheringComplete(pc);
    setupRecorder();
    return pc.localDescription.sdp;
  };

  const prepareOutboundOffer = async () => {
    cleanup();
    localStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    buildPeerConnection();
    localStream.getTracks().forEach(t => pc.addTrack(t, localStream));
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    await waitForIceGatheringComplete(pc);
    return pc.localDescription.sdp;
  };

  const acceptIncomingCall = async ({ callId, sdpOffer, iceServers }) => {
    const sdpAnswer = await prepareInboundAnswer(sdpOffer, iceServers);
    activeCallId = callId;
    await WhatsappCallsAPI.accept(callId, sdpAnswer);
  };

  const rejectIncomingCall = async callId => {
    intentionallyClosing = true;
    try {
      await WhatsappCallsAPI.reject(callId);
    } finally {
      cleanup();
    }
  };

  const initiateOutboundCall = async conversationId => {
    if (isInitiating.value) return null;
    isInitiating.value = true;
    error.value = null;
    try {
      const sdpOffer = await prepareOutboundOffer();
      const response = await WhatsappCallsAPI.initiate(
        conversationId,
        sdpOffer
      );
      // Permission flow returns no call id — let the caller render the banner.
      activeCallId = response?.id || null;
      return response;
    } catch (e) {
      cleanup();
      error.value = e;
      throw e;
    } finally {
      isInitiating.value = false;
    }
  };

  const endActiveCall = async () => {
    if (!activeCallId) {
      cleanup();
      return;
    }
    intentionallyClosing = true;
    const callIdSnapshot = activeCallId;
    try {
      await stopRecorderAndUpload(callIdSnapshot);
      await WhatsappCallsAPI.terminate(callIdSnapshot).catch(() => {});
    } finally {
      cleanup();
    }
  };

  return {
    isInitiating,
    error,
    prepareInboundAnswer,
    prepareOutboundOffer,
    acceptIncomingCall,
    rejectIncomingCall,
    initiateOutboundCall,
    endActiveCall,
  };
}

// Cable handlers fire outside any composable instance; expose the shared session
// surface so they can apply the outbound answer onto the live PeerConnection.
export const applyOutboundAnswer = async (callId, sdpAnswer) => {
  if (!pc) return;
  activeCallId = callId;
  await pc.setRemoteDescription({ type: 'answer', sdp: sdpAnswer });
  setupRecorder();
};

export const hasActiveWhatsappCall = () => Boolean(activeCallId);

// Used by the calls store to tear down the WebRTC session when a WhatsApp call
// is removed by a cable end-event (the other side hung up).
export const cleanupWhatsappSession = () => cleanup();

// Best-effort terminate when the tab actually closes after the beforeunload prompt.
export const sendWhatsappTerminateBeacon = () => {
  if (!activeCallId || intentionallyClosing) return;
  const accountId = window.location.pathname.split('/')[3];
  if (!accountId) return;
  const url = `/api/v1/accounts/${accountId}/whatsapp_calls/${activeCallId}/terminate`;
  try {
    navigator.sendBeacon(url);
  } catch (_) {
    /* noop */
  }
};
