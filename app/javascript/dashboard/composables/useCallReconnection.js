import { onMounted } from 'vue';
import { useI18n } from 'vue-i18n';
import { useVoiceCallsStore } from 'dashboard/stores/voiceCalls';
import VoiceCallsAPI from 'dashboard/api/voiceCalls';
import { useAlert } from 'dashboard/composables';

/**
 * Detects a stale active call on page load and cleans it up. Direct
 * browser ↔ Meta WebRTC has no rejoin path — Meta caches the prior DTLS
 * fingerprint, so a fresh PC can never re-bind to the existing call leg.
 * Best we can do is terminate the stranded Call so the agent isn't shown
 * "in a call" forever.
 */
export function useCallReconnection() {
  const callsStore = useVoiceCallsStore();
  const { t } = useI18n();

  onMounted(async () => {
    if (callsStore.hasActiveCall || callsStore.hasIncomingCall) return;

    try {
      const { data } = await VoiceCallsAPI.active();
      if (!data?.call && !data?.id) return;

      const activeCallData = data.call || data;
      try {
        await VoiceCallsAPI.terminate(activeCallData.id);
      } catch {
        // best-effort — Rails-side cleanup
      }
      useAlert(t('WHATSAPP_CALL.RELOAD_ENDED_CALL'));
    } catch {
      callsStore.clearActiveCall();
    }
  });
}
