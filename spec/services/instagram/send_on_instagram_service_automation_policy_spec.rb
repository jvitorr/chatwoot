require 'rails_helper'

# [FORK CONNECTEI] modifications/027 — política de envio da automação do ERP.
describe Instagram::SendOnInstagramService do
  let(:account) { create(:account) }
  let!(:channel) { create(:channel_instagram, account: account) }
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account) }
  let!(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'igsid-1') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let!(:graph) do
    stub_request(:post, %r{graph\.instagram\.com/v22\.0/#{channel.instagram_id}/messages})
      .to_return(status: 200, body: { recipient_id: 'igsid-1', message_id: 'mid-ok' }.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  def customer_wrote(at)
    create(:message, message_type: :incoming, account: account, inbox: inbox, conversation: conversation, sender: contact, created_at: at)
  end

  def outgoing(**content_attributes)
    create(:message, message_type: :outgoing, account: account, inbox: inbox, conversation: conversation, content: 'Oi!',
                     content_attributes: content_attributes)
  end

  def deliver(message)
    described_class.new(message: message).perform
    message.reload
  end

  describe 'window of the automation (flow_effect_key)' do
    it 'does not call the Graph and fails with window_closed when the last customer message is older than 24h' do
      customer_wrote(25.hours.ago)

      message = deliver(outgoing(flow_effect_key: 'fx:1'))

      expect(graph).not_to have_been_requested
      expect(message.status).to eq('failed')
      expect(message.content_attributes).to include('external_error_kind' => 'window_closed', 'external_error_code' => nil,
                                                    'external_error_subcode' => nil)
      expect(message.content_attributes['external_error']).to start_with('window_closed - ')
    end

    it 'blocks it as well when the customer never wrote (conversation opened by comment-threads)' do
      message = deliver(outgoing(flow_effect_key: 'fx:1'))

      expect(graph).not_to have_been_requested
      expect(message.content_attributes['external_error_kind']).to eq('window_closed')
    end

    it 'sends it inside the window' do
      customer_wrote(23.hours.ago)

      message = deliver(outgoing(flow_effect_key: 'fx:1'))

      expect(graph).to have_been_requested.once
      expect(message.source_id).to eq('mid-ok')
    end

    it 'does not apply the 24h rule to the private reply (the Meta applies the 7 days of the comment)' do
      message = deliver(outgoing(flow_effect_key: 'fx:1', ig_private_reply: { comment_id: '17890000000000001' }))

      expect(graph).to have_been_requested.once
      expect(message.status).to eq('sent')
    end

    it 'leaves human messages to the upstream rules (no fork-side window block)' do
      customer_wrote(25.hours.ago)

      deliver(outgoing)

      expect(graph).to have_been_requested.once
    end
  end

  describe 'HUMAN_AGENT' do
    before do
      InstallationConfig.where(name: 'ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT').first_or_create!(value: true)
      GlobalConfig.clear_cache
      customer_wrote(25.hours.ago)
    end

    after { GlobalConfig.clear_cache }

    it 'is never added to an automation message, even from a User outside the window' do
      params = described_class.new(message: outgoing(flow_effect_key: 'fx:1')).send(:merge_human_agent_tag, { recipient: { id: 'igsid-1' } })

      expect(params).to eq(recipient: { id: 'igsid-1' })
    end

    it 'is still added to a human reply outside the window (#15932 behaviour)' do
      params = described_class.new(message: outgoing).send(:merge_human_agent_tag, { recipient: { id: 'igsid-1' } })

      expect(params).to include(messaging_type: 'MESSAGE_TAG', tag: 'HUMAN_AGENT')
    end
  end
end
