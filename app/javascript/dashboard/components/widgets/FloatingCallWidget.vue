<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useStore } from 'vuex';
import { useCallSession } from 'dashboard/composables/useCallSession';
import { setWhatsappCallMuted } from 'dashboard/composables/useWhatsappCallSession';
import { frontendURL, conversationUrl } from 'dashboard/helper/URLHelper';
import WindowVisibilityHelper from 'dashboard/helper/AudioAlerts/WindowVisibilityHelper';
import Avatar from 'dashboard/components-next/avatar/Avatar.vue';

const RINGTONE_URL = '/audio/dashboard/bell.mp3';

const route = useRoute();
const router = useRouter();
const store = useStore();

const {
  activeCall,
  incomingCalls,
  hasActiveCall,
  isJoining,
  joinCall,
  endCall: endCallSession,
  rejectIncomingCall,
  dismissCall,
  formattedCallDuration,
} = useCallSession();

// Mute is currently WhatsApp-only — Twilio calls are mediated server-side and
// don't expose a mic track on the browser side.
const isMuted = ref(false);
const isWhatsappActive = computed(
  () => activeCall.value?.provider === 'whatsapp'
);

const toggleMute = () => {
  isMuted.value = !isMuted.value;
  setWhatsappCallMuted(isMuted.value);
};

watch(hasActiveCall, active => {
  if (!active) isMuted.value = false;
});

const getCallInfo = call => {
  const conversation = store.getters.getConversationById(call?.conversationId);
  const inbox = store.getters['inboxes/getInbox'](conversation?.inbox_id);
  const sender = conversation?.meta?.sender;
  // Inbound WhatsApp calls stash caller info on the call record (from the cable
  // payload) so the widget has something to show before the conversation lands.
  const caller = call?.caller;
  return {
    conversation,
    inbox,
    contactName:
      sender?.name ||
      sender?.phone_number ||
      caller?.name ||
      caller?.phone ||
      'Unknown caller',
    phoneNumber: sender?.phone_number || caller?.phone || '',
    inboxName: inbox?.name || 'Customer support',
    avatar: sender?.avatar || sender?.thumbnail || caller?.avatar,
  };
};

const goToConversation = call => {
  const conversationId = call?.conversationId;
  const accountId = route.params.accountId;
  if (!conversationId || !accountId) return;
  router.push({
    path: frontendURL(conversationUrl({ accountId, id: conversationId })),
  });
};

const handleEndCall = async () => {
  const call = activeCall.value;
  if (!call) return;

  const inboxId = call.inboxId || getCallInfo(call).conversation?.inbox_id;
  if (!inboxId) return;

  await endCallSession({
    conversationId: call.conversationId,
    inboxId,
    callSid: call.callSid,
  });
};

const handleJoinCall = async call => {
  if (!call || isJoining.value) return;
  const { conversation } = getCallInfo(call);

  if (hasActiveCall.value) {
    await handleEndCall();
  }

  // The conversation may not be hydrated yet (post-refresh seeding path);
  // call.inboxId already carries what joinCall needs.
  const result = await joinCall({
    conversationId: call.conversationId,
    inboxId: call.inboxId || conversation?.inbox_id,
    callSid: call.callSid,
  });

  if (result && conversation) {
    router.push({
      name: 'inbox_conversation',
      params: { conversation_id: call.conversationId },
    });
  }
};

// Auto-join outbound calls when window is visible. WhatsApp outbound has no
// separate join step (the offer was sent at initiate time and the answer is
// applied directly by the cable handler), so this only covers Twilio.
watch(
  () => incomingCalls.value[0],
  call => {
    if (
      call?.callDirection === 'outbound' &&
      call?.provider !== 'whatsapp' &&
      !hasActiveCall.value &&
      WindowVisibilityHelper.isWindowVisible()
    ) {
      handleJoinCall(call);
    }
  },
  { immediate: true }
);

// Loop the ringtone while an inbound call is unanswered. Stop the moment any
// call is active (we joined), every inbound call cleared, or the widget tears
// down. Browser autoplay may reject the first play() if the tab has no prior
// user gesture; that's fine — the visual widget still surfaces the call.
const ringtone = new Audio(RINGTONE_URL);
ringtone.loop = true;
ringtone.volume = 1;

const stopRingtone = () => {
  ringtone.pause();
  ringtone.currentTime = 0;
};

const ringingInbound = computed(() =>
  incomingCalls.value.some(call => call.callDirection !== 'outbound')
);

watch(
  () => ringingInbound.value && !hasActiveCall.value,
  shouldRing => {
    if (shouldRing) {
      ringtone.play().catch(() => {});
    } else {
      stopRingtone();
    }
  },
  { immediate: true }
);

onBeforeUnmount(stopRingtone);
</script>

<template>
  <div
    v-if="incomingCalls.length || hasActiveCall"
    class="fixed ltr:right-4 rtl:left-4 bottom-4 z-50 flex flex-col gap-2 w-80"
  >
    <!-- Incoming Calls (shown above active call) -->
    <div
      v-for="call in hasActiveCall ? incomingCalls : []"
      :key="call.callSid"
      class="flex flex-col gap-3 p-4 bg-n-solid-2 rounded-xl shadow-xl outline outline-1 outline-n-strong"
    >
      <div class="flex items-center gap-3">
        <div
          class="animate-pulse ring-2 ring-n-teal-9 rounded-full inline-flex"
        >
          <Avatar
            :src="getCallInfo(call).avatar"
            :name="getCallInfo(call).contactName"
            :size="40"
            rounded-full
          />
        </div>
        <div class="flex-1 min-w-0">
          <p class="text-sm font-medium text-n-slate-12 truncate mb-0">
            {{ getCallInfo(call).contactName }}
          </p>
          <p
            v-if="getCallInfo(call).phoneNumber"
            class="text-xs text-n-slate-11 truncate mb-0"
          >
            {{ getCallInfo(call).phoneNumber }}
          </p>
        </div>
      </div>
      <button
        v-if="call.conversationId"
        class="flex items-center gap-2 px-3 py-2 bg-n-alpha-2 hover:bg-n-alpha-3 rounded-lg transition-colors"
        @click="goToConversation(call)"
      >
        <i class="text-base text-n-slate-11 i-ph-chat-circle-text-bold" />
        <span class="text-xs text-n-slate-12">
          {{ $t('CONVERSATION.VOICE_WIDGET.VIEW_CHAT_HISTORY') }}
        </span>
        <span class="ml-auto text-xs text-n-slate-11">
          #{{ call.conversationId }}
        </span>
        <i class="text-xs text-n-slate-11 i-ph-caret-right-bold" />
      </button>
      <div class="flex items-center justify-between gap-2">
        <button
          v-tooltip.top="$t('CONVERSATION.VOICE_WIDGET.REJECT_CALL')"
          class="flex justify-center items-center w-10 h-10 bg-n-slate-3 hover:bg-n-slate-4 rounded-full transition-colors"
          @click="dismissCall(call.callSid)"
        >
          <i class="text-lg text-n-slate-12 i-ph-phone-x-bold" />
        </button>
        <button
          class="flex justify-center items-center gap-2 px-4 h-10 bg-n-teal-9 hover:bg-n-teal-10 rounded-full transition-colors"
          @click="handleJoinCall(call)"
        >
          <i class="text-base text-white i-ph-phone-bold" />
          <span class="text-sm font-medium text-white">
            {{ $t('CONVERSATION.VOICE_WIDGET.JOIN_CALL') }}
          </span>
        </button>
      </div>
    </div>

    <!-- Main Call Widget -->
    <div
      v-if="hasActiveCall || incomingCalls.length"
      class="flex flex-col gap-3 p-4 bg-n-solid-2 rounded-xl shadow-xl outline outline-1 outline-n-strong"
    >
      <div class="flex items-center gap-3">
        <div
          class="ring-2 ring-n-teal-9 rounded-full inline-flex"
          :class="{ 'animate-pulse': !hasActiveCall }"
        >
          <Avatar
            :src="getCallInfo(activeCall || incomingCalls[0]).avatar"
            :name="getCallInfo(activeCall || incomingCalls[0]).contactName"
            :size="40"
            rounded-full
          />
        </div>
        <div class="flex-1 min-w-0">
          <p class="text-sm font-medium text-n-slate-12 truncate mb-0">
            {{ getCallInfo(activeCall || incomingCalls[0]).contactName }}
          </p>
          <p
            v-if="getCallInfo(activeCall || incomingCalls[0]).phoneNumber"
            class="text-xs text-n-slate-11 truncate mb-0"
          >
            {{ getCallInfo(activeCall || incomingCalls[0]).phoneNumber }}
          </p>
        </div>
        <p
          v-if="hasActiveCall"
          class="font-mono text-sm text-n-slate-12 shrink-0"
        >
          {{ formattedCallDuration }}
        </p>
        <p v-else class="text-xs text-n-slate-11 shrink-0">
          {{
            incomingCalls[0]?.callDirection === 'outbound'
              ? $t('CONVERSATION.VOICE_WIDGET.OUTGOING_CALL')
              : $t('CONVERSATION.VOICE_WIDGET.INCOMING_CALL')
          }}
        </p>
      </div>

      <button
        v-if="(activeCall || incomingCalls[0])?.conversationId"
        class="flex items-center gap-2 px-3 py-2 bg-n-alpha-2 hover:bg-n-alpha-3 rounded-lg transition-colors"
        @click="goToConversation(activeCall || incomingCalls[0])"
      >
        <i class="text-base text-n-slate-11 i-ph-chat-circle-text-bold" />
        <span class="text-xs text-n-slate-12">
          {{ $t('CONVERSATION.VOICE_WIDGET.VIEW_CHAT_HISTORY') }}
        </span>
        <span class="ml-auto text-xs text-n-slate-11">
          #{{ (activeCall || incomingCalls[0])?.conversationId }}
        </span>
        <i class="text-xs text-n-slate-11 i-ph-caret-right-bold" />
      </button>

      <div class="flex items-center justify-between gap-2">
        <div class="flex gap-2">
          <button
            v-if="hasActiveCall && isWhatsappActive"
            v-tooltip.top="
              isMuted
                ? $t('CONVERSATION.VOICE_WIDGET.UNMUTE')
                : $t('CONVERSATION.VOICE_WIDGET.MUTE')
            "
            class="flex justify-center items-center w-10 h-10 rounded-full transition-colors"
            :class="
              isMuted
                ? 'bg-n-amber-9 hover:bg-n-amber-10'
                : 'bg-n-slate-3 hover:bg-n-slate-4'
            "
            @click="toggleMute"
          >
            <i
              class="text-lg"
              :class="
                isMuted
                  ? 'text-white i-ph-microphone-slash-bold'
                  : 'text-n-slate-12 i-ph-microphone-bold'
              "
            />
          </button>
        </div>
        <div class="flex gap-2">
          <button
            v-if="
              !hasActiveCall && incomingCalls[0]?.callDirection !== 'outbound'
            "
            class="flex justify-center items-center gap-2 px-4 h-10 bg-n-teal-9 hover:bg-n-teal-10 rounded-full transition-colors"
            @click="handleJoinCall(incomingCalls[0])"
          >
            <i class="text-base text-white i-ph-phone-bold" />
            <span class="text-sm font-medium text-white">
              {{ $t('CONVERSATION.VOICE_WIDGET.JOIN_CALL') }}
            </span>
          </button>
          <button
            class="flex justify-center items-center gap-2 px-4 h-10 bg-n-ruby-9 hover:bg-n-ruby-10 rounded-full transition-colors"
            @click="
              hasActiveCall
                ? handleEndCall()
                : rejectIncomingCall(incomingCalls[0]?.callSid)
            "
          >
            <i class="text-base text-white i-ph-phone-x-bold" />
            <span class="text-sm font-medium text-white">
              {{ $t('CONVERSATION.VOICE_WIDGET.END_CALL') }}
            </span>
          </button>
        </div>
      </div>
    </div>
  </div>
</template>
