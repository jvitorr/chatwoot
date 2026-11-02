require 'rails_helper'

# [FORK CONNECTEI] modifications/024 — o motivo da modificação: com `campaigns` desligado,
# o status de WhatsApp de um wamid órfão (disparo do ERP direto na Graph API) deixa de
# enfileirar Campaigns::UpdateRecipientStatusJob.
RSpec.describe Connectei::DisableNativeCampaigns do
  let(:channel) { create(:channel_whatsapp, sync_templates: false, validate_provider_config: false) }
  let(:status) { { 'id' => 'wamid.erp-direct-send', 'status' => 'delivered', 'timestamp' => '1700000600' } }

  def process_orphan_status
    Whatsapp::IncomingMessageService.new(
      inbox: Inbox.find(channel.inbox.id),
      params: { 'statuses' => [status] }.with_indifferent_access
    ).perform
  end

  before { channel.account.enable_features!(:campaigns) }

  it 'enqueues the recipient status job while campaigns is on (baseline)' do
    expect { process_orphan_status }.to have_enqueued_job(Campaigns::UpdateRecipientStatusJob)
  end

  it 'no longer enqueues the recipient status job after perform' do
    described_class.new.perform

    expect { process_orphan_status }.not_to have_enqueued_job(Campaigns::UpdateRecipientStatusJob)
  end

  it 'still forwards the orphan status to the ERP after perform' do
    described_class.new.perform

    expect { process_orphan_status }.to have_enqueued_job(Whatsapp::ForwardMessageStatusToErpJob)
  end
end
