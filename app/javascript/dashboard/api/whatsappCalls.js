/* global axios */
import ApiClient from './ApiClient';

class WhatsappCallsAPI extends ApiClient {
  constructor() {
    super('whatsapp_calls', { accountScoped: true });
  }

  show(callId) {
    return axios.get(`${this.url}/${callId}`);
  }

  // Accept a ringing call. sdpAnswer is optional — omitted in server-relay mode
  // where the media server handles WebRTC negotiation.
  accept(callId, sdpAnswer) {
    const body = sdpAnswer ? { sdp_answer: sdpAnswer } : {};
    return axios.post(`${this.url}/${callId}/accept`, body);
  }

  reject(callId) {
    return axios.post(`${this.url}/${callId}/reject`);
  }

  terminate(callId) {
    return axios.post(`${this.url}/${callId}/terminate`);
  }

  // Initiate an outbound call. sdpOffer is optional — omitted in server-relay
  // mode where the media server generates the SDP offer for Meta.
  initiate(conversationId, sdpOffer) {
    const body = { conversation_id: conversationId };
    if (sdpOffer) body.sdp_offer = sdpOffer;
    return axios.post(`${this.url}/initiate`, body);
  }

  // Send the agent's SDP answer for the Peer B connection (server-relay mode).
  agentAnswer(callId, sdpAnswer) {
    return axios.post(`${this.url}/${callId}/agent_answer`, {
      sdp_answer: sdpAnswer,
    });
  }

  // Get the current agent's active call (if any). Used for reconnection on page load.
  active() {
    return axios.get(`${this.url}/active`);
  }

  // Reconnect to an active call after page reload. Server creates a new Peer B
  // and returns a fresh SDP offer via ActionCable.
  reconnect(callId) {
    return axios.post(`${this.url}/${callId}/reconnect`);
  }

  // Join an existing call as a supervisor (listen-only by default).
  join(callId, role = 'listen_only') {
    return axios.post(`${this.url}/${callId}/join`, { role });
  }

  // Play an audio file to the caller via the media server.
  playAudio(callId, { filePath, mode = 'replace', loop = false }) {
    return axios.post(`${this.url}/${callId}/play_audio`, {
      file_path: filePath,
      mode,
      loop,
    });
  }

  // Legacy: upload browser-side recording. Deprecated when media server is enabled.
  uploadRecording(callId, blob) {
    const formData = new FormData();
    formData.append('recording', blob, `call-${callId}.webm`);
    return axios.post(`${this.url}/${callId}/upload_recording`, formData, {
      headers: { 'Content-Type': 'multipart/form-data' },
    });
  }
}

export default new WhatsappCallsAPI();
