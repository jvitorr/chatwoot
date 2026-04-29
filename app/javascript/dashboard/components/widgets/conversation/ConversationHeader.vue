<script setup>
import { computed, ref } from 'vue';
import { useRoute } from 'vue-router';
import { useStore } from 'vuex';
import { useElementSize } from '@vueuse/core';
import BackButton from '../BackButton.vue';
import InboxName from '../InboxName.vue';
import MoreActions from './MoreActions.vue';
import Avatar from 'next/avatar/Avatar.vue';
import SLACardLabel from './components/SLACardLabel.vue';
import wootConstants from 'dashboard/constants/globals';
import { conversationListPageURL } from 'dashboard/helper/URLHelper';
import { snoozedReopenTime } from 'dashboard/helper/snoozeHelpers';
import { useInbox } from 'dashboard/composables/useInbox';
import { useI18n } from 'vue-i18n';
import VoiceCallsAPI from 'dashboard/api/voiceCalls';
import { emitter } from 'shared/helpers/mitt';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { useVoiceCallsStore } from 'dashboard/stores/voiceCalls';
import {
  prepareOutboundOffer,
  cleanupInboundWebRTC,
} from 'dashboard/composables/useVoiceCallSession';

const props = defineProps({
  chat: {
    type: Object,
    default: () => ({}),
  },
  showBackButton: {
    type: Boolean,
    default: false,
  },
});

const { t } = useI18n();
const store = useStore();
const route = useRoute();
const conversationHeader = ref(null);
const { width } = useElementSize(conversationHeader);
const { isAWebWidgetInbox, isAWhatsAppCloudChannel, voiceCallEnabled } =
  useInbox();
const voiceCallsStore = useVoiceCallsStore();
const isInitiatingCall = ref(false);

const currentChat = computed(() => store.getters.getSelectedChat);
const accountId = computed(() => store.getters.getCurrentAccountId);

const chatMetadata = computed(() => props.chat.meta);

const backButtonUrl = computed(() => {
  const {
    params: { inbox_id: inboxId, label, teamId, id: customViewId },
    name,
  } = route;

  const conversationTypeMap = {
    conversation_through_mentions: 'mention',
    conversation_through_participating: 'participating',
    conversation_through_unattended: 'unattended',
  };
  return conversationListPageURL({
    accountId: accountId.value,
    inboxId,
    label,
    teamId,
    conversationType: conversationTypeMap[name],
    customViewId,
  });
});

const isHMACVerified = computed(() => {
  if (!isAWebWidgetInbox.value) {
    return true;
  }
  return chatMetadata.value.hmac_verified;
});

const currentContact = computed(() =>
  store.getters['contacts/getContact'](props.chat.meta.sender.id)
);

const isSnoozed = computed(
  () => currentChat.value.status === wootConstants.STATUS_TYPE.SNOOZED
);

const snoozedDisplayText = computed(() => {
  const { snoozed_until: snoozedUntil } = currentChat.value;
  if (snoozedUntil) {
    return `${t('CONVERSATION.HEADER.SNOOZED_UNTIL')} ${snoozedReopenTime(snoozedUntil)}`;
  }
  return t('CONVERSATION.HEADER.SNOOZED_UNTIL_NEXT_REPLY');
});

const inbox = computed(() => {
  const { inbox_id: inboxId } = props.chat;
  return store.getters['inboxes/getInbox'](inboxId);
});

const hasMultipleInboxes = computed(
  () => store.getters['inboxes/getInboxes'].length > 1
);

const hasSlaPolicyId = computed(() => props.chat?.sla_policy_id);

// Returns the provider to use for an outbound call, based on the inbox
// channel type. WhatsApp Cloud inboxes use :whatsapp; Twilio Voice inboxes
// use :twilio. Returns null if outbound calling isn't supported on this
// channel.
const callProvider = computed(() => {
  if (isAWhatsAppCloudChannel.value && inbox.value?.calling_enabled) {
    return 'whatsapp';
  }
  if (voiceCallEnabled.value) {
    return 'twilio';
  }
  return null;
});

const canInitiateVoiceCall = computed(() => {
  if (!callProvider.value) return false;
  if (voiceCallsStore.hasVoiceCall) return false;
  return true;
});

// Outbound call initiation. WhatsApp now runs direct browser ↔ Meta WebRTC:
// the browser builds the SDP offer locally before any network call, so Meta
// gets the agent's real fingerprint and the eventual answer applies cleanly
// in the cable handler. Twilio still POSTs first and waits for the
// synchronous agent_offer in the response (its OutboundCallBuilder produces
// the SDP server-side). On 138006 (no call permission) we tear down the local
// PC immediately so the mic light goes off while the contact's phone shows
// the consent prompt.
const initiateWhatsappCall = async () => {
  if (isInitiatingCall.value || !currentChat.value?.id || !callProvider.value)
    return;
  isInitiatingCall.value = true;
  const isWhatsApp = callProvider.value === 'whatsapp';

  try {
    let sdpOffer = null;
    if (isWhatsApp) {
      sdpOffer = await prepareOutboundOffer({});
    }

    const response = await VoiceCallsAPI.initiate(
      currentChat.value.id,
      callProvider.value,
      isWhatsApp ? { sdpOffer } : {}
    );

    const callStatus = response.data?.status;
    if (
      callStatus === 'permission_requested' ||
      callStatus === 'permission_pending'
    ) {
      // Tear down the local PC; we'll rebuild from scratch on retry.
      cleanupInboundWebRTC();
      const message =
        callStatus === 'permission_requested'
          ? t('WHATSAPP_CALL.PERMISSION_REQUESTED')
          : t('WHATSAPP_CALL.PERMISSION_PENDING');
      emitter.emit(BUS_EVENTS.SHOW_ALERT, { message, type: 'info' });
      return;
    }

    emitter.emit(BUS_EVENTS.SHOW_ALERT, {
      message: t('WHATSAPP_CALL.CALLING'),
      type: 'success',
    });

    const callData = response.data || {};
    voiceCallsStore.setActiveCall({
      id: callData.id,
      callId: callData.call_id,
      provider: callData.provider || callProvider.value,
      direction: 'outbound',
      status: 'ringing',
      conversationId: currentChat.value.id,
      caller: {
        name: currentContact.value?.name,
        phone: currentContact.value?.phone_number,
        avatar: currentContact.value?.thumbnail,
      },
    });
  } catch (err) {
    cleanupInboundWebRTC();
    const errorMessage =
      err.response?.data?.error || t('WHATSAPP_CALL.CALL_FAILED');
    emitter.emit(BUS_EVENTS.SHOW_ALERT, {
      message: errorMessage,
      type: 'error',
    });
  } finally {
    isInitiatingCall.value = false;
  }
};
</script>

<template>
  <div
    ref="conversationHeader"
    class="flex flex-col gap-3 items-center justify-between flex-1 w-full min-w-0 xl:flex-row px-3 pt-3 pb-2 h-24 xl:h-12"
  >
    <div
      class="flex items-center justify-start w-full xl:w-auto max-w-full min-w-0 xl:flex-1"
    >
      <BackButton
        v-if="showBackButton"
        :back-url="backButtonUrl"
        class="ltr:mr-2 rtl:ml-2"
      />
      <Avatar
        :name="currentContact.name"
        :src="currentContact.thumbnail"
        :size="32"
        :status="currentContact.availability_status"
        hide-offline-status
        rounded-full
      />
      <div
        class="flex flex-col items-start min-w-0 ml-2 overflow-hidden rtl:ml-0 rtl:mr-2"
      >
        <div class="flex flex-row items-center max-w-full gap-1 p-0 m-0">
          <span
            class="text-sm font-medium truncate leading-tight text-n-slate-12"
          >
            {{ currentContact.name }}
          </span>
          <fluent-icon
            v-if="!isHMACVerified"
            v-tooltip="$t('CONVERSATION.UNVERIFIED_SESSION')"
            size="14"
            class="text-n-amber-10 my-0 mx-0 min-w-[14px] flex-shrink-0"
            icon="warning"
          />
        </div>

        <div
          class="flex items-center gap-2 overflow-hidden text-xs conversation--header--actions text-ellipsis whitespace-nowrap"
        >
          <InboxName v-if="hasMultipleInboxes" :inbox="inbox" class="!mx-0" />
          <span v-if="isSnoozed" class="font-medium text-n-amber-10">
            {{ snoozedDisplayText }}
          </span>
        </div>
      </div>
    </div>
    <div
      class="flex flex-row items-center justify-start xl:justify-end flex-shrink-0 gap-2 w-full xl:w-auto header-actions-wrap"
    >
      <SLACardLabel
        v-if="hasSlaPolicyId"
        :chat="chat"
        show-extended-info
        :parent-width="width"
        class="hidden md:flex"
      />
      <button
        v-if="canInitiateVoiceCall"
        v-tooltip="$t('WHATSAPP_CALL.INITIATE_CALL')"
        class="flex items-center justify-center w-8 h-8 rounded-lg text-n-slate-11 hover:text-n-slate-12 hover:bg-n-slate-3 transition-colors"
        :disabled="isInitiatingCall"
        @click="initiateWhatsappCall"
      >
        <i
          v-if="isInitiatingCall"
          class="text-base i-ph-circle-notch animate-spin"
        />
        <i v-else class="text-base i-ph-phone-bold" />
      </button>
      <MoreActions :conversation-id="currentChat.id" />
    </div>
  </div>
</template>
