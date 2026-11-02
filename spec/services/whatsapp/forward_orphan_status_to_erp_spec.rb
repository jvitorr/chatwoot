require 'rails_helper'

# [FORK CONNECTEI] modifications/001-repasse-status-whatsapp-connectei.md
# O status de um `wamid` sem `Message` local (disparo feito pelo ERP direto na
# Graph API) precisa ser repassado ao ERP. Um merge de upstream que restaure o
# `return unless find_message_by_source_id(...)` desliga o repasse em silêncio;
# esta spec é o que faz esse merge ficar vermelho.
# rubocop:disable RSpec/SpecFilePathFormat -- cobre o gancho do fork no service, não uma classe nova
describe Whatsapp::IncomingMessageService do
  let(:whatsapp_channel) { create(:channel_whatsapp, sync_templates: false) }
  let(:wamid) { 'wamid.HBgMNTU3OTk5OTk5OTk5FQIAERgSQUJDREVGMDEyMzQ1Njc4OQA=' }
  let(:status_params) do
    {
      'statuses' => [{ 'recipient_id' => '5579999999999', 'id' => wamid, 'status' => 'delivered' }]
    }.with_indifferent_access
  end

  before do
    stub_request(:post, 'https://waba.360dialog.io/v1/configs/webhook')
  end

  it 'forwards the status of an unknown wamid to the ERP' do
    expect do
      described_class.new(inbox: whatsapp_channel.inbox, params: status_params).perform
    end.to have_enqueued_job(Whatsapp::ForwardMessageStatusToErpJob)
      .with([hash_including('id' => wamid, 'status' => 'delivered')])
  end

  it 'does not forward the status of a message that exists locally' do
    contact_inbox = create(:contact_inbox, inbox: whatsapp_channel.inbox, source_id: '5579999999999')
    conversation = create(:conversation, inbox: whatsapp_channel.inbox, contact_inbox: contact_inbox, contact: contact_inbox.contact)
    message = create(:message, conversation: conversation, inbox: whatsapp_channel.inbox, account: whatsapp_channel.account,
                               message_type: :outgoing, source_id: wamid, status: :sent)

    expect do
      described_class.new(inbox: whatsapp_channel.inbox, params: status_params).perform
    end.not_to have_enqueued_job(Whatsapp::ForwardMessageStatusToErpJob)

    expect(message.reload.status).to eq('delivered')
  end

  it 'never lets an enqueue failure break the webhook processing' do
    allow(Whatsapp::ForwardMessageStatusToErpJob).to receive(:perform_later).and_raise(StandardError, 'redis down')

    expect do
      described_class.new(inbox: whatsapp_channel.inbox, params: status_params).perform
    end.not_to raise_error
  end
end
# rubocop:enable RSpec/SpecFilePathFormat
