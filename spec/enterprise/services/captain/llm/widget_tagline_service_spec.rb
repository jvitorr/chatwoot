require 'rails_helper'

RSpec.describe Captain::Llm::WidgetTaglineService do
  let(:account) do
    create(:account, name: 'Acme', custom_attributes: {
             'brand_info' => {
               'title' => 'Acme Corp',
               'description' => 'Leading tech company',
               'slogan' => 'We build things',
               'industries' => [{ 'industry' => 'Technology', 'subindustry' => 'Software' }]
             }
           })
  end
  let(:service) { described_class.new(account: account) }

  before do
    create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'test-key')
  end

  describe '#perform' do
    it 'returns the stripped tagline message' do
      allow(service).to receive(:make_api_call).and_return(message: '  Smart support for your business  ')
      expect(service.perform).to include(message: 'Smart support for your business')
    end

    it 'forwards account name and brand context to the LLM prompt' do
      expect(service).to receive(:make_api_call) do |args|
        expect(args[:messages][0][:content]).to include('chat widget')
        user_content = args[:messages][1][:content]
        expect(user_content).to include('Company: Acme')
        expect(user_content).to include('Title: Acme Corp')
        expect(user_content).to include('Slogan: We build things')
        expect(user_content).to include('Industries: Technology')
        { message: 'tagline' }
      end

      service.perform
    end

    it 'returns the error hash unchanged when the LLM call fails' do
      allow(service).to receive(:make_api_call).and_return(error: 'LLM timeout', error_code: 500)
      expect(service.perform).to eq(error: 'LLM timeout', error_code: 500)
    end

    context 'when brand_info is empty' do
      let(:account) { create(:account, name: 'Acme') }

      it 'still builds a prompt from the account name alone' do
        expect(service).to receive(:make_api_call) do |args|
          expect(args[:messages][1][:content]).to eq('Company: Acme')
          { message: 'Tagline' }
        end

        service.perform
      end
    end
  end

  describe 'gating overrides' do
    it 'always uses the system OpenAI credential' do
      expect(service.send(:llm_credential)).to eq(api_key: 'test-key', source: :system)
    end

    it 'bypasses the captain_tasks per-account feature flag' do
      expect(service.send(:captain_tasks_enabled?)).to be(true)
    end

    it 'opts out of usage metering via counts_toward_usage?' do
      expect(service.send(:counts_toward_usage?)).to be(false)
    end
  end

  describe 'usage metering' do
    before do
      allow(account).to receive(:feature_enabled?).and_call_original
      allow(account).to receive(:feature_enabled?).with('captain_tasks').and_return(true)
      allow(service).to receive(:make_api_call).and_return(message: 'A tagline')
    end

    it 'does not increment captain_responses_usage on success' do
      expect(account).not_to receive(:increment_response_usage)
      service.perform
    end
  end
end
