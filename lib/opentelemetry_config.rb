require 'opentelemetry/sdk'
require 'opentelemetry/exporter/otlp'
require 'base64'

# [FORK CONNECTEI] Refatorado de single-provider (Langfuse) para multi-provider.
# Ver modifications/004-integracao-axiom.md antes de reconciliar um merge de upstream.
module OpentelemetryConfig
  # These instrumentations raise during install on Rails 7.1, so they are opted out of use_all.
  UNSUPPORTED_INSTRUMENTATIONS = {
    'OpenTelemetry::Instrumentation::ActionMailer' => { enabled: false },
    'OpenTelemetry::Instrumentation::ActionPack' => { enabled: false },
    'OpenTelemetry::Instrumentation::ActiveStorage' => { enabled: false }
  }.freeze

  class << self
    def tracer
      initialize! unless initialized?
      OpenTelemetry.tracer_provider.tracer('chatwoot')
    end

    def initialized?
      @initialized ||= false
    end

    def initialize!
      return if @initialized

      @provider = resolve_provider
      return mark_initialized if @provider.blank?

      configure_opentelemetry
      mark_initialized
    rescue StandardError => e
      Rails.logger.error "Failed to configure OpenTelemetry: #{e.message}"
      mark_initialized
    end

    def reset!
      @initialized = false
      @provider = nil
    end

    private

    def mark_initialized
      @initialized = true
    end

    def resolve_provider
      return :axiom if Axiom.traces_enabled?
      return :langfuse if langfuse_provider? && langfuse_credentials_present?

      nil
    end

    def langfuse_provider?
      otel_provider = InstallationConfig.find_by(name: 'OTEL_PROVIDER')&.value
      otel_provider == 'langfuse'
    end

    def langfuse_credentials_present?
      return true if langfuse_credentials.values.all?(&:present?)

      Rails.logger.error 'OpenTelemetry disabled (LANGFUSE_BASE_URL, LANGFUSE_PUBLIC_KEY or LANGFUSE_SECRET_KEY is missing)'
      false
    end

    def langfuse_credentials
      {
        endpoint: InstallationConfig.find_by(name: 'LANGFUSE_BASE_URL')&.value,
        public_key: InstallationConfig.find_by(name: 'LANGFUSE_PUBLIC_KEY')&.value,
        secret_key: InstallationConfig.find_by(name: 'LANGFUSE_SECRET_KEY')&.value
      }
    end

    def exporter_config
      @provider == :axiom ? axiom_exporter_config : langfuse_exporter_config
    end

    def axiom_exporter_config
      {
        endpoint: Axiom.traces_endpoint,
        headers: {
          'Authorization' => "Bearer #{Axiom.token}",
          'X-AXIOM-DATASET' => Axiom.traces_dataset
        }
      }
    end

    def langfuse_exporter_config
      credentials = langfuse_credentials
      auth_header = Base64.strict_encode64("#{credentials[:public_key]}:#{credentials[:secret_key]}")

      config = {
        endpoint: "#{credentials[:endpoint]}/api/public/otel/v1/traces",
        headers: {
          'Authorization' => "Basic #{auth_header}",
          'x-langfuse-ingestion-version' => '4'
        }
      }

      config[:ssl_verify_mode] = OpenSSL::SSL::VERIFY_NONE if Rails.env.development?
      config
    end

    def configure_opentelemetry
      OpenTelemetry::SDK.configure do |c|
        c.service_name = 'chatwoot'
        install_sampler
        install_auto_instrumentation(c)
        exporter = OpenTelemetry::Exporter::OTLP::Exporter.new(**exporter_config)
        c.add_span_processor(OpenTelemetry::SDK::Trace::Export::BatchSpanProcessor.new(exporter))
        Rails.logger.info "OpenTelemetry initialized and configured to export to #{@provider}"
      end
    end

    # The SDK resolves its sampler from these standard OTel variables when it builds
    # the tracer provider. An operator-set value always wins.
    def install_sampler
      return unless @provider == :axiom

      ENV['OTEL_TRACES_SAMPLER'] ||= 'parentbased_traceidratio'
      ENV['OTEL_TRACES_SAMPLER_ARG'] ||= Axiom.traces_sample_rate.to_s
    end

    def install_auto_instrumentation(config)
      return unless Axiom.trace_rails?

      require 'opentelemetry/instrumentation/all'
      config.use_all(UNSUPPORTED_INSTRUMENTATIONS)
    end
  end
end
