import { getters } from '../../contactAttachments';

describe('#getters', () => {
  describe('#getContactAttachments', () => {
    it('returns the attachment list for a numeric contact id', () => {
      const data = [{ id: 1, file_type: 'image' }];
      const state = { records: { 1: data } };
      expect(getters.getContactAttachments(state)(1)).toEqual(data);
    });

    it('coerces string ids and returns the matching record', () => {
      const data = [{ id: 1, file_type: 'image' }];
      const state = { records: { 1: data } };
      expect(getters.getContactAttachments(state)('1')).toEqual(data);
    });

    it('returns an empty array when no record exists', () => {
      const state = { records: {} };
      expect(getters.getContactAttachments(state)(99)).toEqual([]);
    });
  });

  describe('#getUIFlags', () => {
    it('returns the uiFlags slice', () => {
      const state = { uiFlags: { isFetching: true } };
      expect(getters.getUIFlags(state)).toEqual({ isFetching: true });
    });
  });
});
