# [FORK CONNECTEI] modifications/026-endpoints-connectei-instagram.md
#
# Ice breakers (iniciadores de conversa) do Instagram: validação da entrada e
# conversão entre o formato do contrato fork↔ERP §2.6 (`[{question, payload}]`) e o
# da Graph (`[{call_to_actions: [...], locale}]`).
module Connectei::Instagram::IceBreakers
  MAX_ITEMS = 4
  LIMITS = { question: 80, payload: 1000 }.freeze
  LOCALE = 'default'.freeze

  module_function

  # Devolve a lista normalizada ou levanta `GraphClient::Error` (`invalid`, 422).
  def validate!(raw)
    invalid!('ice_breakers deve ser uma lista') unless raw.is_a?(Array)
    invalid!("ice_breakers deve ter de 1 a #{MAX_ITEMS} itens") unless raw.size.between?(1, MAX_ITEMS)

    raw.each_with_index.map { |item, index| validate_item!(item, index) }
  end

  def validate_item!(item, index)
    item = item.respond_to?(:to_unsafe_h) ? item.to_unsafe_h : item
    invalid!("ice_breakers[#{index}] deve ser um objeto") unless item.is_a?(Hash)

    item = item.with_indifferent_access
    LIMITS.to_h do |field, max|
      value = item[field].to_s.strip
      invalid!("ice_breakers[#{index}].#{field} deve ter de 1 a #{max} caracteres") unless value.length.between?(1, max)

      [field, value]
    end
  end

  def to_graph(items)
    [{ call_to_actions: items, locale: LOCALE }]
  end

  # `GET /me/messenger_profile?fields=ice_breakers` → `[{question, payload}]`,
  # preferindo o locale `default`.
  def from_graph(body)
    entries = hashes(body.is_a?(Hash) ? body['data'] : nil).flat_map { |profile| hashes(profile['ice_breakers']) }
    chosen = entries.find { |entry| entry['locale'] == LOCALE } || entries.first || {}
    hashes(chosen['call_to_actions']).map { |action| { question: action['question'], payload: action['payload'] } }
  end

  def hashes(value)
    Array(value).select { |entry| entry.is_a?(Hash) }
  end

  def invalid!(message)
    raise Connectei::Instagram::GraphClient::Error.invalid(message)
  end
end
