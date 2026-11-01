require 'rails_helper'

# [FORK CONNECTEI] modifications/025 — envio do Instagram Login.
describe Instagram::SendOnInstagramService do
  let(:account) { create(:account) }
  let!(:channel) { create(:channel_instagram, account: account) }
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account) }
  let!(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'igsid-1') }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }
  let(:graph_url) { %r{\Ahttps://graph\.instagram\.com/v22\.0/#{channel.instagram_id}/messages} }
  let(:sent) { [] }

  def stub_graph(status: 200, body: { recipient_id: 'igsid-1', message_id: 'mid-ok' })
    stub_request(:post, graph_url).to_return do |request|
      sent << Rack::Utils.parse_nested_query(request.body)
      { status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' } }
    end
  end

  def outgoing(content: 'Escolha uma opção', **attributes)
    create(:message, message_type: :outgoing, account: account, inbox: inbox, conversation: conversation, content: content, **attributes)
  end

  def deliver(message)
    described_class.new(message: message).perform
    message.reload
  end

  describe 'quick replies (input_select)' do
    it 'sends at most 13 quick replies, titles cut to 20 characters and payload = value' do
      stub_graph
      items = Array.new(15) { |index| { title: "Opção número #{index} com título longo", value: "menu:n1:i#{index}" } }

      deliver(outgoing(content_type: 'input_select', content_attributes: { items: items }))

      message_param = JSON.parse(sent.first['message'])
      expect(message_param['text']).to eq('Escolha uma opção')
      expect(message_param['quick_replies'].size).to eq(13)
      expect(message_param['quick_replies'].first).to eq('content_type' => 'text', 'title' => 'Opção número 0 com t', 'payload' => 'menu:n1:i0')
      expect(message_param['quick_replies'].map { |reply| reply['title'].length }.max).to be <= 20
      expect(sent.first['recipient']).to eq('id' => 'igsid-1')
    end

    it 'keeps a plain text message in the regular form encoding' do
      stub_graph

      deliver(outgoing(content: 'oi'))

      expect(sent.first['message']).to eq('text' => 'oi')
    end
  end

  describe 'private reply' do
    let(:private_reply_attributes) { { ig_private_reply: { comment_id: '17890000000000001' }, flow_effect_key: 'fx:1' } }

    it 'sends to the comment (recipient.comment_id) and stores the returned message_id as source_id' do
      stub_graph

      message = deliver(outgoing(content: 'Te mandei o link 😉', content_attributes: private_reply_attributes))

      expect(sent.first['recipient']).to eq('comment_id' => '17890000000000001')
      expect(message.source_id).to eq('mid-ok')
      expect(message.content_attributes['ig_private_reply']).not_to have_key('recipient_id')
    end

    it 'never adds HUMAN_AGENT, even for a human sender outside the 24-hour window with the flag on' do
      InstallationConfig.where(name: 'ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT').first_or_create!(value: true)
      GlobalConfig.clear_cache
      create(:message, message_type: :incoming, account: account, inbox: inbox, conversation: conversation, created_at: 3.days.ago)
      stub_graph

      deliver(outgoing(content: 'oi', content_attributes: { ig_private_reply: { comment_id: 'c-1' } }))

      expect(sent.first).not_to have_key('tag')
      expect(sent.first).not_to have_key('messaging_type')
    ensure
      GlobalConfig.clear_cache
    end

    it 'records a divergent recipient_id and logs a warning' do
      stub_graph(body: { recipient_id: 'igsid-outro', message_id: 'mid-ok' })
      allow(Rails.logger).to receive(:warn)

      message = deliver(outgoing(content: 'oi', content_attributes: private_reply_attributes))

      expect(message.content_attributes['ig_private_reply']).to eq('comment_id' => '17890000000000001', 'recipient_id' => 'igsid-outro')
      expect(message.source_id).to eq('mid-ok')
      expect(Rails.logger).to have_received(:warn).with(/recipient_id igsid-outro difere do source_id igsid-1/)
    end
  end

  describe 'Meta errors' do
    def error_body(code, subcode = nil, text = 'erro da Meta')
      { error: { message: text, type: 'OAuthException', code: code, error_subcode: subcode } }
    end

    it 'keeps external_error and adds code, subcode and kind in the same failed update' do
      stub_graph(status: 400, body: error_body(10, 2_534_022, 'This message is sent outside of allowed window.'))
      message = outgoing
      updates = []
      allow(Rails.configuration.dispatcher).to receive(:dispatch).and_wrap_original do |original, *args, **kwargs|
        payload = args[2].is_a?(Hash) ? args[2] : kwargs
        updates << payload[:message].content_attributes.dup if args[0] == Events::Types::MESSAGE_UPDATED
        kwargs.empty? ? original.call(*args) : original.call(*args, **kwargs)
      end

      deliver(message)

      expect(updates.size).to eq(1)
      expect(updates.first).to include('external_error_kind' => 'window_closed', 'external_error_code' => 10)
      expect(message.status).to eq('failed')
      expect(message.content_attributes).to include(
        'external_error' => '10 - This message is sent outside of allowed window.',
        'external_error_code' => 10, 'external_error_subcode' => 2_534_022, 'external_error_kind' => 'window_closed'
      )
    end

    {
      [613, nil] => 'rate_limited', [551, 1_545_041] => 'user_unavailable', [9_999, nil] => 'unknown'
    }.each do |(code, subcode), kind|
      it "classifies Meta code #{code} as #{kind}" do
        stub_graph(status: 400, body: error_body(code, subcode))

        expect(deliver(outgoing).content_attributes['external_error_kind']).to eq(kind)
      end
    end

    it 'classifies a deleted comment on a private reply as comment_unavailable' do
      stub_graph(status: 400, body: error_body(100, 33, 'Object does not exist'))

      message = deliver(outgoing(content_attributes: { ig_private_reply: { comment_id: 'c-apagado' } }))

      expect(message.content_attributes).to include('external_error_kind' => 'comment_unavailable', 'external_error_code' => 100)
    end

    it 'classifies an invalid token as token and asks for reauthorization' do
      stub_graph(status: 400, body: error_body(190, nil, 'Error validating access token'))

      expect(deliver(outgoing).content_attributes['external_error_kind']).to eq('token')
      expect(channel.reload).to be_reauthorization_required
    end
  end

  describe 'timeouts' do
    it 'marks a read timeout (after sending) as delivery_unconfirmed and keeps the message sent' do
      stub_request(:post, graph_url).to_raise(Net::ReadTimeout)

      message = deliver(outgoing)

      expect(message.status).to eq('sent')
      expect(message.content_attributes['delivery_unconfirmed']).to be(true)
      expect(message.content_attributes).not_to have_key('external_error')
    end

    it 'marks an open timeout (never sent) as failed with kind unknown' do
      stub_request(:post, graph_url).to_raise(Net::OpenTimeout)

      message = deliver(outgoing)

      expect(message.status).to eq('failed')
      expect(message.content_attributes).to include('external_error_kind' => 'unknown', 'external_error' => /Net::OpenTimeout/)
    end

    it 'does not flag delivery_unconfirmed when an echo already adopted the message meanwhile (mod 027b)' do
      message = outgoing
      stub_request(:post, graph_url)
        .with { |_request| Message.where(id: message.id).update_all(source_id: 'mid-do-eco') } # rubocop:disable Rails/SkipsModelValidations
        .to_raise(Net::ReadTimeout)

      deliver(message)

      expect(message.source_id).to eq('mid-do-eco')
      expect(message.content_attributes).not_to have_key('delivery_unconfirmed')
    end

    it 'does not turn a late Graph error into failed when the echo already adopted the message' do
      message = outgoing
      stub_request(:post, graph_url)
        .with { |_request| Message.where(id: message.id).update_all(source_id: 'mid-do-eco') } # rubocop:disable Rails/SkipsModelValidations
        .to_return(status: 500, body: { error: { code: 2, message: 'Service temporarily unavailable' } }.to_json,
                   headers: { 'Content-Type' => 'application/json' })

      deliver(message)

      expect(message.status).to eq('sent')
      expect(message.source_id).to eq('mid-do-eco')
    end
  end

  describe 'per-account rate limiter' do
    it 'fails the private reply over CONNECTEI_IG_PRIVATE_REPLY_PER_HOUR without calling the Graph' do
      stub_graph

      with_modified_env(CONNECTEI_IG_PRIVATE_REPLY_PER_HOUR: '2') do
        3.times { |index| deliver(outgoing(content: "oi #{index}", content_attributes: { ig_private_reply: { comment_id: "c-#{index}" } })) }
      end

      expect(sent.size).to eq(2)
      blocked = conversation.messages.reorder(:id).last
      expect(blocked.status).to eq('failed')
      expect(blocked.content_attributes).to include('external_error_kind' => 'rate_limited', 'external_error_code' => nil)
      expect(blocked.content_attributes['external_error']).to start_with('rate_limited - ')
    end

    it 'fails a message over CONNECTEI_IG_SEND_PER_SECOND without calling the Graph' do
      stub_graph

      with_modified_env(CONNECTEI_IG_SEND_PER_SECOND: '1') do
        freeze_time { 2.times { |index| deliver(outgoing(content: "msg #{index}")) } }
      end

      expect(sent.size).to eq(1)
      expect(conversation.messages.reorder(:id).last.content_attributes['external_error_kind']).to eq('rate_limited')
    end
  end
end
