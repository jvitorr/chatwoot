# [FORK CONNECTEI] modifications/024 — escopos do Instagram no JSON do inbox.
require 'rails_helper'

RSpec.describe 'Inbox JSON: escopos concedidos do Instagram', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  def show_inbox(inbox)
    get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}",
        headers: admin.create_new_auth_token,
        as: :json
    response.parsed_body
  end

  it 'expõe os escopos concedidos do canal Instagram' do
    channel = create(:channel_instagram, account: account,
                                         connectei_granted_scopes: %w[instagram_business_basic instagram_business_manage_comments])

    body = show_inbox(channel.inbox)

    expect(response).to have_http_status(:success)
    expect(body['instagram_granted_scopes']).to eq(%w[instagram_business_basic instagram_business_manage_comments])
  end

  it 'canal Instagram sem escopos gravados: lista vazia, nunca nil' do
    channel = create(:channel_instagram, account: account)

    expect(show_inbox(channel.inbox)['instagram_granted_scopes']).to eq([])
  end

  it 'inbox que não é Instagram não tem o campo' do
    inbox = create(:inbox, channel: create(:channel_api, account: account), account: account)

    expect(show_inbox(inbox)).not_to have_key('instagram_granted_scopes')
  end
end
