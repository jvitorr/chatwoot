# [FORK CONNECTEI] modifications/024-repasse-de-eventos-instagram-ao-erp.md
#
# POST de um evento do Instagram (comentário, referral solto) ao ERP.
#
# AUTENTICAÇÃO (contrato fork↔ERP §1.1)
# O MESMO esquema do webhook de conta (`lib/webhooks/trigger.rb#request_headers`),
# que o ERP já verifica em `flow-runtime/utils/verify-chatwoot-signature.util.ts`
# com tolerância de 300s:
#   X-Chatwoot-Timestamp: <segundos Unix>
#   X-Chatwoot-Signature: sha256=<hex HMAC-SHA256(segredo, "<timestamp>.<corpo cru>")>
# O timestamp é recalculado a cada tentativa (cada retry do job chama `perform`
# de novo), então o backoff longo nunca estoura a janela do ERP. NÃO é o
# `x-connectei-signature` da mod 001: o ERP não tem receptor para aquele esquema.
#
# RESPOSTAS (contrato §1.3)
#   2xx (202)                       → entregue (inclusive duplicado).
#   5xx, 408, 425, 429, rede, timeout → levanta RetryableError; o job tenta de novo.
#   demais 4xx (401, 422…)          → contrato quebrado: `logger.error`, sem retry.
#
# Sem `CONNECTEI_INSTAGRAM_EVENTS_URL` ou sem `CONNECTEI_INSTAGRAM_EVENTS_SECRET` o
# repasse fica desligado: registra `info` uma vez por processo e segue — a
# instância precisa funcionar sem o ERP. As duas são lidas DIRETO do ambiente
# (sem `installation_configs`, para não cair na armadilha da mod 001).
class Connectei::Instagram::EventForwarder
  class RetryableError < StandardError; end

  URL_ENV = 'CONNECTEI_INSTAGRAM_EVENTS_URL'.freeze
  SECRET_ENV = 'CONNECTEI_INSTAGRAM_EVENTS_SECRET'.freeze
  TIMEOUT_SECONDS = 10
  RETRYABLE_STATUSES = [408, 425, 429].freeze
  NETWORK_ERRORS = [
    Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH, Errno::ENETUNREACH, Errno::ETIMEDOUT, Errno::EPIPE,
    Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, SocketError, IOError, OpenSSL::SSL::SSLError
  ].freeze
  LOG_PREFIX = '[CONNECTEI][ig-forward]'.freeze

  class << self
    attr_accessor :unconfigured_logged

    def url
      ENV.fetch(URL_ENV, nil).presence&.strip
    end

    def secret
      ENV.fetch(SECRET_ENV, nil).presence
    end

    def configured?
      return true if url.present? && secret.present?

      log_unconfigured_once
      false
    end

    def sign(body, timestamp, key = secret)
      "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', key, "#{timestamp}.#{body}")}"
    end

    private

    def log_unconfigured_once
      return if unconfigured_logged

      self.unconfigured_logged = true
      missing = [URL_ENV, SECRET_ENV].select { |name| ENV.fetch(name, nil).blank? }
      Rails.logger.info("#{LOG_PREFIX} repasse desativado: #{missing.join(', ')} não configurado(s). " \
                        'Comentários e referrals do Instagram não chegam ao ERP; o resto do canal segue normal.')
    end
  end

  def initialize(payload)
    @payload = payload
  end

  # :delivered, :rejected ou :disabled (para log/teste); levanta RetryableError no transitório.
  def perform
    return :disabled unless self.class.configured?

    body = @payload.to_json
    timestamp = Time.now.to_i.to_s
    response = HTTParty.post(self.class.url, body: body, headers: headers(body, timestamp),
                                             timeout: TIMEOUT_SECONDS, follow_redirects: false)
    handle_response(response)
  rescue *NETWORK_ERRORS => e
    raise RetryableError, "ERP unreachable: #{e.class}: #{e.message}"
  end

  private

  def headers(body, timestamp)
    {
      'Content-Type' => 'application/json',
      'X-Chatwoot-Timestamp' => timestamp,
      'X-Chatwoot-Signature' => self.class.sign(body, timestamp)
    }
  end

  def handle_response(response)
    code = response.code.to_i
    return :delivered if code.between?(200, 299)
    raise RetryableError, "ERP responded #{code} for #{event_id}" if code >= 500 || RETRYABLE_STATUSES.include?(code)

    Rails.logger.error("#{LOG_PREFIX} ERP recusou #{event_id} (#{code}), sem nova tentativa: #{response.body.to_s.truncate(500)}")
    :rejected
  end

  def event_id
    @payload.to_h.with_indifferent_access[:event_id]
  end
end
