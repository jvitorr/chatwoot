# Dotenv loads .env in every environment, including test. A developer with a real
# AXIOM_* configuration would otherwise flip the integration on for the whole suite.
# Specs that need it enabled opt in explicitly via with_modified_env.
# OTEL_TRACES_SAMPLER* are included because OpentelemetryConfig writes them into ENV
# when it installs the sampler, and that would otherwise leak across examples.
AXIOM_ENV_KEYS = %w[
  AXIOM_API_TOKEN AXIOM_DATASET AXIOM_DOMAIN AXIOM_LOG_LEVEL
  AXIOM_TRACES_DATASET ENABLE_AXIOM_TRACES AXIOM_TRACE_RAILS AXIOM_TRACES_SAMPLE_RATE
  ENABLE_AXIOM_LOGS
  OTEL_TRACES_SAMPLER OTEL_TRACES_SAMPLER_ARG
].freeze

RSpec.configure do |config|
  config.around do |example|
    ClimateControl.modify(AXIOM_ENV_KEYS.index_with(nil)) { example.run }
  end
end
