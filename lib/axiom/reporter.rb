###############
# Single entry point for sending an exception to Axiom.
# Kept separate from ChatwootExceptionTracker so the Rack middleware and the Sidekiq
# error handler can report to Axiom without also re-reporting to Sentry, which
# installs its own middleware and server handler.
############

class Axiom::Reporter
  def self.report(exception, user: nil, account: nil, request: nil, context: nil)
    return unless Axiom.enabled?

    event = Axiom::ExceptionEvent.new(exception, user: user, account: account, request: request, context: context).to_h
    Axiom::IngestJob.perform_later([event])
  rescue StandardError => e
    Rails.logger.warn "Axiom exception capture failed: #{e.message}"
  end
end
