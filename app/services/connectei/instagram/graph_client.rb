# [FORK CONNECTEI] modifications/026-endpoints-connectei-instagram.md
#
# Chamadas à Graph do Instagram feitas pelos endpoints `connectei-instagram`, com
# o token do canal (o ERP não guarda o token — mod 003). Base e timeouts de
# `Connectei::Instagram::Graph` (mod 028).
#
# Toda falha vira `GraphClient::Error`, já no formato do contrato fork↔ERP §2.1:
#   { "error": { "kind", "code", "subcode", "message", "retry_after" } } + HTTP
#
# Timeout depois de enviar: numa escrita (POST/DELETE) o efeito pode ter
# acontecido — `ambiguous` (504), e o ERP relê antes de tentar de novo. Numa
# leitura não há efeito — `unavailable` (503).
class Connectei::Instagram::GraphClient
  class Error < StandardError
    attr_reader :kind, :http_status, :code, :subcode, :retry_after

    def self.invalid(message)
      new(kind: :invalid, http_status: 422, message: message)
    end

    # `details`: `code`, `subcode` (da Meta) e `retry_after` (segundos), todos opcionais.
    def initialize(kind:, http_status:, message:, **details)
      @kind = kind
      @http_status = http_status
      @code = details[:code]
      @subcode = details[:subcode]
      @retry_after = details[:retry_after]
      super(message)
    end

    def as_json(*)
      { error: { kind: kind.to_s, code: code, subcode: subcode, message: message, retry_after: retry_after } }
    end
  end

  NOT_SENT_ERRORS = [
    Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, SocketError, OpenSSL::SSL::SSLError
  ].freeze
  AMBIGUOUS_ERRORS = [Net::ReadTimeout, Net::WriteTimeout, Errno::ECONNRESET, Errno::EPIPE, IOError].freeze
  DEFAULT_RETRY_AFTER = 60

  def initialize(channel)
    @channel = channel
  end

  def get(path, query: {})
    request(:get, path, query: query)
  end

  # `rate_limited: true` passa pelo limitador por conta (mod 025) antes da Graph.
  def post(path, query: {}, json: nil, rate_limited: false)
    acquire_send_slot! if rate_limited
    request(:post, path, query: query, json: json)
  end

  def delete(path, query: {})
    request(:delete, path, query: query)
  end

  private

  def request(method, path, query:, json: nil)
    options = { query: query.merge(access_token: @channel.access_token), follow_redirects: false, **Connectei::Instagram::Graph::TIMEOUTS }
    if json
      options[:body] = json.to_json
      options[:headers] = { 'Content-Type' => 'application/json' }
    end
    handle_response(HTTParty.public_send(method, "#{Connectei::Instagram::Graph.versioned_base_url}/#{path}", **options))
  rescue *NOT_SENT_ERRORS => e
    raise Error.new(kind: :unavailable, http_status: 503, message: "Graph unreachable (#{e.class})", retry_after: 1)
  rescue *AMBIGUOUS_ERRORS => e
    raise transport_ambiguity(method, e)
  end

  def handle_response(response)
    parsed = parse(response)
    return parsed if response.success? && parsed.is_a?(Hash) && parsed['error'].blank?

    raise graph_error(response, parsed)
  end

  def graph_error(response, parsed)
    details = Connectei::Instagram::GraphError.details(parsed)
    kind, status = Connectei::Instagram::GraphError.endpoint_error(details[:code], response.code)
    @channel.authorization_error! if kind == :reauthorization_required

    Error.new(kind: kind, http_status: status, code: details[:code], subcode: details[:subcode],
              message: details[:message] || "Graph HTTP #{response.code}",
              retry_after: kind == :rate_limited ? meta_retry_after(response) : nil)
  end

  def transport_ambiguity(method, error)
    return Error.new(kind: :unavailable, http_status: 503, message: "Graph timeout (#{error.class})", retry_after: 1) if method == :get

    Error.new(kind: :ambiguous, http_status: 504, message: "Graph timeout after sending (#{error.class}); the effect may have happened")
  end

  def acquire_send_slot!
    decision = Connectei::Instagram::RateLimiter.new(@channel.instagram_id).acquire_send
    return if decision.allowed?

    raise Error.new(kind: :rate_limited, http_status: 429, message: 'Connectei send limit reached for this Instagram account',
                    retry_after: decision.retry_after)
  end

  def parse(response)
    parsed = response.parsed_response
    parsed.is_a?(String) ? JSON.parse(parsed) : parsed
  rescue JSON::ParserError
    nil
  end

  # A Meta informa o tempo para recuperar o acesso (em minutos) no cabeçalho de
  # uso; sem ele, um minuto.
  def meta_retry_after(response)
    usage = JSON.parse(response.headers['x-business-use-case-usage'].to_s)
    minutes = usage.values.flatten.filter_map { |entry| entry.is_a?(Hash) ? entry['estimated_time_to_regain_access'].to_i : nil }.max
    minutes.to_i.positive? ? minutes * 60 : DEFAULT_RETRY_AFTER
  rescue JSON::ParserError, NoMethodError, TypeError
    DEFAULT_RETRY_AFTER
  end
end
