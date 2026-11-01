require 'rails_helper'

# [FORK CONNECTEI] modifications/024 — campos assinados no webhook.
RSpec.describe Channel::Instagram do
  let(:account) { create(:account) }
  let(:base_fields) { %w[messages message_reactions messaging_seen messaging_postbacks messaging_referral] }

  # O `after_create_commit` do canal já assina uma vez; zera o registro para
  # contar só a chamada sob teste.
  def subscribe_request(channel, fields)
    WebMock.reset_executed_requests!
    stub_request(:post, "https://graph.instagram.com/v22.0/#{channel.instagram_id}/subscribed_apps")
      .with(query: { access_token: channel[:access_token], subscribed_fields: fields })
      .to_return(status: 200, body: { success: true }.to_json)
  end

  it 'subscribes postbacks and referral, without comments, when no scope was granted' do
    channel = create(:channel_instagram, account: account)
    request = subscribe_request(channel, base_fields)

    channel.subscribe

    expect(request).to have_been_requested.once
  end

  it 'subscribes comments when the channel has instagram_business_manage_comments' do
    channel = create(:channel_instagram, account: account, connectei_granted_scopes: %w[instagram_business_manage_comments])
    request = subscribe_request(channel, base_fields + ['comments'])

    channel.subscribe

    expect(request).to have_been_requested.once
  end

  it 'persists the granted scopes with an empty default' do
    channel = create(:channel_instagram, account: account)

    expect(channel.reload.connectei_granted_scopes).to eq([])
  end
end
