import AuthAPI from '../api/auth';
import BaseActionCableConnector from '../../shared/helpers/BaseActionCableConnector';
import DashboardAudioNotificationHelper from './AudioAlerts/DashboardAudioNotificationHelper';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';
import { useImpersonation } from 'dashboard/composables/useImpersonation';
import { useVoiceCallsStore } from 'dashboard/stores/voiceCalls';
import { applyOutboundAnswer } from 'dashboard/composables/useVoiceCallSession';

const { isImpersonating } = useImpersonation();

class ActionCableConnector extends BaseActionCableConnector {
  constructor(app, pubsubToken) {
    const { websocketURL = '' } = window.chatwootConfig || {};
    super(app, pubsubToken, websocketURL);
    this.CancelTyping = [];
    this.events = {
      'message.created': this.onMessageCreated,
      'message.updated': this.onMessageUpdated,
      'conversation.created': this.onConversationCreated,
      'conversation.status_changed': this.onStatusChange,
      'user:logout': this.onLogout,
      'page:reload': this.onReload,
      'assignee.changed': this.onAssigneeChanged,
      'conversation.typing_on': this.onTypingOn,
      'conversation.typing_off': this.onTypingOff,
      'conversation.contact_changed': this.onConversationContactChange,
      'presence.update': this.onPresenceUpdate,
      'contact.deleted': this.onContactDelete,
      'contact.updated': this.onContactUpdate,
      'conversation.mentioned': this.onConversationMentioned,
      'notification.created': this.onNotificationCreated,
      'notification.deleted': this.onNotificationDeleted,
      'notification.updated': this.onNotificationUpdated,
      'conversation.read': this.onConversationRead,
      'conversation.updated': this.onConversationUpdated,
      'account.cache_invalidated': this.onCacheInvalidate,
      'copilot.message.created': this.onCopilotMessageCreated,
      'voice_call.incoming': this.onVoiceCallIncoming,
      'voice_call.accepted': this.onVoiceCallAccepted,
      'voice_call.ended': this.onVoiceCallEnded,
      'voice_call.outbound_connected': this.onVoiceCallOutboundConnected,
      'voice_call.permission_granted': this.onVoiceCallPermissionGranted,
    };
  }

  // eslint-disable-next-line class-methods-use-this
  onReconnect = () => {
    emitter.emit(BUS_EVENTS.WEBSOCKET_RECONNECT);
  };

  // eslint-disable-next-line class-methods-use-this
  onDisconnected = () => {
    emitter.emit(BUS_EVENTS.WEBSOCKET_DISCONNECT);
  };

  isAValidEvent = data => {
    return this.app.$store.getters.getCurrentAccountId === data.account_id;
  };

  onMessageUpdated = data => {
    this.app.$store.dispatch('updateMessage', data);
  };

  onPresenceUpdate = data => {
    if (isImpersonating.value) return;
    this.app.$store.dispatch('contacts/updatePresence', data.contacts);
    this.app.$store.dispatch('agents/updatePresence', data.users);
    this.app.$store.dispatch('setCurrentUserAvailability', data.users);
  };

  onConversationContactChange = payload => {
    const { meta = {}, id: conversationId } = payload;
    const { sender } = meta || {};
    if (conversationId) {
      this.app.$store.dispatch('updateConversationContact', {
        conversationId,
        ...sender,
      });
    }
  };

  onAssigneeChanged = payload => {
    const { id } = payload;
    if (id) {
      this.app.$store.dispatch('updateConversation', payload);
    }
    this.fetchConversationStats();
  };

  onConversationCreated = data => {
    this.app.$store.dispatch('addConversation', data);
    this.fetchConversationStats();
  };

  onConversationRead = data => {
    this.app.$store.dispatch('updateConversation', data);
  };

  // eslint-disable-next-line class-methods-use-this
  onLogout = () => AuthAPI.logout();

  onMessageCreated = data => {
    const {
      conversation: { last_activity_at: lastActivityAt },
      conversation_id: conversationId,
    } = data;
    DashboardAudioNotificationHelper.onNewMessage(data);
    this.app.$store.dispatch('addMessage', data);
    this.app.$store.dispatch('updateConversationLastActivity', {
      lastActivityAt,
      conversationId,
    });
  };

  // eslint-disable-next-line class-methods-use-this
  onReload = () => window.location.reload();

  onStatusChange = data => {
    this.app.$store.dispatch('updateConversation', data);
    this.fetchConversationStats();
  };

  onConversationUpdated = data => {
    this.app.$store.dispatch('updateConversation', data);
    this.fetchConversationStats();
  };

  onTypingOn = ({ conversation, user }) => {
    const conversationId = conversation.id;

    this.clearTimer(conversationId);
    this.app.$store.dispatch('conversationTypingStatus/create', {
      conversationId,
      user,
    });
    this.initTimer({ conversation, user });
  };

  onTypingOff = ({ conversation, user }) => {
    const conversationId = conversation.id;

    this.clearTimer(conversationId);
    this.app.$store.dispatch('conversationTypingStatus/destroy', {
      conversationId,
      user,
    });
  };

  onConversationMentioned = data => {
    this.app.$store.dispatch('addMentions', data);
  };

  clearTimer = conversationId => {
    const timerEvent = this.CancelTyping[conversationId];

    if (timerEvent) {
      clearTimeout(timerEvent);
      this.CancelTyping[conversationId] = null;
    }
  };

  initTimer = ({ conversation, user }) => {
    const conversationId = conversation.id;
    // Turn off typing automatically after 30 seconds
    this.CancelTyping[conversationId] = setTimeout(() => {
      this.onTypingOff({ conversation, user });
    }, 30000);
  };

  // eslint-disable-next-line class-methods-use-this
  fetchConversationStats = () => {
    emitter.emit('fetch_conversation_stats');
  };

  onContactDelete = data => {
    this.app.$store.dispatch(
      'contacts/deleteContactThroughConversations',
      data.id
    );
    this.fetchConversationStats();
  };

  onContactUpdate = data => {
    this.app.$store.dispatch('contacts/updateContact', data);
  };

  onNotificationCreated = data => {
    this.app.$store.dispatch('notifications/addNotification', data);
  };

  onNotificationDeleted = data => {
    this.app.$store.dispatch('notifications/deleteNotification', data);
  };

  onNotificationUpdated = data => {
    this.app.$store.dispatch('notifications/updateNotification', data);
  };

  onCopilotMessageCreated = data => {
    this.app.$store.dispatch('copilotMessages/upsert', data);
  };

  onCacheInvalidate = data => {
    const keys = data.cache_keys;
    this.app.$store.dispatch('labels/revalidate', { newKey: keys.label });
    this.app.$store.dispatch('inboxes/revalidate', { newKey: keys.inbox });
    this.app.$store.dispatch('teams/revalidate', { newKey: keys.team });
  };

  // eslint-disable-next-line class-methods-use-this
  onVoiceCallIncoming = data => {
    const voiceCallsStore = useVoiceCallsStore();
    voiceCallsStore.addIncomingCall({
      id: data.id,
      callId: data.call_id,
      provider: data.provider,
      direction: data.direction,
      inboxId: data.inbox_id,
      conversationId: data.conversation_id,
      caller: data.caller,
      // Stash Meta's SDP offer + ICE servers on the incoming-call entry so
      // the bubble's Accept button can build the WebRTC answer locally
      // without re-fetching from /show.
      sdpOffer: data.sdp_offer,
      iceServers: data.ice_servers,
    });
  };

  onVoiceCallAccepted = data => {
    const voiceCallsStore = useVoiceCallsStore();
    const currentUserId = this.app.$store.getters.getCurrentUserID;
    if (data.accepted_by_agent_id !== currentUserId) {
      voiceCallsStore.handleCallAcceptedByOther(data.call_id);
    }
  };

  // eslint-disable-next-line class-methods-use-this
  onVoiceCallEnded = data => {
    const voiceCallsStore = useVoiceCallsStore();
    voiceCallsStore.handleCallEnded(data.call_id);
  };

  // eslint-disable-next-line class-methods-use-this
  onVoiceCallOutboundConnected = data => {
    // Outbound WhatsApp direct mode: Meta delivers its SDP answer when the
    // contact picks up. Apply it to the existing local RTCPeerConnection so
    // DTLS can complete browser ↔ Meta directly. The PC was created earlier
    // by prepareOutboundOffer when the agent clicked the call button.
    const voiceCallsStore = useVoiceCallsStore();
    const activeCall = voiceCallsStore.activeCall;
    if (!activeCall || activeCall.callId !== data.call_id) return;

    if (!data.sdp_answer) return;

    applyOutboundAnswer(data.sdp_answer)
      .then(() => {
        voiceCallsStore.markActiveCallConnected();
        emitter.emit('voice_call:agent_webrtc_connected');
      })
      .catch(err => {
        // eslint-disable-next-line no-console
        console.error('[Voice Call] Failed to apply outbound SDP answer:', err);
      });
  };

  // eslint-disable-next-line class-methods-use-this
  onVoiceCallPermissionGranted = data => {
    emitter.emit('voice_call:permission_granted', {
      contactName: data.contact_name,
    });
  };
}

export default {
  init(store, pubsubToken) {
    return new ActionCableConnector({ $store: store }, pubsubToken);
  },
};
