require 'rails_helper'

# [FORK CONNECTEI] modifications/026 — perfil do contato criado pelo comment-threads é buscado no 1º DM.
describe Instagram::MessageText do
  let(:account) { create(:account) }
  let!(:channel) { create(:channel_instagram, account: account, instagram_id: 'ig-business-1') }
  let(:inbox) { channel.inbox }
  let(:profile_lookup) { %r{graph\.instagram\.com/v22\.0/1234567890\?} }

  def comment_thread_contact
    Connectei::Instagram::CommentThreadService.new(inbox: inbox, igsid: '1234567890', username: 'cliente_x').perform
    inbox.contact_inboxes.find_by!(source_id: '1234567890').contact
  end

  def receive(text: 'oi', echo: false)
    messaging = if echo
                  { sender: { id: 'ig-business-1' }, recipient: { id: '1234567890' },
                    message: { mid: "mid-#{SecureRandom.hex(4)}", text: text, is_echo: true } }
                else
                  { sender: { id: '1234567890' }, recipient: { id: 'ig-business-1' }, message: { mid: "mid-#{SecureRandom.hex(4)}", text: text } }
                end
    described_class.new(messaging.with_indifferent_access, channel).perform
  end

  it 'fetches the profile on the first DM, swaps the provisional name and clears the pending mark' do
    contact = comment_thread_contact
    lookup = stub_request(:get, profile_lookup)
             .to_return(status: 200, body: { id: '1234567890', name: 'Maria Silva', username: 'cliente_x', is_user_follow_business: true }.to_json,
                        headers: { 'Content-Type' => 'application/json' })

    receive

    contact.reload
    expect(lookup).to have_been_requested.once
    expect(contact.name).to eq('Maria Silva')
    expect(contact.additional_attributes).not_to have_key('connectei_profile_pending')
    expect(contact.additional_attributes).to include('social_instagram_user_name' => 'cliente_x', 'social_instagram_is_user_follow_business' => true)
    expect(inbox.messages.count).to eq(1)
  end

  it 'keeps the mark (and still creates the message) when the profile is not available yet' do
    contact = comment_thread_contact
    stub_request(:get, profile_lookup).to_return(status: 400, body: { error: { code: 230, message: 'User consent is required' } }.to_json)

    receive

    expect(contact.reload.additional_attributes['connectei_profile_pending']).to be(true)
    expect(contact.name).to eq('cliente_x')
    expect(inbox.messages.count).to eq(1)
  end

  it 'does not overwrite a name an agent already changed' do
    contact = comment_thread_contact
    contact.update!(name: 'Cliente VIP')
    stub_request(:get, profile_lookup).to_return(status: 200, body: { id: '1234567890', name: 'Maria Silva', username: 'cliente_x' }.to_json)

    receive

    expect(contact.reload.name).to eq('Cliente VIP')
    expect(contact.additional_attributes).not_to have_key('connectei_profile_pending')
  end

  it 'does not look the profile up on an echo (the person has not written yet)' do
    comment_thread_contact
    lookup = stub_request(:get, profile_lookup)

    receive(echo: true)

    expect(lookup).not_to have_been_requested
  end

  it 'does not look the profile up again for a contact that is not pending' do
    contact = comment_thread_contact
    contact.update!(additional_attributes: contact.additional_attributes.except('connectei_profile_pending'))
    lookup = stub_request(:get, profile_lookup)

    receive

    expect(lookup).not_to have_been_requested
  end
end
