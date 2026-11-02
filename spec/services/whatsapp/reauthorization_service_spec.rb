require 'rails_helper'

RSpec.describe Whatsapp::ReauthorizationService do
  let(:account) { create(:account) }
  let(:channel) do
    create(
      :channel_whatsapp,
      account: account,
      provider: 'whatsapp_cloud',
      provider_config: {
        'api_key' => 'old-token',
        'phone_number_id' => 'old-phone-id',
        'business_account_id' => 'old-waba-id',
        'source' => 'embedded_signup'
      },
      business_management_token: 'business-token',
      validate_provider_config: false,
      sync_templates: false
    )
  end
  let(:inbox) { create(:inbox, account: account, channel: channel) }
  let(:phone_info) { { phone_number: channel.phone_number, business_name: inbox.name } }

  before do
    stub_request(:get, %r{\Ahttps://graph\.facebook\.com/v14\.0/.+/message_templates\?access_token=new-token\z})
      .to_return(status: 200, body: { data: [] }.to_json, headers: { 'Content-Type' => 'application/json' })
    stub_request(:get, %r{\Ahttps://graph\.facebook\.com/v14\.0/.+/phone_numbers\?.*access_token=new-token})
      .to_return(status: 200, body: { data: [{ id: 'new-phone-id' }] }.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  it 'clears the business management token when the WhatsApp Business Account changes' do
    described_class.new(
      account: account,
      inbox_id: inbox.id,
      phone_number_id: 'new-phone-id',
      waba_id: 'new-waba-id'
    ).perform('new-token', phone_info)

    expect(channel.reload.business_management_token).to be_nil
  end

  it 'retains the business management token when the WhatsApp Business Account does not change' do
    described_class.new(
      account: account,
      inbox_id: inbox.id,
      phone_number_id: 'new-phone-id',
      waba_id: channel.provider_config['business_account_id']
    ).perform('new-token', phone_info)

    expect(channel.reload.business_management_token).to eq('business-token')
  end

  # [FORK CONNECTEI] reauth grava o WABA id em business_account_id (PR #6).
  context 'when the channel is reauthorized with a WABA id' do
    let(:channel) do
      create(:channel_whatsapp, account: account, phone_number: '+5579936182380', provider: 'whatsapp_cloud',
                                validate_provider_config: false, sync_templates: false)
    end
    let(:inbox) { channel.inbox }
    let(:phone_info) do
      {
        phone_number_id: 'new_phone_number_id',
        phone_number: '+5579936182380',
        business_name: 'Aracaju WhatsApp'
      }
    end
    let(:service) do
      described_class.new(
        account: account,
        inbox_id: inbox.id,
        phone_number_id: 'new_phone_number_id',
        waba_id: '1973751103573954'
      )
    end

    describe '#perform' do
      before do
        # Meta only exposes the message_templates edge on a WABA. Pointing the check at the
        # Business Manager id is what made every reauthorization fail with "Invalid Credentials".
        stub_request(:get, %r{graph\.facebook\.com/v14\.0/1973751103573954/message_templates})
          .to_return(status: 200, body: { data: [] }.to_json, headers: { 'Content-Type' => 'application/json' })
        # Since 4.16 the provider check also confirms the phone number belongs to the WABA.
        stub_request(:get, %r{graph\.facebook\.com/v14\.0/1973751103573954/phone_numbers})
          .to_return(status: 200, body: { data: [{ id: 'new_phone_number_id' }] }.to_json,
                     headers: { 'Content-Type' => 'application/json' })
        stub_request(:get, %r{graph\.facebook\.com/v14\.0/836920726405540/message_templates})
          .to_return(status: 400, body: { error: { message: 'Unsupported get request' } }.to_json,
                     headers: { 'Content-Type' => 'application/json' })
      end

      it 'stores the waba id as business_account_id so validate_provider_config hits the WABA edge' do
        service.perform('new_access_token', phone_info)

        expect(channel.reload.provider_config).to include(
          'api_key' => 'new_access_token',
          'phone_number_id' => 'new_phone_number_id',
          'business_account_id' => '1973751103573954',
          'source' => 'embedded_signup'
        )
      end

      it 'renames the inbox with the business name' do
        service.perform('new_access_token', phone_info)

        expect(inbox.reload.name).to eq('Aracaju WhatsApp')
      end

      it 'raises when the reauthorized phone number does not match the channel' do
        expect do
          service.perform('new_access_token', phone_info.merge(phone_number: '+5579900000000'))
        end.to raise_error(StandardError, /Phone number mismatch/)
      end
    end
  end
end
