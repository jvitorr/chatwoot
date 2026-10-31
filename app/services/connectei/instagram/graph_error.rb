# [FORK CONNECTEI] modifications/025-envio-entrada-e-erro-instagram.md
#
# Classificação dos erros da Graph do Instagram. Funções puras: a mesma tabela
# serve ao envio de mensagem (contrato fork↔ERP §4, `external_error_kind`) e aos
# endpoints `connectei-instagram` (contrato §2.1, `error.kind` + HTTP).
#
# Os códigos vêm da documentação pública da Meta (Graph API / Instagram Messaging).
# O código exato de "comentário já respondido" e de "comentário oculto" só uma
# conta real confirma — por isso o ERP recebe também `code`/`subcode` crus.
module Connectei::Instagram::GraphError
  RATE_LIMIT_CODES = [4, 17, 32, 613, 80_002].freeze
  TOKEN_CODE = 190
  CONSENT_CODE = 230
  NOT_FOUND_CODES = [100, 33].freeze
  USER_UNAVAILABLE_CODE = 551
  USER_NOT_FOUND_SUBCODES = [2_534_014, 2_018_001].freeze
  WINDOW_CLOSED = { code: 10, subcode: 2_534_022 }.freeze

  MESSAGE_KINDS = %w[window_closed rate_limited user_unavailable comment_unavailable token unknown].freeze

  # Código da Meta → `[kind, HTTP]` dos endpoints (contrato §2.1). O que não está
  # aqui cai nas regras de `endpoint_error` (permissão, 5xx, inválido).
  ENDPOINT_ERRORS_BY_CODE = RATE_LIMIT_CODES.index_with { [:rate_limited, 429] }.merge(
    TOKEN_CODE => [:reauthorization_required, 403],
    CONSENT_CODE => [:consent_required, 409],
    100 => [:not_found, 404], 33 => [:not_found, 404],
    1 => [:unavailable, 503], 2 => [:unavailable, 503]
  ).freeze

  module_function

  # `{ code:, subcode:, message: }` a partir do corpo da Graph (Hash ou JSON cru).
  def details(parsed_response)
    parsed = parsed_response.is_a?(String) ? safe_json(parsed_response) : parsed_response
    error = parsed.is_a?(Hash) ? parsed.with_indifferent_access[:error] : nil
    error = {} unless error.is_a?(Hash)

    { code: integer_or_nil(error[:code]), subcode: integer_or_nil(error[:error_subcode]), message: error[:message].presence }
  end

  # `external_error_kind` de uma mensagem que falhou na Graph (contrato §4).
  def message_kind(code, subcode, private_reply: false)
    return 'unknown' if code.nil?
    return 'token' if code == TOKEN_CODE
    return 'rate_limited' if RATE_LIMIT_CODES.include?(code)

    private_reply ? private_reply_kind(code, subcode) : regular_message_kind(code, subcode)
  end

  def regular_message_kind(code, subcode)
    return 'window_closed' if code == WINDOW_CLOSED[:code] && subcode == WINDOW_CLOSED[:subcode]
    return 'user_unavailable' if user_unavailable?(code, subcode)

    'unknown'
  end

  # Private reply tem regra própria: o "fora da janela" dele é o prazo de 7 dias do
  # comentário, e objeto inexistente é o comentário apagado. Os dois viram
  # `comment_unavailable` — o comentário não aceita mais resposta privada.
  def private_reply_kind(code, subcode)
    return 'comment_unavailable' if NOT_FOUND_CODES.include?(code) || (code == WINDOW_CLOSED[:code] && subcode.present?)
    return 'user_unavailable' if user_unavailable?(code, subcode)

    'unknown'
  end

  # `[kind, http_status]` dos endpoints `connectei-instagram` (contrato §2.1).
  def endpoint_error(code, http_status)
    return ENDPOINT_ERRORS_BY_CODE[code] if ENDPOINT_ERRORS_BY_CODE.key?(code)
    return [:permission_denied, 403] if permission_code?(code)
    return [:unavailable, 503] if http_status.to_i >= 500

    [:invalid, 422]
  end

  def user_unavailable?(code, subcode)
    code == USER_UNAVAILABLE_CODE || (code == 100 && USER_NOT_FOUND_SUBCODES.include?(subcode))
  end

  # 10 = sem permissão para a ação; 200–299 = família de erros de permissão.
  def permission_code?(code)
    code == 10 || (code.is_a?(Integer) && code.between?(200, 299))
  end

  def integer_or_nil(value)
    Integer(value.to_s, 10)
  rescue ArgumentError, TypeError
    nil
  end

  def safe_json(raw)
    JSON.parse(raw)
  rescue JSON::ParserError
    nil
  end
end
