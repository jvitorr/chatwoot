###############
# Configuration resolver for the Axiom (https://axiom.co) integration.
# Everything is gated on AXIOM_API_TOKEN, so the integration is inert unless explicitly configured.
############

module Axiom
  module_function

  def enabled?
    ENV['AXIOM_API_TOKEN'].present?
  end

  def traces_enabled?
    enabled? && ENV['ENABLE_AXIOM_TRACES'].present?
  end

  # Log shipping has its own switch so exceptions and traces can be adopted first.
  def logs_enabled?
    enabled? && ENV['ENABLE_AXIOM_LOGS'].present?
  end

  def trace_rails?
    traces_enabled? && ENV['AXIOM_TRACE_RAILS'].present?
  end

  def token
    ENV.fetch('AXIOM_API_TOKEN', nil)
  end

  def domain
    ENV.fetch('AXIOM_DOMAIN', 'api.axiom.co')
  end

  def dataset
    ENV.fetch('AXIOM_DATASET', 'chatwoot')
  end

  def traces_dataset
    ENV.fetch('AXIOM_TRACES_DATASET', dataset)
  end

  def log_level
    ENV.fetch('AXIOM_LOG_LEVEL', 'warn')
  end

  # Auto-instrumenting Rails emits a span per query, so the default drops to 10%.
  # With only LLM spans flowing the volume is low and everything is kept.
  def traces_sample_rate
    ENV.fetch('AXIOM_TRACES_SAMPLE_RATE') { trace_rails? ? '0.1' : '1.0' }.to_f
  end

  def ingest_url
    "https://#{domain}/v1/datasets/#{dataset}/ingest"
  end

  def traces_endpoint
    "https://#{domain}/v1/traces"
  end

  def logger
    @logger ||= Axiom::Logger.build
  end
end
