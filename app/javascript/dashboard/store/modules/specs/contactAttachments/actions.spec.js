import axios from 'axios';
import { actions } from '../../contactAttachments';
import * as types from '../../../mutation-types';

const attachments = [
  {
    id: 11,
    message_id: 21,
    conversation_display_id: 7,
    file_type: 'image',
    data_url: 'https://example.com/image.png',
  },
  {
    id: 12,
    message_id: 22,
    conversation_display_id: 7,
    file_type: 'file',
    data_url: 'https://example.com/file.pdf',
  },
];

const commit = vi.fn();
global.axios = axios;
vi.mock('axios');

beforeEach(() => commit.mockClear());

describe('#actions', () => {
  describe('#get', () => {
    it('sends correct actions if API is success', async () => {
      axios.get.mockResolvedValue({ data: { payload: attachments } });
      await actions.get({ commit }, 1);
      expect(commit.mock.calls).toEqual([
        [types.default.SET_CONTACT_ATTACHMENTS_UI_FLAG, { isFetching: true }],
        [types.default.SET_CONTACT_ATTACHMENTS, { id: 1, data: attachments }],
        [types.default.SET_CONTACT_ATTACHMENTS_UI_FLAG, { isFetching: false }],
      ]);
    });

    it('clears the loading flag and rethrows if API errors', async () => {
      axios.get.mockRejectedValue(new Error('Network error'));
      await expect(actions.get({ commit }, 1)).rejects.toThrow('Network error');
      expect(commit.mock.calls).toEqual([
        [types.default.SET_CONTACT_ATTACHMENTS_UI_FLAG, { isFetching: true }],
        [types.default.SET_CONTACT_ATTACHMENTS_UI_FLAG, { isFetching: false }],
      ]);
    });
  });
});
