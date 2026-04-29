import { defineStore } from 'pinia';

export const useVoiceCallsStore = defineStore('voiceCalls', {
  state: () => ({
    // Incoming ringing calls waiting for agent action (per account)
    incomingCalls: [],
    // The single active call (accepted + audio connected)
    activeCall: null,
    // Cleanup callback registered by the composable — called when a call ends externally
    cleanupCallback: null,
  }),

  getters: {
    hasIncomingCall: state => state.incomingCalls.length > 0,
    hasActiveCall: state => state.activeCall !== null,
    hasVoiceCall: state =>
      state.incomingCalls.length > 0 || state.activeCall !== null,
    firstIncomingCall: state => state.incomingCalls[0] || null,
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
    },

    markActiveCallConnected() {
      if (this.activeCall) {
        this.activeCall = { ...this.activeCall, status: 'connected' };
      }
    },

    registerCleanupCallback(callback) {
      this.cleanupCallback = callback;
    },

    handleCallAcceptedByOther(callId) {
      this.removeIncomingCall(callId);
    },

    handleCallEnded(callId) {
      this.removeIncomingCall(callId);
      if (this.activeCall?.callId === callId) {
        // Snapshot the DB id before nulling activeCall so the composable can
        // POST upload_recording with the right path even after we clear state.
        const dbCallId = this.activeCall?.id;
        if (this.cleanupCallback) this.cleanupCallback(dbCallId);
        this.activeCall = null;
      }
    },
  },
});
