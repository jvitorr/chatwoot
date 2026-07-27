# The gate reads ENV directly: at this point nothing under lib/ is autoloadable yet,
# and the middleware stack is built before the autoloader is set up.
if ENV['AXIOM_API_TOKEN'].present?
  # Capture unhandled request exceptions. This has to sit *below* DebugExceptions:
  # DebugExceptions rescues and renders the error page without re-raising, so anything
  # placed above it never sees the exception. Same reason sentry-rails puts its
  # RescuedExceptionInterceptor here.
  middleware_path = Rails.root.join('lib/axiom_capture_exceptions.rb')
  Rails.autoloaders.main.ignore(middleware_path)
  require middleware_path.to_s

  Rails.application.config.app_middleware.insert_after(
    ActionDispatch::DebugExceptions, AxiomCaptureExceptions
  )

  # Capture failed Sidekiq jobs. Reporting an Axiom::IngestJob failure would enqueue
  # another IngestJob, so that one is skipped to avoid a feedback loop.
  Sidekiq.configure_server do |config|
    config.error_handlers << lambda do |exception, context, _config|
      job_class = context.dig(:job, 'wrapped') || context.dig(:job, 'class')
      next if job_class.to_s.include?('Axiom::IngestJob')

      Axiom::Reporter.report(exception, context: context)
    end
  end

  Rails.application.config.after_initialize do
    # Ship application logs to Axiom alongside the existing stdout logger. Gated on its
    # own flag rather than on Rails.env, so it can be exercised outside production
    # before being turned on there.
    Rails.logger.broadcast_to(Axiom.logger) if Axiom.logs_enabled?

    # OpentelemetryConfig is lazy by design, but auto-instrumentation has to be
    # installed at boot to wrap Rails/ActiveRecord/HTTP.
    OpentelemetryConfig.initialize! if Axiom.trace_rails?
  end
end
