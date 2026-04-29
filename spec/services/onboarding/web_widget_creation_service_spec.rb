require 'rails_helper'

RSpec.describe Onboarding::WebWidgetCreationService do
  let(:account) { create(:account, name: 'Acme Inc', domain: 'acme.com') }
  let(:user) { create(:user) }
  let(:service) { described_class.new(account, user) }

  before { create(:account_user, account: account, user: user, role: :administrator) }

  describe '#perform' do
    context 'with a website_url available' do
      it 'creates a Channel::WebWidget' do
        expect { service.perform }.to change(Channel::WebWidget, :count).by(1)
      end

      it 'creates an inbox named after the account' do
        inbox = service.perform
        expect(inbox.name).to eq('Acme Inc')
        expect(inbox.channel_type).to eq('Channel::WebWidget')
      end

      it 'adds the user as an inbox member' do
        inbox = service.perform
        expect(inbox.inbox_members.pluck(:user_id)).to include(user.id)
      end

      it 'returns the inbox' do
        expect(service.perform).to be_a(Inbox)
      end
    end

    context 'when website_url cannot be derived from account.domain or brand_info' do
      let(:account) { create(:account, name: 'Acme Inc', domain: nil) }

      it 'returns nil without creating any records' do
        expect { service.perform }.not_to change(Inbox, :count)
        expect(service.perform).to be_nil
      end
    end

    context 'when account.domain is blank but brand_info has a domain' do
      let(:account) do
        create(:account, name: 'Acme Inc', domain: nil, custom_attributes: {
                 'brand_info' => { 'domain' => 'fallback.com' }
               })
      end

      it 'falls back to brand_info[:domain]' do
        expect(service.perform.channel.website_url).to eq('fallback.com')
      end
    end

    context 'when brand_info has populated values' do
      let(:account) do
        create(:account, name: 'Acme Inc', domain: 'acme.com', custom_attributes: {
                 'brand_info' => {
                   'title' => 'Acme Corp',
                   'colors' => [{ 'hex' => '#FF5733' }],
                   'slogan' => 'We build things',
                   'description' => 'Leading tech company'
                 }
               })
      end

      it 'sets widget_color, welcome_title, welcome_tagline from brand_info' do
        channel = service.perform.channel
        expect(channel.widget_color).to eq('#FF5733')
        expect(channel.welcome_title).to eq('Acme Corp')
        expect(channel.welcome_tagline).to eq('We build things')
      end
    end

    context 'when brand_info is empty' do
      it 'falls back to defaults' do
        channel = service.perform.channel
        expect(channel.widget_color).to eq(described_class::DEFAULT_WIDGET_COLOR)
        expect(channel.welcome_title).to eq('Acme Inc')
        expect(channel.welcome_tagline).to be_nil
      end
    end

    context 'when brand_info color is not a valid hex' do
      let(:account) do
        create(:account, domain: 'acme.com', custom_attributes: {
                 'brand_info' => { 'colors' => [{ 'hex' => 'rgb(255,0,0)' }] }
               })
      end

      it 'falls back to the default widget color' do
        expect(service.perform.channel.widget_color).to eq(described_class::DEFAULT_WIDGET_COLOR)
      end
    end

    context 'when brand_info has only description' do
      let(:account) do
        create(:account, domain: 'acme.com', custom_attributes: {
                 'brand_info' => { 'description' => 'Customer support assistant' }
               })
      end

      it 'uses the description as the welcome tagline' do
        expect(service.perform.channel.welcome_tagline).to eq('Customer support assistant')
      end
    end

    context 'when channel creation raises' do
      before do
        web_widgets = instance_double(Channel::WebWidget.const_get(:ActiveRecord_Associations_CollectionProxy))
        allow(account).to receive(:web_widgets).and_return(web_widgets)
        allow(web_widgets).to receive(:create!).and_raise(ActiveRecord::RecordInvalid)
      end

      it 'returns nil and rolls back the transaction' do
        expect { service.perform }.not_to change(Inbox, :count)
        expect(service.perform).to be_nil
      end
    end
  end
end
