require 'rails_helper'

# [FORK CONNECTEI] modifications/001 + 023 — o status de um envio de campanha do
# próprio Chatwoot (CampaignRecipient, sem Message) não é disparo do ERP e não
# deve ser repassado; o de um wamid desconhecido continua sendo.
# rubocop:disable RSpec/SpecFilePathFormat -- cobre o guard do fork no service do core
RSpec.describe Enterprise::Whatsapp::IncomingMessageBaseService do
  let(:channel) { create(:channel_whatsapp, sync_templates: false, validate_provider_config: false) }
  let(:campaign) { create(:campaign, account: channel.account, inbox: channel.inbox, campaign_type: :one_off) }
  let(:status) { { 'id' => 'wamid.campaign-send', 'status' => 'delivered', 'timestamp' => '1700000600' } }

  def process_status
    Whatsapp::IncomingMessageService.new(
      inbox: channel.inbox,
      params: { 'statuses' => [status] }.with_indifferent_access
    ).perform
  end

  it 'does not forward the status of a Chatwoot campaign recipient to the ERP' do
    CampaignRecipient.create!(
      account: channel.account,
      campaign: campaign,
      contact: create(:contact, account: channel.account),
      inbox: channel.inbox,
      status: :sent,
      source_id: status['id']
    )

    expect { process_status }.not_to have_enqueued_job(Whatsapp::ForwardMessageStatusToErpJob)
  end

  it 'still forwards the status of a wamid that is neither a message nor a campaign recipient' do
    expect { process_status }.to have_enqueued_job(Whatsapp::ForwardMessageStatusToErpJob)
  end
end
# rubocop:enable RSpec/SpecFilePathFormat
