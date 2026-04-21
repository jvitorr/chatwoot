import { onMounted, computed } from 'vue';
import { useWhatsappCallsStore } from 'dashboard/stores/whatsappCalls';
import WhatsappCallsAPI from 'dashboard/api/whatsappCalls';

/**
 * Checks for an active WhatsApp call on page load and reconnects if found.
 * This handles the server-relay scenario where the call persists on the media
 * server even after the agent's browser reloads.
 *
 * NOTE: This composable intentionally does NOT call useWhatsappCallSession()
 * to avoid creating duplicate side effects (beforeunload handlers, cleanup
 * callbacks, timers). The WhatsappCallWidget owns the useWhatsappCallSession
 * instance. This composable only sets store state and triggers the reconnect
 * API call — the actual WebRTC setup happens when the ActionCable agent_offer
 * event arrives and is handled by handleAgentOffer.
 *
 * Usage: call `useCallReconnection()` in the app-level layout component that
 * mounts once on page load.
 */
export function useCallReconnection() {
  const callsStore = useWhatsappCallsStore();

  const isReconnecting = computed(() => callsStore.isReconnecting);

  onMounted(async () => {
    // Skip if there's already an active or incoming call in the store
    if (callsStore.hasActiveCall || callsStore.hasIncomingCall) return;

    try {
      const { data } = await WhatsappCallsAPI.active();
      if (!data?.call) return;

      const activeCallData = data.call;

      callsStore.setReconnecting(true);
      callsStore.setActiveCall({
        id: activeCallData.id,
        callId: activeCallData.call_id,
        direction: activeCallData.direction,
        conversationId: activeCallData.conversation_id,
        status: 'reconnecting',
        serverRelay: true,
        caller: activeCallData.caller,
      });

      // Set timer offset so the timer resumes from the correct elapsed time
      if (activeCallData.elapsed_seconds) {
        callsStore.setTimerOffset(activeCallData.elapsed_seconds);
      }

      // Tell the server to create a new Peer B and send us a fresh SDP offer.
      // The server will broadcast whatsapp_call.agent_offer via ActionCable,
      // which is handled by handleAgentOffer in actionCable.js.
      await WhatsappCallsAPI.reconnect(activeCallData.id);
    } catch {
      // No active call or API/reconnect error — clear state and silent fail.
      // clearActiveCall() also resets isReconnecting and callTimerOffset.
      callsStore.clearActiveCall();
    }
  });

  return { isReconnecting };
}
