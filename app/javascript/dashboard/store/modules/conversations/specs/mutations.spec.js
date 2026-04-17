import { mutations } from '../index';
import types from '../../../mutation-types';

describe('#mutations', () => {
  describe('#UPDATE_MESSAGE_CALL_STATUS', () => {
    it('does nothing if conversation is not found', () => {
      const state = { allConversations: [] };
      mutations[types.UPDATE_MESSAGE_CALL_STATUS](state, {
        conversationId: 1,
        callStatus: 'ringing',
        callSid: 'CA123',
      });
      expect(state.allConversations).toEqual([]);
    });

    it('does nothing if no matching voice call message exists', () => {
      const state = {
        allConversations: [
          { id: 1, messages: [{ id: 1, content_type: 'text' }] },
        ],
      };
      mutations[types.UPDATE_MESSAGE_CALL_STATUS](state, {
        conversationId: 1,
        callStatus: 'ringing',
        callSid: 'CA123',
      });
      expect(state.allConversations[0].messages[0]).toEqual({
        id: 1,
        content_type: 'text',
      });
    });

    it('updates only the voice call message matching the given callSid', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            messages: [
              {
                id: 1,
                content_type: 'voice_call',
                content_attributes: {
                  data: { call_sid: 'CA111', status: 'ringing' },
                },
              },
              {
                id: 2,
                content_type: 'voice_call',
                content_attributes: {
                  data: { call_sid: 'CA222', status: 'ringing' },
                },
              },
            ],
          },
        ],
      };
      mutations[types.UPDATE_MESSAGE_CALL_STATUS](state, {
        conversationId: 1,
        callStatus: 'in-progress',
        callSid: 'CA111',
      });
      expect(
        state.allConversations[0].messages[0].content_attributes.data.status
      ).toBe('in-progress');
      expect(
        state.allConversations[0].messages[1].content_attributes.data.status
      ).toBe('ringing');
    });

    it('preserves existing data in content_attributes.data', () => {
      const state = {
        allConversations: [
          {
            id: 1,
            messages: [
              {
                id: 1,
                content_type: 'voice_call',
                content_attributes: {
                  data: { call_sid: 'CA123', status: 'ringing' },
                },
              },
            ],
          },
        ],
      };
      mutations[types.UPDATE_MESSAGE_CALL_STATUS](state, {
        conversationId: 1,
        callStatus: 'in-progress',
        callSid: 'CA123',
      });
      expect(
        state.allConversations[0].messages[0].content_attributes.data
      ).toEqual({
        call_sid: 'CA123',
        status: 'in-progress',
      });
    });

    it('handles empty messages array', () => {
      const state = {
        allConversations: [{ id: 1, messages: [] }],
      };
      mutations[types.UPDATE_MESSAGE_CALL_STATUS](state, {
        conversationId: 1,
        callStatus: 'ringing',
        callSid: 'CA123',
      });
      expect(state.allConversations[0].messages).toEqual([]);
    });
  });
});
