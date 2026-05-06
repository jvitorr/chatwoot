<script setup>
import { computed } from 'vue';
import { useI18n } from 'vue-i18n';
import { useStore } from 'vuex';
import { useMessageContext } from '../provider.js';
import { VOICE_CALL_STATUS } from '../constants';
import { useCallActions } from 'dashboard/composables/useCallSession';
import { formatDuration } from 'shared/helpers/timeHelper';

import Icon from 'dashboard/components-next/icon/Icon.vue';
import BaseBubble from 'next/message/bubbles/Base.vue';
import AudioChip from 'next/message/chips/Audio.vue';

const LABEL_MAP = {
  [VOICE_CALL_STATUS.IN_PROGRESS]: 'CONVERSATION.VOICE_CALL.CALL_IN_PROGRESS',
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

const { t } = useI18n();
const store = useStore();
const {
  call,
  attachments,
  contentAttributes,
  conversationId,
  currentUserId,
  inboxId,
} = useMessageContext();
// Lightweight consumer — bubble doesn't own global listeners; the
// FloatingCallWidget is the singleton root that drives the session.
const { joinCall, endCall, activeCall, hasActiveCall, isJoining } =
  useCallActions();

const status = computed(() => call.value?.status);
const isOutbound = computed(() => call.value?.direction === 'outgoing');
const isFailed = computed(() =>
  [VOICE_CALL_STATUS.NO_ANSWER, VOICE_CALL_STATUS.FAILED].includes(status.value)
);
const acceptedByAgentId = computed(() => call.value?.acceptedByAgentId);
const didCurrentUserAnswer = computed(
  () =>
    !!acceptedByAgentId.value && acceptedByAgentId.value === currentUserId.value
);
// Pickup auto-assigns the conversation, so the assignee is a safe display proxy
// for the answerer when the Call payload lacks accepted_by_agent_id (e.g.,
// Twilio's call-status webhook flipped the call to in-progress before the
// participant-join webhook claimed it).
const conversationAssignee = computed(() => {
  const conversation = store.getters.getConversationById?.(
    conversationId?.value
  );
  return conversation?.meta?.assignee || null;
});
const displayAgentName = computed(() => {
  if (call.value?.acceptedByAgentName) return call.value.acceptedByAgentName;
  if (acceptedByAgentId.value) {
    const agent = store.getters['agents/getAgentById'](acceptedByAgentId.value);
    if (agent?.available_name) return agent.available_name;
    if (agent?.name) return agent.name;
  }
  return conversationAssignee.value?.name || null;
});

const audioAttachment = computed(() =>
  (attachments?.value || []).find(a => a.fileType === 'audio')
);

// Duration may arrive on call.duration_seconds (push_event_data) or
// content_attributes.data.duration_seconds — and either may be camelCased
// upstream, so check every variant.
const durationSeconds = computed(() => {
  const fromCall = call.value?.durationSeconds || call.value?.duration_seconds;
  if (fromCall != null) return fromCall;

  const data = contentAttributes?.value?.data;
  return data?.durationSeconds || data?.duration_seconds;
});

const formattedDuration = computed(() => formatDuration(durationSeconds.value));

const labelKey = computed(() => {
  if (LABEL_MAP[status.value]) return LABEL_MAP[status.value];
  if (status.value === VOICE_CALL_STATUS.RINGING) {
    return isOutbound.value
      ? 'CONVERSATION.VOICE_CALL.OUTGOING_CALL'
      : 'CONVERSATION.VOICE_CALL.INCOMING_CALL';
  }
  if (isFailed.value) {
    return isOutbound.value
      ? 'CONVERSATION.VOICE_CALL.NO_ANSWER_OUTBOUND_LABEL'
      : 'CONVERSATION.VOICE_CALL.MISSED_CALL';
  }
  return 'CONVERSATION.VOICE_CALL.INCOMING_CALL';
});

const subtext = computed(() => {
  if (status.value === VOICE_CALL_STATUS.RINGING) {
    return isOutbound.value
      ? t('CONVERSATION.VOICE_CALL.CALLING')
      : t('CONVERSATION.VOICE_CALL.NOT_ANSWERED_YET');
  }
  if (status.value === VOICE_CALL_STATUS.COMPLETED) {
    return formattedDuration.value;
  }
  if (status.value === VOICE_CALL_STATUS.IN_PROGRESS) {
    // Outbound calls can flip to in-progress before the contact actually
    // picks up (e.g., Twilio marks in-progress when the agent joins the
    // conference); claiming "they answered" here would be misleading. The
    // 'Call in progress' label alone is accurate; the floating widget shows
    // the live duration.
    if (isOutbound.value) return null;
    if (didCurrentUserAnswer.value) {
      return t('CONVERSATION.VOICE_CALL.YOU_ANSWERED');
    }
    if (displayAgentName.value) {
      return t('CONVERSATION.VOICE_CALL.AGENT_ANSWERED', {
        agentName: displayAgentName.value,
      });
    }
    return null;
  }
  if (isFailed.value) {
    return isOutbound.value
      ? t('CONVERSATION.VOICE_CALL.NO_ANSWER_OUTBOUND_SUBTEXT')
      : t('CONVERSATION.VOICE_CALL.MISSED_CALL_INBOUND_SUBTEXT');
  }
  return t('CONVERSATION.VOICE_CALL.NOT_ANSWERED_YET');
});

const iconName = computed(() => {
  if (ICON_MAP[status.value]) return ICON_MAP[status.value];
  return isOutbound.value ? 'i-ph-phone-outgoing' : 'i-ph-phone-incoming';
});

const bgColor = computed(() => BG_COLOR_MAP[status.value] || 'bg-n-teal-9');

const callSid = computed(() => call.value?.providerCallId);

// Show "Join call" when the call is still ringing, no agent has claimed it,
// and the conversation is unassigned or assigned to the current user. Mirrors
// the eligibility used by FloatingCallWidget so the bubble can act as a
// recovery affordance after a refresh or missed widget.
const canJoinCall = computed(() => {
  if (status.value !== VOICE_CALL_STATUS.RINGING) return false;
  if (isOutbound.value) return false;
  if (acceptedByAgentId.value) return false;
  if (!callSid.value || !inboxId.value || !conversationId.value) return false;
  // Suppress the button once this call is the local active session — the
  // message status webhook may lag behind, so we can't rely on `status` alone
  // to hide it after a successful join from this client.
  if (hasActiveCall.value && activeCall.value?.callSid === callSid.value)
    return false;
  const assignee = conversationAssignee.value;
  if (assignee?.id && assignee.id !== currentUserId.value) return false;
  return true;
});

const recordingAttachment = computed(() => {
  if (audioAttachment.value) return audioAttachment.value;
  const url = call.value?.recordingUrl;
  if (!url) return null;
  return {
    dataUrl: url,
    fileType: 'audio',
    extension: 'wav',
    transcribedText: call.value?.transcript || '',
  };
});

const handleJoinCall = async () => {
  if (!canJoinCall.value || isJoining.value) return;

  if (hasActiveCall.value && activeCall.value?.callSid !== callSid.value) {
    await endCall({
      conversationId: activeCall.value.conversationId,
      inboxId: activeCall.value.inboxId,
      callSid: activeCall.value.callSid,
    });
  }

  await joinCall({
    conversationId: conversationId.value,
    inboxId: inboxId.value,
    callSid: callSid.value,
  });
};
</script>

<template>
  <BaseBubble class="p-0 border-none" hide-meta>
    <div class="flex overflow-hidden flex-col w-full max-w-sm">
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

        <div class="flex overflow-hidden flex-col flex-grow">
          <span class="text-sm font-medium truncate text-n-slate-12">
            {{ $t(labelKey) }}
          </span>
          <span v-if="subtext" class="text-xs text-n-slate-11">
            {{ subtext }}
          </span>
          <button
            v-if="canJoinCall"
            type="button"
            class="p-0 mt-1 text-xs font-medium text-start text-n-teal-10 hover:text-n-teal-11 disabled:opacity-50"
            :disabled="isJoining"
            @click="handleJoinCall"
          >
            {{ $t('CONVERSATION.VOICE_CALL.JOIN_CALL') }}
          </button>
        </div>
      </div>

      <div v-if="recordingAttachment" class="px-3 pb-3 w-full">
        <AudioChip :attachment="recordingAttachment" class="text-n-slate-12" />
      </div>
    </div>
  </BaseBubble>
</template>
