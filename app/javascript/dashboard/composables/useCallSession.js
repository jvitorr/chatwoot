import { computed, ref, watch, onUnmounted, onMounted } from 'vue';
import { useStore } from 'vuex';
import VoiceAPI from 'dashboard/api/channel/voice/voiceAPIClient';
import TwilioVoiceClient from 'dashboard/api/channel/voice/twilioVoiceClient';
import { useCallsStore } from 'dashboard/stores/calls';
import {
  useWhatsappCallSession,
  sendWhatsappTerminateBeacon,
  cleanupWhatsappSession,
} from 'dashboard/composables/useWhatsappCallSession';
import { handleVoiceCallCreated } from 'dashboard/helper/voice';
import Timer from 'dashboard/helper/Timer';

const isWhatsappCall = call => call?.provider === 'whatsapp';

export function useCallSession() {
  const store = useStore();
  const callsStore = useCallsStore();
  const whatsappSession = useWhatsappCallSession();
  const isJoining = ref(false);
  const callDuration = ref(0);
  const durationTimer = new Timer(elapsed => {
    callDuration.value = elapsed;
  });

  const activeCall = computed(() => callsStore.activeCall);
  const incomingCalls = computed(() => callsStore.incomingCalls);
  const hasActiveCall = computed(() => callsStore.hasActiveCall);
  const hasIncomingCall = computed(() => callsStore.hasIncomingCall);

  watch(
    hasActiveCall,
    active => {
      if (active) {
        durationTimer.start();
      } else {
        durationTimer.stop();
        callDuration.value = 0;
      }
    },
    { immediate: true }
  );

  // Warn before a refresh/close drops a live or ringing call. Cable events
  // aren't replayed on reconnect, so a confirmed refresh during ringing would
  // leave the agent unable to accept; for active calls the WebRTC session
  // dies outright (no rejoin path).
  const handleBeforeUnload = event => {
    if (!hasActiveCall.value && !hasIncomingCall.value) return;
    event.preventDefault();
    event.returnValue = '';
  };

  // Cable broadcasts (voice_call.incoming / message.created) are one-shot, so
  // on a hard refresh they leave the calls store empty. Seed it from any
  // ringing voice_call message in the conversation cache.
  const seedCallsFromHydratedMessages = () => {
    const conversations = store.getters.getAllConversations || [];
    const currentUserId = store.getters.getCurrentUserID;
    conversations.forEach(conv => {
      (conv.messages || []).forEach(msg => {
        if (msg.content_type !== 'voice_call') return;
        if (msg.call?.status !== 'ringing') return;
        handleVoiceCallCreated(msg, currentUserId);
      });
    });
  };

  // Terminate only the active call — ringing calls stay alive on Meta so the
  // agent can pick them up after reload (seeded back via the watcher above).
  const handlePageHide = () => {
    sendWhatsappTerminateBeacon();
  };

  const handleTwilioDisconnected = () => callsStore.clearActiveCall();

  onMounted(() => {
    TwilioVoiceClient.addEventListener(
      'call:disconnected',
      handleTwilioDisconnected
    );
    window.addEventListener('beforeunload', handleBeforeUnload);
    window.addEventListener('pagehide', handlePageHide);
    seedCallsFromHydratedMessages();
  });

  // Re-seed when conversations stream in after mount; addCall merges by callSid.
  watch(
    () => store.getters.getAllConversations?.length,
    () => seedCallsFromHydratedMessages()
  );

  onUnmounted(() => {
    durationTimer.stop();
    TwilioVoiceClient.removeEventListener(
      'call:disconnected',
      handleTwilioDisconnected
    );
    window.removeEventListener('beforeunload', handleBeforeUnload);
    window.removeEventListener('pagehide', handlePageHide);
  });

  const findCall = callSid => callsStore.calls.find(c => c.callSid === callSid);

  const endCall = async ({ conversationId, inboxId, callSid }) => {
    if (isWhatsappCall(findCall(callSid))) {
      await whatsappSession.endActiveCall();
      durationTimer.stop();
      callsStore.clearActiveCall();
      return;
    }

    await VoiceAPI.leaveConference({ inboxId, conversationId, callSid });
    TwilioVoiceClient.endClientCall();
    durationTimer.stop();
    callsStore.clearActiveCall();
  };

  const joinCall = async ({ conversationId, inboxId, callSid }) => {
    if (isJoining.value) return null;

    isJoining.value = true;
    try {
      const call = findCall(callSid);
      if (isWhatsappCall(call)) {
        await whatsappSession.acceptIncomingCall({
          callId: call.callId,
          sdpOffer: call.sdpOffer,
          iceServers: call.iceServers,
        });
        callsStore.setCallActive(callSid);
        durationTimer.start();
        return { callId: call.callId };
      }

      const device = await TwilioVoiceClient.initializeDevice(inboxId);
      if (!device) return null;

      const joinResponse = await VoiceAPI.joinConference({
        conversationId,
        inboxId,
        callSid,
      });

      await TwilioVoiceClient.joinClientCall({
        to: joinResponse?.conference_sid,
        conversationId,
        callSid,
      });

      callsStore.setCallActive(callSid);
      durationTimer.start();

      return { conferenceSid: joinResponse?.conference_sid };
    } catch (error) {
      // eslint-disable-next-line no-console
      console.error('Failed to join call:', error);
      // Drop any half-built WebRTC state so the next click starts fresh.
      cleanupWhatsappSession();
      return null;
    } finally {
      isJoining.value = false;
    }
  };

  const rejectIncomingCall = callSid => {
    const call = findCall(callSid);
    if (isWhatsappCall(call) && call?.callId) {
      whatsappSession.rejectIncomingCall(call.callId);
    } else {
      TwilioVoiceClient.endClientCall();
    }
    callsStore.dismissCall(callSid);
  };

  const dismissCall = callSid => {
    callsStore.dismissCall(callSid);
  };

  const formattedCallDuration = computed(() => {
    const minutes = Math.floor(callDuration.value / 60);
    const seconds = callDuration.value % 60;
    return `${minutes.toString().padStart(2, '0')}:${seconds.toString().padStart(2, '0')}`;
  });

  return {
    activeCall,
    incomingCalls,
    hasActiveCall,
    isJoining,
    formattedCallDuration,
    joinCall,
    endCall,
    rejectIncomingCall,
    dismissCall,
  };
}
