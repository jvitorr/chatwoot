/* global axios */
import ApiClient from './ApiClient';

class VoiceCallsAPI extends ApiClient {
  constructor() {
    super('voice_calls', { accountScoped: true });
  }

  show(callId) {
    return axios.get(`${this.url}/${callId}`);
  }

  // The browser does WebRTC locally and ships the SDP answer up. Rails forwards
  // it to Meta via pre_accept_call+accept_call.
  accept(callId, { sdpAnswer } = {}) {
    return axios.post(`${this.url}/${callId}/accept`, {
      sdp_answer: sdpAnswer,
    });
  }

  reject(callId) {
    return axios.post(`${this.url}/${callId}/reject`);
  }

  terminate(callId) {
    return axios.post(`${this.url}/${callId}/terminate`);
  }

  // Outbound: browser builds the offer first; Rails ships it to Meta and
  // creates the Call record. Meta delivers its SDP answer later via the
  // connect webhook (broadcast over ActionCable as voice_call.outbound_connected).
  initiate(conversationId, provider, { sdpOffer } = {}) {
    return axios.post(`${this.url}/initiate`, {
      conversation_id: conversationId,
      provider,
      sdp_offer: sdpOffer,
    });
  }

  // Get the current agent's active call (if any). Used on page load to detect
  // a stale active session so we can terminate it cleanly.
  active() {
    return axios.get(`${this.url}/active`);
  }

  // Multipart upload of the in-browser MediaRecorder Blob to Rails. The
  // controller attaches it to the call's voice_call message; the after-create
  // hook on Attachment fires Messages::AudioTranscriptionJob automatically.
  uploadRecording(callId, blob, filename) {
    const fd = new FormData();
    fd.append('recording', blob, filename);
    return axios.post(`${this.url}/${callId}/upload_recording`, fd, {
      headers: { 'Content-Type': 'multipart/form-data' },
    });
  }

  // URL helpers for navigator.sendBeacon (which can't carry custom headers and
  // needs the absolute account-scoped path).
  uploadRecordingUrl(callId) {
    return `${this.url}/${callId}/upload_recording`;
  }

  terminateUrl(callId) {
    return `${this.url}/${callId}/terminate`;
  }
}

export default new VoiceCallsAPI();
