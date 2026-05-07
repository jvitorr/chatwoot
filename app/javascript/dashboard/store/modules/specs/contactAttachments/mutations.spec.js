import * as types from '../../../mutation-types';
import { mutations } from '../../contactAttachments';

describe('#mutations', () => {
  describe('#SET_CONTACT_ATTACHMENTS_UI_FLAG', () => {
    it('merges incoming flags into existing uiFlags', () => {
      const state = { uiFlags: { isFetching: true } };
      mutations[types.default.SET_CONTACT_ATTACHMENTS_UI_FLAG](state, {
        isFetching: false,
      });
      expect(state.uiFlags).toEqual({ isFetching: false });
    });
  });

  describe('#SET_CONTACT_ATTACHMENTS', () => {
    it('sets attachment records keyed by contact id', () => {
      const state = { records: {} };
      const data = [{ id: 1, file_type: 'image' }];
      mutations[types.default.SET_CONTACT_ATTACHMENTS](state, { id: 1, data });
      expect(state.records).toEqual({ 1: data });
    });

    it('replaces records for the same contact while preserving others', () => {
      const existing = [{ id: 99, file_type: 'file' }];
      const state = { records: { 2: existing } };
      const data = [{ id: 1, file_type: 'image' }];
      mutations[types.default.SET_CONTACT_ATTACHMENTS](state, { id: 1, data });
      expect(state.records).toEqual({ 1: data, 2: existing });
    });
  });
});
