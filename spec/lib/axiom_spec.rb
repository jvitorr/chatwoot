require 'rails_helper'

describe Axiom do
  describe '#enabled?' do
    it 'is disabled without a token' do
      expect(described_class).not_to be_enabled
    end

    it 'is enabled with a token' do
      with_modified_env AXIOM_API_TOKEN: 'xaat-token' do
        expect(described_class).to be_enabled
      end
    end
  end

  describe '#traces_enabled?' do
    it 'is false when only the flag is set' do
      with_modified_env ENABLE_AXIOM_TRACES: 'true' do
        expect(described_class).not_to be_traces_enabled
      end
    end

    it 'is false when only the token is set' do
      with_modified_env AXIOM_API_TOKEN: 'xaat-token' do
        expect(described_class).not_to be_traces_enabled
      end
    end

    it 'is true when both are set' do
      with_modified_env AXIOM_API_TOKEN: 'xaat-token', ENABLE_AXIOM_TRACES: 'true' do
        expect(described_class).to be_traces_enabled
      end
    end
  end

  describe '#logs_enabled?' do
    it 'is false when only the flag is set' do
      with_modified_env ENABLE_AXIOM_LOGS: 'true' do
        expect(described_class).not_to be_logs_enabled
      end
    end

    it 'is false with a token but no flag, so logs stay opt-in' do
      with_modified_env AXIOM_API_TOKEN: 'xaat-token' do
        expect(described_class).not_to be_logs_enabled
      end
    end

    it 'is true when both are set' do
      with_modified_env AXIOM_API_TOKEN: 'xaat-token', ENABLE_AXIOM_LOGS: 'true' do
        expect(described_class).to be_logs_enabled
      end
    end
  end

  describe '#trace_rails?' do
    it 'requires traces to be enabled' do
      with_modified_env AXIOM_API_TOKEN: 'xaat-token', AXIOM_TRACE_RAILS: 'true' do
        expect(described_class).not_to be_trace_rails
      end
    end

    it 'is true when traces and the flag are set' do
      with_modified_env AXIOM_API_TOKEN: 'xaat-token', ENABLE_AXIOM_TRACES: 'true', AXIOM_TRACE_RAILS: 'true' do
        expect(described_class).to be_trace_rails
      end
    end
  end

  describe '#traces_sample_rate' do
    it 'keeps everything when only LLM spans flow' do
      with_modified_env AXIOM_API_TOKEN: 'xaat-token', ENABLE_AXIOM_TRACES: 'true' do
        expect(described_class.traces_sample_rate).to eq 1.0
      end
    end

    it 'drops to 10% once Rails auto-instrumentation is on' do
      with_modified_env AXIOM_API_TOKEN: 'xaat-token', ENABLE_AXIOM_TRACES: 'true', AXIOM_TRACE_RAILS: 'true' do
        expect(described_class.traces_sample_rate).to eq 0.1
      end
    end

    it 'lets an explicit rate win' do
      with_modified_env AXIOM_API_TOKEN: 'xaat-token', ENABLE_AXIOM_TRACES: 'true', AXIOM_TRACE_RAILS: 'true',
                        AXIOM_TRACES_SAMPLE_RATE: '0.5' do
        expect(described_class.traces_sample_rate).to eq 0.5
      end
    end
  end

  describe 'defaults' do
    it 'falls back to the public API domain and the chatwoot dataset' do
      expect(described_class.domain).to eq 'api.axiom.co'
      expect(described_class.dataset).to eq 'chatwoot'
      expect(described_class.traces_dataset).to eq 'chatwoot'
      expect(described_class.log_level).to eq 'warn'
      expect(described_class.ingest_url).to eq 'https://api.axiom.co/v1/datasets/chatwoot/ingest'
      expect(described_class.traces_endpoint).to eq 'https://api.axiom.co/v1/traces'
    end

    it 'honours overrides' do
      with_modified_env AXIOM_DOMAIN: 'api.eu.axiom.co', AXIOM_DATASET: 'cw-prod', AXIOM_LOG_LEVEL: 'info' do
        expect(described_class.ingest_url).to eq 'https://api.eu.axiom.co/v1/datasets/cw-prod/ingest'
        expect(described_class.traces_endpoint).to eq 'https://api.eu.axiom.co/v1/traces'
        expect(described_class.traces_dataset).to eq 'cw-prod'
        expect(described_class.log_level).to eq 'info'
      end
    end

    it 'lets the traces dataset diverge from the logs dataset' do
      with_modified_env AXIOM_DATASET: 'cw-logs', AXIOM_TRACES_DATASET: 'cw-traces' do
        expect(described_class.dataset).to eq 'cw-logs'
        expect(described_class.traces_dataset).to eq 'cw-traces'
      end
    end
  end
end
