<script setup>
import { computed, onBeforeUnmount, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useStore } from 'vuex';
import { useCallSession } from 'dashboard/composables/useCallSession';
import { setWhatsappCallMuted } from 'dashboard/composables/useWhatsappCallSession';
import { frontendURL, conversationUrl } from 'dashboard/helper/URLHelper';
import WindowVisibilityHelper from 'dashboard/helper/AudioAlerts/WindowVisibilityHelper';
import CallCard from 'dashboard/components/widgets/call/CallCard.vue';

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

const mainCardState = computed(() => {
  if (hasActiveCall.value) return 'ongoing';
  const direction = incomingCalls.value[0]?.callDirection;
  return direction === 'outbound' ? 'outgoing' : 'incoming';
});

const toggleMute = () => {
  isMuted.value = !isMuted.value;
  setWhatsappCallMuted(isMuted.value);
};

watch(hasActiveCall, active => {
  if (!active) isMuted.value = false;
});

// Convert ISO 3166-1 alpha-2 country code (e.g. "US") to its regional indicator
// flag emoji. Returns empty string if the code is missing or malformed.
const countryCodeToFlag = code => {
  if (!code || code.length !== 2) return '';
  const base = 0x1f1e6;
  const offset = 'A'.charCodeAt(0);
  return String.fromCodePoint(
    ...code
      .toUpperCase()
      .split('')
      .map(c => base + (c.charCodeAt(0) - offset))
  );
};

const getCallInfo = call => {
  const conversation = store.getters.getConversationById(call?.conversationId);
  const inbox = store.getters['inboxes/getInbox'](conversation?.inbox_id);
  const sender = conversation?.meta?.sender;
  // Inbound WhatsApp calls stash caller info on the call record (from the cable
  // payload) so the widget has something to show before the conversation lands.
  const caller = call?.caller;
  const additional = sender?.additional_attributes || {};
  const city = additional.city || '';
  const country = additional.country || '';
  const countryCode = additional.country_code || '';
  // Prefer the richest available location string ("City, Country"); fall back to
  // whichever single field is present; finally fall back to the inbox name so
  // there's always something to show.
  const locationParts = [city, country].filter(Boolean);
  const location =
    locationParts.join(', ') || inbox?.name || 'Customer support';
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
    location,
    countryFlag: countryCodeToFlag(countryCode),
    hasLocation: locationParts.length > 0,
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
    class="fixed ltr:right-4 rtl:left-4 bottom-4 z-50 flex flex-col gap-3 w-[400px]"
  >
    <!-- Incoming Calls (shown above active call) -->
    <CallCard
      v-for="call in hasActiveCall ? incomingCalls : []"
      :key="call.callSid"
      :call="call"
      state="incoming"
      :call-info="getCallInfo(call)"
      @accept="handleJoinCall(call)"
      @reject="dismissCall(call.callSid)"
      @go-to-conversation="goToConversation(call)"
    />

    <!-- Main Call Widget -->
    <CallCard
      v-if="hasActiveCall || incomingCalls.length"
      :call="activeCall || incomingCalls[0]"
      :state="mainCardState"
      :call-info="getCallInfo(activeCall || incomingCalls[0])"
      :duration="hasActiveCall ? formattedCallDuration : ''"
      :is-muted="isMuted"
      :show-mute="hasActiveCall && isWhatsappActive"
      @accept="handleJoinCall(incomingCalls[0])"
      @reject="rejectIncomingCall(incomingCalls[0]?.callSid)"
      @end="handleEndCall"
      @toggle-mute="toggleMute"
      @go-to-conversation="goToConversation(activeCall || incomingCalls[0])"
    />
  </div>
</template>
