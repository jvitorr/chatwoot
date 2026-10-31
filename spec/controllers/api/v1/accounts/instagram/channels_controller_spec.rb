require 'rails_helper'

# [FORK CONNECTEI] modifications/003 (registro do canal) + 024 (granted_scopes).
RSpec.describe 'Connectei Instagram channel registration API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:base_fields) { %w[messages message_reactions messaging_seen messaging_postbacks messaging_referral] }
  let(:create_params) do
    { access_token: 'long-lived-token', instagram_id: '17841400000000000', username: 'minha_loja', expires_in: 5_184_000 }
  end

  def stub_subscribe(instagram_id, token, fields)
    stub_request(:post, "https://graph.instagram.com/v22.0/#{instagram_id}/subscribed_apps")
      .with(query: { access_token: token, subscribed_fields: fields })
      .to_return(status: 200, body: { success: true }.to_json)
  end

  describe 'POST /api/v1/accounts/:account_id/instagram/channels' do
    it 'stores granted_scopes and subscribes comments when the comments scope was granted' do
      subscribe = stub_subscribe('17841400000000000', 'long-lived-token', base_fields + ['comments'])

      post "/api/v1/accounts/#{account.id}/instagram/channels",
           params: create_params.merge(granted_scopes: %w[instagram_business_basic instagram_business_manage_comments]),
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      channel = Channel::Instagram.find_by!(instagram_id: '17841400000000000')
      expect(channel.connectei_granted_scopes).to eq(%w[instagram_business_basic instagram_business_manage_comments])
      expect(response.parsed_body['granted_scopes']).to eq(channel.connectei_granted_scopes)
      expect(subscribe).to have_been_requested.once
    end

    it 'accepts granted_scopes as the comma separated "permissions" string' do
      stub_subscribe('17841400000000000', 'long-lived-token', base_fields)

      post "/api/v1/accounts/#{account.id}/instagram/channels",
           params: create_params.merge(granted_scopes: 'instagram_business_basic,instagram_business_manage_messages'),
           headers: admin.create_new_auth_token, as: :json

      expect(Channel::Instagram.last.connectei_granted_scopes).to eq(%w[instagram_business_basic instagram_business_manage_messages])
    end

    it 'defaults to no scope (and no comments subscription) when granted_scopes is absent' do
      subscribe = stub_subscribe('17841400000000000', 'long-lived-token', base_fields)

      post "/api/v1/accounts/#{account.id}/instagram/channels", params: create_params, headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(Channel::Instagram.last.connectei_granted_scopes).to eq([])
      expect(subscribe).to have_been_requested.once
    end
  end

  describe 'PATCH /api/v1/accounts/:account_id/instagram/channels/:id' do
    let!(:channel) { create(:channel_instagram, account: account, connectei_granted_scopes: %w[instagram_business_basic]) }

    it 'replaces granted_scopes and re-subscribes with comments' do
      subscribe = stub_subscribe(channel.instagram_id, 'novo-token', base_fields + ['comments'])

      patch "/api/v1/accounts/#{account.id}/instagram/channels/#{channel.id}",
            params: { access_token: 'novo-token', expires_in: 5_184_000,
                      granted_scopes: %w[instagram_business_basic instagram_business_manage_comments] },
            headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(channel.reload.connectei_granted_scopes).to eq(%w[instagram_business_basic instagram_business_manage_comments])
      expect(response.parsed_body['granted_scopes']).to eq(channel.connectei_granted_scopes)
      expect(subscribe).to have_been_requested.once
    end

    it 'keeps the stored scopes when granted_scopes is not sent' do
      stub_subscribe(channel.instagram_id, 'novo-token', base_fields)

      patch "/api/v1/accounts/#{account.id}/instagram/channels/#{channel.id}",
            params: { access_token: 'novo-token', expires_in: 5_184_000 }, headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(channel.reload.connectei_granted_scopes).to eq(%w[instagram_business_basic])
    end

    it 'clears the scopes (and drops comments) when an empty list is sent' do
      channel.update!(connectei_granted_scopes: %w[instagram_business_manage_comments])
      subscribe = stub_subscribe(channel.instagram_id, 'novo-token', base_fields)

      patch "/api/v1/accounts/#{account.id}/instagram/channels/#{channel.id}",
            params: { access_token: 'novo-token', expires_in: 5_184_000, granted_scopes: [] },
            headers: admin.create_new_auth_token, as: :json

      expect(channel.reload.connectei_granted_scopes).to eq([])
      expect(subscribe).to have_been_requested.once
    end

    it 'does not touch a channel of another account' do
      other = create(:channel_instagram, account: create(:account))

      patch "/api/v1/accounts/#{account.id}/instagram/channels/#{other.id}",
            params: { access_token: 'novo-token', expires_in: 5_184_000, granted_scopes: %w[x] },
            headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
      expect(other.reload.connectei_granted_scopes).to eq([])
    end
  end
end
