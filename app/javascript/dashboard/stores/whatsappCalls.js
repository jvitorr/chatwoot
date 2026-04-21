import { defineStore } from 'pinia';

// Module-scoped (non-reactive) state for outbound call WebRTC objects.
// These cannot be in Pinia state because RTCPeerConnection/MediaStream are not serializable.
// Used ONLY in legacy (browser-direct) mode. In server-relay mode outbound calls
// go through the same inbound WebRTC path via handleAgentOffer.
const outboundCall = { pc: null, stream: null, audio: null, callId: null };

export function getOutboundCallState() {
  return outboundCall;
}

export function setOutboundCallProperty(key, value) {
  outboundCall[key] = value;
}

export function cleanupOutboundCall() {
  if (outboundCall.pc) outboundCall.pc.close();
  if (outboundCall.stream) {
    outboundCall.stream.getTracks().forEach(t => t.stop());
  }
  if (outboundCall.audio) {
    outboundCall.audio.srcObject = null;
    outboundCall.audio.remove();
  }
  outboundCall.pc = null;
  outboundCall.stream = null;
  outboundCall.audio = null;
  outboundCall.callId = null;
}

export const useWhatsappCallsStore = defineStore('whatsappCalls', {
  state: () => ({
    // Incoming ringing calls waiting for agent action
    incomingCalls: [],
    // The single active call (accepted + audio connected)
    activeCall: null,
    // Cleanup callback registered by the composable — called when a call ends externally
    cleanupCallback: null,
    // True while the agent is reconnecting to an active call after page reload
    isReconnecting: false,
    // Seconds already elapsed when reconnecting — timer resumes from this offset
    callTimerOffset: 0,
  }),

  getters: {
    hasIncomingCall: state => state.incomingCalls.length > 0,
    hasActiveCall: state => state.activeCall !== null,
    hasWhatsappCall: state =>
      state.incomingCalls.length > 0 || state.activeCall !== null,
    firstIncomingCall: state => state.incomingCalls[0] || null,

    // Returns true when the active call is operating through the media server
    // (server-relay mode). Detected by the absence of sdpOffer in the call data
    // — in legacy mode the incoming call ActionCable event includes sdpOffer.
    isMediaServerEnabled() {
      return this.activeCall?.serverRelay === true;
    },
  },

  actions: {
    addIncomingCall(callData) {
      const exists = this.incomingCalls.some(c => c.callId === callData.callId);
      if (exists) return;
      this.incomingCalls.push(callData);
    },

    removeIncomingCall(callId) {
      this.incomingCalls = this.incomingCalls.filter(c => c.callId !== callId);
    },

    setActiveCall(callData) {
      this.activeCall = callData;
    },

    clearActiveCall() {
      this.activeCall = null;
      this.callTimerOffset = 0;
      this.isReconnecting = false;
    },

    markActiveCallConnected() {
      if (this.activeCall) {
        this.activeCall = { ...this.activeCall, status: 'connected' };
      }
    },

    registerCleanupCallback(callback) {
      this.cleanupCallback = callback;
    },

    setReconnecting(value) {
      this.isReconnecting = value;
    },

    setTimerOffset(seconds) {
      this.callTimerOffset = seconds;
    },

    handleCallAcceptedByOther(callId) {
      this.removeIncomingCall(callId);
    },

    handleCallEnded(callId) {
      this.removeIncomingCall(callId);
      if (this.activeCall?.callId === callId) {
        // Invoke cleanup BEFORE clearing activeCall so the callback can
        // check isMediaServerEnabled (which depends on activeCall.serverRelay)
        if (this.cleanupCallback) {
          this.cleanupCallback();
        }
        this.activeCall = null;
        this.callTimerOffset = 0;
        this.isReconnecting = false;
      }
      if (outboundCall.callId === callId) {
        cleanupOutboundCall();
      }
    },
  },
});
