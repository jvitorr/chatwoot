import * as types from '../mutation-types';
import ContactAPI from '../../api/contacts';

const state = {
  records: {},
  uiFlags: {
    isFetching: false,
  },
};

export const getters = {
  getUIFlags($state) {
    return $state.uiFlags;
  },
  getContactAttachments: $state => id => {
    return $state.records[Number(id)] || [];
  },
};

export const actions = {
  get: async ({ commit }, contactId) => {
    commit(types.default.SET_CONTACT_ATTACHMENTS_UI_FLAG, { isFetching: true });
    try {
      const response = await ContactAPI.getAttachments(contactId);
      commit(types.default.SET_CONTACT_ATTACHMENTS, {
        id: contactId,
        data: response.data.payload,
      });
    } finally {
      commit(types.default.SET_CONTACT_ATTACHMENTS_UI_FLAG, {
        isFetching: false,
      });
    }
  },
};

export const mutations = {
  [types.default.SET_CONTACT_ATTACHMENTS_UI_FLAG]($state, data) {
    $state.uiFlags = { ...$state.uiFlags, ...data };
  },
  [types.default.SET_CONTACT_ATTACHMENTS]: ($state, { id, data }) => {
    $state.records = { ...$state.records, [id]: data };
  },
};

export default {
  namespaced: true,
  state,
  getters,
  actions,
  mutations,
};
