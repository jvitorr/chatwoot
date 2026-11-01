require 'rails_helper'

# [FORK CONNECTEI] modifications/027b — o eco não vira "atendente fantasma".
describe Messages::Instagram::MessageBuilder do
  let(:account) { create(:account) }
  let!(:channel) { create(:channel_instagram, account: account, instagram_id: 'ig-business-1') }
  let(:inbox) { channel.inbox }
  let(:contact) { create(:contact, account: account) }
  let!(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox, source_id: 'igsid-1') }
  let!(:conversation) { create(:conversation, account: account, inbox: inbox, contact: contact, contact_inbox: contact_inbox) }

  def pending_outgoing(content, **attributes)
    create(:message, message_type: :outgoing, account: account, inbox: inbox, conversation: conversation, content: content, **attributes)
  end

  def echo(text, mid: "mid-#{SecureRandom.hex(4)}", recipient: 'igsid-1')
    messaging = { sender: { id: 'ig-business-1' }, recipient: { id: recipient }, timestamp: 1_730_376_000_000,
                  message: { mid: mid, text: text, is_echo: true } }
    described_class.new(messaging.with_indifferent_access, inbox, outgoing_echo: true).perform
    mid
  end

  it 'adopts the pending automation message instead of creating a "human" one' do
    pending = pending_outgoing("Te mandei o link 😉\n", content_attributes: { flow_effect_key: 'fx:1', delivery_unconfirmed: true })

    mid = echo('Te mandei o link 😉')

    expect(conversation.messages.count).to eq(1)
    expect(pending.reload.source_id).to eq(mid)
    expect(pending.content_attributes).not_to have_key('delivery_unconfirmed')
    expect(pending.content_attributes['flow_effect_key']).to eq('fx:1')
  end

  it 'publishes the adoption as message_updated, so the ERP sees the source_id' do
    pending = pending_outgoing('Oi')
    allow(Rails.configuration.dispatcher).to receive(:dispatch).and_call_original

    echo('Oi')

    expect(Rails.configuration.dispatcher).to have_received(:dispatch)
      .with(Events::Types::MESSAGE_UPDATED, anything, hash_including(message: pending))
  end

  it 'keeps a message typed in the Instagram app as a human message' do
    pending_outgoing('Mensagem da automação')

    echo('Digitei isso no celular')

    human = conversation.messages.reorder(:id).last
    expect(conversation.messages.count).to eq(2)
    expect(human).to have_attributes(content: 'Digitei isso no celular', sender: nil, message_type: 'outgoing')
    expect(human.content_attributes['external_echo']).to be(true)
  end

  it 'does not adopt a message older than 5 minutes' do
    pending = pending_outgoing('Oi', created_at: 6.minutes.ago)

    echo('Oi')

    expect(pending.reload.source_id).to be_nil
    expect(conversation.messages.count).to eq(2)
  end

  it 'does not adopt a failed message (it never left)' do
    pending = pending_outgoing('Oi', status: :failed)

    echo('Oi')

    expect(pending.reload.source_id).to be_nil
    expect(conversation.messages.count).to eq(2)
  end

  it 'does not adopt a pending message of another contact' do
    other_inbox = create(:contact_inbox, inbox: inbox, source_id: 'igsid-2')
    other_conversation = create(:conversation, account: account, inbox: inbox, contact: other_inbox.contact, contact_inbox: other_inbox)
    other = create(:message, message_type: :outgoing, account: account, inbox: inbox, conversation: other_conversation, content: 'Oi')

    echo('Oi')

    expect(other.reload.source_id).to be_nil
    expect(conversation.messages.count).to eq(1)
  end

  it 'adopts identical texts in order (first echo → oldest pending)' do
    first = pending_outgoing('Oi', created_at: 2.minutes.ago)
    second = pending_outgoing('Oi', created_at: 1.minute.ago)

    first_mid = echo('Oi')
    second_mid = echo('Oi')

    expect([first.reload.source_id, second.reload.source_id]).to eq([first_mid, second_mid])
    expect(conversation.messages.count).to eq(2)
  end

  it 'is a no-op for a known mid (upstream dedupe) and for a replayed echo' do
    pending = pending_outgoing('Oi')
    mid = echo('Oi')

    echo('Oi', mid: mid)

    expect(pending.reload.source_id).to eq(mid)
    expect(conversation.messages.count).to eq(1)
  end
end
