require 'rails_helper'

describe OpentelemetryConfig do
  before { described_class.reset! }

  after { described_class.reset! }

  # InstallationConfig rows may already be seeded, so upsert instead of create.
  def configure_langfuse
    {
      'OTEL_PROVIDER' => 'langfuse',
      'LANGFUSE_BASE_URL' => 'https://us.cloud.langfuse.com',
      'LANGFUSE_PUBLIC_KEY' => 'pk',
      'LANGFUSE_SECRET_KEY' => 'sk'
    }.each { |name, value| InstallationConfig.find_or_initialize_by(name: name).update!(value: value) }
  end

  describe 'provider resolution' do
    it 'stays a no-op when no provider is configured' do
      expect(described_class).not_to receive(:configure_opentelemetry)

      described_class.initialize!

      expect(described_class).to be_initialized
    end

    it 'uses axiom when traces are enabled' do
      with_modified_env AXIOM_API_TOKEN: 'xaat-token', ENABLE_AXIOM_TRACES: 'true', AXIOM_TRACES_DATASET: 'cw-traces' do
        expect(OpenTelemetry::Exporter::OTLP::Exporter).to receive(:new).with(
          endpoint: 'https://api.axiom.co/v1/traces',
          headers: {
            'Authorization' => 'Bearer xaat-token',
            'X-AXIOM-DATASET' => 'cw-traces'
          }
        ).and_call_original

        described_class.initialize!
      end
    end

    it 'keeps the langfuse path when axiom traces are off' do
      configure_langfuse

      expect(OpenTelemetry::Exporter::OTLP::Exporter).to receive(:new) do |config|
        expect(config[:endpoint]).to eq 'https://us.cloud.langfuse.com/api/public/otel/v1/traces'
        expect(config[:headers]['Authorization']).to eq "Basic #{Base64.strict_encode64('pk:sk')}"
      end.and_call_original

      described_class.initialize!
    end

    it 'prefers axiom over a configured langfuse provider' do
      configure_langfuse

      with_modified_env AXIOM_API_TOKEN: 'xaat-token', ENABLE_AXIOM_TRACES: 'true' do
        expect(OpenTelemetry::Exporter::OTLP::Exporter).to receive(:new) do |config|
          expect(config[:endpoint]).to eq 'https://api.axiom.co/v1/traces'
        end.and_call_original

        described_class.initialize!
      end
    end
  end

  describe 'sampling' do
    it 'installs a ratio sampler for axiom' do
      with_modified_env AXIOM_API_TOKEN: 'xaat-token', ENABLE_AXIOM_TRACES: 'true', AXIOM_TRACES_SAMPLE_RATE: '0.25' do
        described_class.initialize!

        expect(ENV.fetch('OTEL_TRACES_SAMPLER', nil)).to eq 'parentbased_traceidratio'
        expect(ENV.fetch('OTEL_TRACES_SAMPLER_ARG', nil)).to eq '0.25'
      end
    end

    it 'leaves an operator-set sampler alone' do
      with_modified_env AXIOM_API_TOKEN: 'xaat-token', ENABLE_AXIOM_TRACES: 'true', OTEL_TRACES_SAMPLER: 'always_on' do
        described_class.initialize!

        expect(ENV.fetch('OTEL_TRACES_SAMPLER', nil)).to eq 'always_on'
      end
    end

    it 'does not touch sampling on the langfuse path' do
      configure_langfuse
      described_class.initialize!

      expect(ENV.fetch('OTEL_TRACES_SAMPLER', nil)).to be_nil
    end
  end

  describe '#tracer' do
    it 'initializes lazily and returns a tracer' do
      expect(described_class.tracer).to respond_to(:in_span)
      expect(described_class).to be_initialized
    end
  end
end
