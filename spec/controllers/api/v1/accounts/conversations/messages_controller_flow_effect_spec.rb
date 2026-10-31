require 'rails_helper'

# [FORK CONNECTEI] modifications/027b — POST de mensagem idempotente por `flow_effect_key`.
RSpec.describe 'Conversation Messages API — flow_effect_key idempotency', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, inbox: inbox, account: account) }
  let(:headers) { { api_access_token: agent.access_token.token } }

  before { create(:inbox_member, inbox: inbox, user: agent) }

  def post_message(params, target: conversation, as: :json)
    post api_v1_account_conversation_messages_url(account_id: account.id, conversation_id: target.display_id),
         params: params, headers: headers, as: as
  end

  it 'returns the existing message (200) without creating or sending it again' do
    post_message({ content: 'Oi!', content_attributes: { flow_effect_key: 'fx:1' } })
    first_id = response.parsed_body['id']

    expect do
      post_message({ content: 'Oi!', content_attributes: { flow_effect_key: 'fx:1' } })
    end.not_to(change { conversation.messages.count })

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body['id']).to eq(first_id)
    expect(response.parsed_body['content_attributes']['flow_effect_key']).to eq('fx:1')
    expect(SendReplyJob).to have_been_enqueued.exactly(:once)
  end

  it 'accepts the key as multipart form fields and as a JSON string (the two ERP formats)' do
    post_message({ 'content' => 'Oi', 'content_attributes[flow_effect_key]' => 'fx:form' }, as: nil)
    post_message({ 'content' => 'Oi', 'content_attributes[flow_effect_key]' => 'fx:form' }, as: nil)
    post_message({ content: 'Oi', content_attributes: { flow_effect_key: 'fx:json', connectei_media_kind: 'x' }.to_json }, as: nil)
    post_message({ content: 'Oi', content_attributes: { flow_effect_key: 'fx:json', connectei_media_kind: 'x' }.to_json }, as: nil)

    expect(conversation.messages.count).to eq(2)
  end

  it 'scopes the key to the conversation' do
    other = create(:conversation, inbox: inbox, account: account)

    post_message({ content: 'Oi', content_attributes: { flow_effect_key: 'fx:1' } })
    post_message({ content: 'Oi', content_attributes: { flow_effect_key: 'fx:1' } }, target: other)

    expect(conversation.messages.count).to eq(1)
    expect(other.messages.count).to eq(1)
  end

  it 'returns an existing failed message as it is (a retry needs a new key)' do
    post_message({ content: 'Oi', content_attributes: { flow_effect_key: 'fx:1' } })
    conversation.messages.last.update!(status: :failed)

    post_message({ content: 'Oi', content_attributes: { flow_effect_key: 'fx:1' } })

    expect(response.parsed_body['status']).to eq('failed')
    expect(conversation.messages.count).to eq(1)
  end

  it 'keeps creating messages normally when there is no flow_effect_key' do
    2.times { post_message({ content: 'Oi' }) }

    expect(conversation.messages.count).to eq(2)
  end

  it 'works for an Instagram conversation too (any channel)' do
    channel = create(:channel_instagram, account: account)
    create(:inbox_member, inbox: channel.inbox, user: agent)
    ig_conversation = create(:conversation, inbox: channel.inbox, account: account)

    2.times { post_message({ content: 'Oi', content_attributes: { flow_effect_key: 'fx:ig' } }, target: ig_conversation) }

    expect(ig_conversation.messages.count).to eq(1)
  end
end
