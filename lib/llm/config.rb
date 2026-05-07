require 'ruby_llm'
require 'agents'

module Llm::Config
  DEFAULT_MODEL = 'gpt-4.1-mini'.freeze

  class << self
    def initialized?
      @initialized ||= false
    end

    def initialize!
      return if @initialized

      refresh!
    end

    def reset!
      @initialized = false
    end

    def refresh!
      settings = resolved_settings
      configure_agents(settings)
      configure_ruby_llm(settings)
      @initialized = true
    end

    def with_api_key(api_key, api_base: nil)
      initialize!
      context = RubyLLM.context do |config|
        config.openai_api_key = api_key
        config.openai_api_base = api_base
      end

      yield context
    end

    private

    def configure_ruby_llm(settings)
      RubyLLM.configure do |config|
        config.openai_api_key = settings[:api_key]
        config.openai_api_base = settings[:api_base]
        config.default_model = settings[:model]
        config.model_registry_file = Rails.root.join('config/llm_models.json').to_s
        config.logger = Rails.logger
      end
    end

    def configure_agents(settings)
      Agents.configure do |config|
        config.openai_api_key = settings[:api_key]
        config.openai_api_base = settings[:api_base]
        config.default_model = settings[:model]
        config.debug = false
      end
    end

    def resolved_settings
      {
        api_key: system_api_key.presence,
        api_base: openai_api_base,
        model: system_model
      }
    end

    def system_api_key
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value
    end

    def openai_endpoint
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_ENDPOINT')&.value
    end

    def openai_api_base
      endpoint = openai_endpoint.presence&.chomp('/')
      return if endpoint.blank?

      endpoint.end_with?('/v1') ? endpoint : "#{endpoint}/v1"
    end

    def system_model
      InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_MODEL')&.value.presence || LlmConstants::DEFAULT_MODEL
    end
  end
end
