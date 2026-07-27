###############
# Rack middleware that reports unhandled exceptions to Axiom, mirroring
# Sentry::Rails::CaptureExceptions. Without this only the explicit
# ChatwootExceptionTracker call sites are covered, which misses every unexpected 500.
#
# The middleware stack is built before the autoloader is ready, so this file is
# required explicitly by config/initializers/axiom.rb and deliberately sits outside
# the autoloaded Axiom namespace. Axiom::Reporter is only referenced at request time,
# by which point autoloading works.
############

class AxiomCaptureExceptions
  # Routine 4xx conditions, not defects. Mirrors sentry-ruby's default ignore list
  # plus the exclusions already configured in config/initializers/sentry.rb.
  IGNORED_EXCEPTIONS = %w[
    AbstractController::ActionNotFound
    ActionController::BadRequest
    ActionController::InvalidAuthenticityToken
    ActionController::InvalidCrossOriginRequest
    ActionController::MethodNotAllowed
    ActionController::ParameterMissing
    ActionController::RoutingError
    ActionController::UnknownAction
    ActionController::UnknownFormat
    ActionController::UnknownHttpMethod
    ActionDispatch::Http::MimeNegotiation::InvalidType
    ActiveRecord::RecordNotFound
    Rack::QueryParser::InvalidParameterError
    Rack::QueryParser::ParameterTypeError
    Rack::Timeout::RequestTimeoutException
  ].freeze

  def initialize(app)
    @app = app
  end

  # rubocop:disable Lint/RescueException
  def call(env)
    @app.call(env)
  rescue Exception => e
    report(e, env)
    raise
  end
  # rubocop:enable Lint/RescueException

  private

  def report(exception, env)
    return if IGNORED_EXCEPTIONS.include?(exception.class.name)

    Axiom::Reporter.report(exception, request: ActionDispatch::Request.new(env))
  end
end
