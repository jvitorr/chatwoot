# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InstallationConfig do
  subject(:installation_config) { described_class.new(name: 'INSTALLATION_NAME') }

  it { is_expected.to validate_presence_of(:name) }

  describe 'new record defaults' do
    it 'initializes serialized_value with indifferent access' do
      expect(installation_config.serialized_value).to eq({}.with_indifferent_access)
    end

    it 'returns nil for value before assignment' do
      expect(installation_config.value).to be_nil
    end
  end

  describe 'Captain LLM configuration' do
    before do
      described_class.where(name: %w[CAPTAIN_OPEN_AI_API_KEY CAPTAIN_OPEN_AI_ENDPOINT CAPTAIN_OPEN_AI_MODEL]).delete_all
      RubyLLM.configure do |config|
        config.openai_api_key = nil
        config.openai_api_base = nil
      end
      Agents.configuration.openai_api_key = nil
      Agents.configuration.openai_api_base = nil
      Llm::Config.reset!
    end

    after do
      RubyLLM.configure do |config|
        config.openai_api_key = nil
        config.openai_api_base = nil
      end
      Agents.configuration.openai_api_key = nil
      Agents.configuration.openai_api_base = nil
      Llm::Config.reset!
    end

    it 'clears stale Captain LLM endpoint when Captain endpoint is saved as blank' do
      create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: 'test-key')
      endpoint_config = create(:installation_config, name: 'CAPTAIN_OPEN_AI_ENDPOINT', value: 'https://azure.example.com/openai')

      Llm::Config.initialize!

      expect(RubyLLM.config.openai_api_base).to include('azure.example.com')
      expect(Agents.configuration.openai_api_base).to include('azure.example.com')

      endpoint_config.update!(value: '')

      expect(RubyLLM.config.openai_api_base).to be_nil
      expect(Agents.configuration.openai_api_base).to be_nil
    end
  end
end
