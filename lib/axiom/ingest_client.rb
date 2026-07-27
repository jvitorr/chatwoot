###############
# Posts events to the Axiom ingest API.
# ref: https://axiom.co/docs/guides/send-logs-from-ruby-on-rails
# Failures are swallowed on purpose: observability must never break the request it is observing.
############

class Axiom::IngestClient
  TIMEOUT = 5

  class << self
    def push(events)
      events = Array.wrap(events)
      return if events.blank? || !Axiom.enabled?

      connection.post(Axiom.ingest_url, events.map { |event| decorate(event) }.to_json)
    rescue StandardError => e
      Rails.logger.warn "Axiom ingest failed: #{e.message}"
    end

    private

    def decorate(event)
      {
        _time: Time.current.iso8601,
        service: 'chatwoot',
        environment: Rails.env,
        git_sha: defined?(GIT_HASH) ? GIT_HASH : nil
      }.merge(event.symbolize_keys).compact
    end

    def connection
      Faraday.new(headers: headers) do |conn|
        conn.options.timeout = TIMEOUT
        conn.options.open_timeout = TIMEOUT
      end
    end

    def headers
      {
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer #{Axiom.token}"
      }
    end
  end
end
