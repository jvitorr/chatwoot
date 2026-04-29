<script setup>
import { computed, ref } from 'vue';
import { useRouter } from 'vue-router';
import { useMessageContext } from '../provider.js';
import { MESSAGE_TYPES, VOICE_CALL_STATUS } from '../constants';
import { acceptVoiceCallById } from 'dashboard/composables/useVoiceCallSession';
import VoiceCallsAPI from 'dashboard/api/voiceCalls';

import Icon from 'dashboard/components-next/icon/Icon.vue';
import BaseBubble from 'next/message/bubbles/Base.vue';

const LABEL_MAP = {
  [VOICE_CALL_STATUS.IN_PROGRESS]: 'CONVERSATION.VOICE_CALL.CALL_IN_PROGRESS',
  [VOICE_CALL_STATUS.COMPLETED]: 'CONVERSATION.VOICE_CALL.CALL_ENDED',
};

const SUBTEXT_MAP = {
  [VOICE_CALL_STATUS.RINGING]: 'CONVERSATION.VOICE_CALL.NOT_ANSWERED_YET',
  [VOICE_CALL_STATUS.COMPLETED]: 'CONVERSATION.VOICE_CALL.CALL_ENDED',
};

const ICON_MAP = {
  [VOICE_CALL_STATUS.IN_PROGRESS]: 'i-ph-phone-call',
  [VOICE_CALL_STATUS.NO_ANSWER]: 'i-ph-phone-x',
  [VOICE_CALL_STATUS.FAILED]: 'i-ph-phone-x',
};

const BG_COLOR_MAP = {
  [VOICE_CALL_STATUS.IN_PROGRESS]: 'bg-n-teal-9',
  [VOICE_CALL_STATUS.RINGING]: 'bg-n-teal-9 animate-pulse',
  [VOICE_CALL_STATUS.COMPLETED]: 'bg-n-slate-11',
  [VOICE_CALL_STATUS.NO_ANSWER]: 'bg-n-ruby-9',
  [VOICE_CALL_STATUS.FAILED]: 'bg-n-ruby-9',
};

const router = useRouter();
const { contentAttributes, messageType, attachments } = useMessageContext();

// NOTE: contentAttributes.data keys are camelCase because MessageList.vue
// applies useCamelCase(messages, { deep: true }) before rendering.
const data = computed(() => contentAttributes.value?.data);
const status = computed(() => data.value?.status?.toString());

const isOutbound = computed(() => messageType.value === MESSAGE_TYPES.OUTGOING);
const isFailed = computed(() =>
  [VOICE_CALL_STATUS.NO_ANSWER, VOICE_CALL_STATUS.FAILED].includes(status.value)
);

// Call source and metadata — all camelCase due to deep transform
const callSource = computed(() => data.value?.callSource);
const isVoiceCall = computed(() =>
  ['whatsapp', 'twilio'].includes(callSource.value)
);
const callId = computed(() => data.value?.callId);
const acceptedBy = computed(() => data.value?.acceptedBy);
const durationSeconds = computed(() => data.value?.durationSeconds);

// Recording and transcript live on the first audio attachment. After the
// call ends, CallRecordingFetchJob creates an Attachment on this message;
// Messages::AudioTranscriptionService fills in `transcribedText` when ready.
const audioAttachment = computed(
  () => attachments.value?.find(a => a.fileType === 'audio') || null
);
const recordingUrl = computed(() => audioAttachment.value?.dataUrl);
const transcript = computed(() => audioAttachment.value?.transcribedText);
const isJoining = ref(false);
const isRejecting = ref(false);
const showTranscript = ref(false);

// Reject is shown only for ringing inbound calls — outbound calls and
// in-progress calls don't need a reject button (initiator hangs up via the
// floating widget).
const showRejectButton = computed(
  () =>
    isVoiceCall.value &&
    !isOutbound.value &&
    status.value === VOICE_CALL_STATUS.RINGING
);

const formattedDuration = computed(() => {
  const seconds = durationSeconds.value;
  if (!seconds || seconds <= 0) return '';
  const mins = Math.floor(seconds / 60);
  const secs = seconds % 60;
  return mins > 0 ? `${mins}m ${secs}s` : `${secs}s`;
});

// Show join/accept button logic
// Direct browser↔Meta WebRTC has no rejoin path (Meta caches the prior
// DTLS fingerprint), so only ringing calls show the Accept button.
const showJoinButton = computed(
  () => isVoiceCall.value && status.value === VOICE_CALL_STATUS.RINGING
);

const labelKey = computed(() => {
  if (LABEL_MAP[status.value]) return LABEL_MAP[status.value];
  if (status.value === VOICE_CALL_STATUS.RINGING) {
    return isOutbound.value
      ? 'CONVERSATION.VOICE_CALL.OUTGOING_CALL'
      : 'CONVERSATION.VOICE_CALL.INCOMING_CALL';
  }
  return isFailed.value
    ? 'CONVERSATION.VOICE_CALL.MISSED_CALL'
    : 'CONVERSATION.VOICE_CALL.INCOMING_CALL';
});

const subtextKey = computed(() => {
  // acceptedBy on outbound calls is the initiator, not the contact — so keep
  // "They answered" instead of "Answered by <agent>". Only inbound bubbles
  // should suppress the subtext in favor of the acceptedBy line.
  if (
    !isOutbound.value &&
    acceptedBy.value?.name &&
    [VOICE_CALL_STATUS.IN_PROGRESS, VOICE_CALL_STATUS.COMPLETED].includes(
      status.value
    )
  ) {
    return null;
  }

  if (SUBTEXT_MAP[status.value]) return SUBTEXT_MAP[status.value];
  if (status.value === VOICE_CALL_STATUS.IN_PROGRESS) {
    return isOutbound.value
      ? 'CONVERSATION.VOICE_CALL.THEY_ANSWERED'
      : 'CONVERSATION.VOICE_CALL.YOU_ANSWERED';
  }
  return isFailed.value
    ? 'CONVERSATION.VOICE_CALL.NO_ANSWER'
    : 'CONVERSATION.VOICE_CALL.NOT_ANSWERED_YET';
});

const answeredByText = computed(() => {
  if (isOutbound.value) return '';
  if (!acceptedBy.value?.name) return '';
  return acceptedBy.value.name;
});

const iconName = computed(() => {
  if (ICON_MAP[status.value]) return ICON_MAP[status.value];
  return isOutbound.value ? 'i-ph-phone-outgoing' : 'i-ph-phone-incoming';
});

const bgColor = computed(() => BG_COLOR_MAP[status.value] || 'bg-n-teal-9');

const handleJoinCall = async () => {
  if (isJoining.value || !isVoiceCall.value) return;
  isJoining.value = true;
  try {
    const result = await acceptVoiceCallById(callId.value);
    if (result?.success && result.call) {
      router.push({
        name: 'inbox_conversation',
        params: { conversation_id: result.call.conversationId },
      });
    }
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error('[Voice Call] Accept from bubble failed:', err);
  } finally {
    isJoining.value = false;
  }
};

const handleRejectCall = async () => {
  if (isRejecting.value || !callId.value) return;
  isRejecting.value = true;
  try {
    await VoiceCallsAPI.reject(callId.value);
  } catch (err) {
    // eslint-disable-next-line no-console
    console.error('[Voice Call] Reject from bubble failed:', err);
  } finally {
    isRejecting.value = false;
  }
};
</script>

<template>
  <BaseBubble class="p-0 border-none" hide-meta>
    <div class="flex overflow-hidden flex-col w-full max-w-xs">
      <div class="flex gap-3 items-center p-3 w-full">
        <div
          class="flex justify-center items-center rounded-full size-10 shrink-0"
          :class="bgColor"
        >
          <Icon
            class="size-5"
            :icon="iconName"
            :class="{
              'text-n-slate-1': status === VOICE_CALL_STATUS.COMPLETED,
              'text-white': status !== VOICE_CALL_STATUS.COMPLETED,
            }"
          />
        </div>

        <div class="flex overflow-hidden flex-col flex-grow gap-0.5">
          <span class="text-sm font-medium truncate text-n-slate-12">
            {{ $t(labelKey) }}
          </span>
          <span v-if="answeredByText" class="text-xs text-n-slate-11">
            {{
              $t('CONVERSATION.VOICE_CALL.ANSWERED_BY', {
                name: answeredByText,
              })
            }}
          </span>
          <span v-else-if="subtextKey" class="text-xs text-n-slate-11">
            {{ $t(subtextKey) }}
          </span>
          <span
            v-if="formattedDuration && status === VOICE_CALL_STATUS.COMPLETED"
            class="text-xs text-n-slate-10"
          >
            {{ formattedDuration }}
          </span>
        </div>

        <button
          v-if="showRejectButton"
          :disabled="isRejecting"
          :title="$t('WHATSAPP_CALL.REJECT')"
          class="flex justify-center items-center w-8 h-8 bg-n-ruby-9 hover:bg-n-ruby-10 rounded-full transition-colors shrink-0"
          :class="{ 'opacity-75 cursor-wait': isRejecting }"
          @click="handleRejectCall"
        >
          <i
            v-if="isRejecting"
            class="i-ph-circle-notch-bold text-sm text-white animate-spin"
          />
          <i v-else class="i-ph-phone-x-bold text-sm text-white" />
        </button>

        <button
          v-if="showJoinButton"
          :disabled="isJoining"
          class="flex items-center gap-1 px-3 py-1.5 text-xs font-medium text-white bg-n-teal-9 hover:bg-n-teal-10 rounded-lg transition-colors shrink-0"
          :class="{ 'opacity-75 cursor-wait': isJoining }"
          @click="handleJoinCall"
        >
          <i
            v-if="isJoining"
            class="i-ph-circle-notch-bold text-sm animate-spin"
          />
          <i v-else class="i-ph-phone-bold text-sm" />
          {{ $t('CONVERSATION.VOICE_CALL.ACCEPT_CALL') }}
        </button>
      </div>

      <div
        v-if="recordingUrl && status === VOICE_CALL_STATUS.COMPLETED"
        class="px-3 pb-2"
      >
        <audio controls class="w-full h-8" :src="recordingUrl">
          {{ $t('CONVERSATION.VOICE_CALL.AUDIO_NOT_SUPPORTED') }}
        </audio>
      </div>

      <div
        v-if="transcript && status === VOICE_CALL_STATUS.COMPLETED"
        class="px-3 pb-3"
      >
        <button
          class="flex items-center gap-1 text-xs text-n-slate-11 hover:text-n-slate-12 transition-colors"
          @click="showTranscript = !showTranscript"
        >
          <i
            class="text-sm"
            :class="
              showTranscript ? 'i-ph-caret-up-bold' : 'i-ph-caret-down-bold'
            "
          />
          {{ $t('CONVERSATION.VOICE_CALL.TRANSCRIPT') }}
        </button>
        <p
          v-if="showTranscript"
          class="mt-1 text-xs leading-relaxed text-n-slate-11 whitespace-pre-wrap"
        >
          {{ transcript }}
        </p>
      </div>
    </div>
  </BaseBubble>
</template>
