import AuthAPI from '../api/auth';
import BaseActionCableConnector from '../../shared/helpers/BaseActionCableConnector';
import DashboardAudioNotificationHelper from './AudioAlerts/DashboardAudioNotificationHelper';
import { BUS_EVENTS } from 'shared/constants/busEvents';
import { emitter } from 'shared/helpers/mitt';
import { useImpersonation } from 'dashboard/composables/useImpersonation';
import {
  useWhatsappCallsStore,
  getOutboundCallState,
} from 'dashboard/stores/whatsappCalls';
import { handleAgentOffer } from 'dashboard/composables/useWhatsappCallSession';

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
      'whatsapp_call.incoming': this.onWhatsappCallIncoming,
      'whatsapp_call.accepted': this.onWhatsappCallAccepted,
      'whatsapp_call.ended': this.onWhatsappCallEnded,
      'whatsapp_call.outbound_connected': this.onWhatsappCallOutboundConnected,
      'whatsapp_call.permission_granted': this.onWhatsappCallPermissionGranted,
      'whatsapp_call.agent_offer': this.onWhatsappCallAgentOffer,
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
  onWhatsappCallIncoming = data => {
    const whatsappCallsStore = useWhatsappCallsStore();
    // In server-relay mode, sdp_offer and ice_servers are absent — the media
    // server handles WebRTC with Meta, and the browser only needs call metadata.
    whatsappCallsStore.addIncomingCall({
      id: data.id,
      callId: data.call_id,
      direction: data.direction,
      inboxId: data.inbox_id,
      conversationId: data.conversation_id,
      caller: data.caller,
      sdpOffer: data.sdp_offer || null,
      iceServers: data.ice_servers || null,
      mediaServerEnabled: data.media_server_enabled,
    });
  };

  onWhatsappCallAccepted = data => {
    const whatsappCallsStore = useWhatsappCallsStore();
    const currentUserId = this.app.$store.getters.getCurrentUserID;
    // If accepted by a different agent, remove from incoming list for this agent
    if (data.accepted_by_agent_id !== currentUserId) {
      whatsappCallsStore.handleCallAcceptedByOther(data.call_id);
    }
  };

  // eslint-disable-next-line class-methods-use-this
  onWhatsappCallEnded = data => {
    const whatsappCallsStore = useWhatsappCallsStore();
    whatsappCallsStore.handleCallEnded(data.call_id);
  };

  // eslint-disable-next-line class-methods-use-this
  onWhatsappCallOutboundConnected = data => {
    const whatsappCallsStore = useWhatsappCallsStore();

    // Server-relay mode: data contains sdp_offer (media server generated offer
    // for Peer B) instead of sdp_answer.
    if (data.sdp_offer) {
      const activeCall = whatsappCallsStore.activeCall;
      if (activeCall && activeCall.callId === data.call_id) {
        handleAgentOffer(activeCall.id, data.sdp_offer, data.ice_servers)
          .then(() => {
            whatsappCallsStore.markActiveCallConnected();
            // Emit event so the composable can start the timer
            emitter.emit('whatsapp_call:agent_webrtc_connected');
          })
          .catch(err => {
            // eslint-disable-next-line no-console
            console.error(
              '[WhatsApp Call] Failed to handle outbound agent offer:',
              err
            );
          });
      }
      return;
    }

    // Legacy mode: data contains sdp_answer (Meta's answer to browser's offer)
    const { pc, callId } = getOutboundCallState();
    if (pc && callId === data.call_id && data.sdp_answer) {
      pc.setRemoteDescription({ type: 'answer', sdp: data.sdp_answer }).catch(
        err => {
          // eslint-disable-next-line no-console
          console.error(
            '[WhatsApp Call] Failed to set remote SDP answer:',
            err
          );
        }
      );
    }
  };

  // eslint-disable-next-line class-methods-use-this
  onWhatsappCallPermissionGranted = data => {
    emitter.emit('whatsapp_call:permission_granted', {
      contactName: data.contact_name,
    });
  };

  // Server-relay mode: the media server created Peer B and sent an SDP offer
  // for the agent's browser. This fires after POST /accept or POST /reconnect.
  // eslint-disable-next-line class-methods-use-this
  onWhatsappCallAgentOffer = data => {
    const whatsappCallsStore = useWhatsappCallsStore();
    const activeCall = whatsappCallsStore.activeCall;

    if (!activeCall) return;
    // Verify this offer is for the current active call
    if (activeCall.callId !== data.call_id && activeCall.id !== data.id) return;

    handleAgentOffer(activeCall.id, data.sdp_offer, data.ice_servers)
      .then(() => {
        whatsappCallsStore.markActiveCallConnected();
        whatsappCallsStore.setReconnecting(false);
        // Emit event so the composable can start the timer
        emitter.emit('whatsapp_call:agent_webrtc_connected');
      })
      .catch(err => {
        // eslint-disable-next-line no-console
        console.error('[WhatsApp Call] Failed to handle agent offer:', err);
      });
  };
}

export default {
  init(store, pubsubToken) {
    return new ActionCableConnector({ $store: store }, pubsubToken);
  },
};
