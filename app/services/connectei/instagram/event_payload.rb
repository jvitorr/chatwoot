# [FORK CONNECTEI] modifications/024-repasse-de-eventos-instagram-ao-erp.md
#
# Monta o corpo que o fork repassa ao ERP (contrato fork↔ERP §1.2). Funções puras:
# recebem o canal e o pedaço do webhook da Meta e devolvem o Hash a enviar.
#
# `event_id` é estável e único — é a chave de deduplicação dos dois lados
# (a Meta reentrega por até 36h e o retry do fork também repete):
#   comentário: `ig:c:<comment_id>`
#   referral:   `ig:r:<sender_id>:<timestamp>`
module Connectei::Instagram::EventPayload
  VERSION = 1
  COMMENT_EVENT = 'instagram.comment'.freeze
  REFERRAL_EVENT = 'instagram.referral'.freeze
  REFERRAL_KEYS = %w[ref source type ad_id ads_context_data].freeze

  # Abaixo disto o número é segundos; acima, milissegundos. 1e11 s cai no ano
  # 5138 e 1e11 ms em 1973, então o corte separa os dois sem ambiguidade.
  SECONDS_MILLISECONDS_THRESHOLD = 100_000_000_000

  module_function

  def comment(channel:, entry:, value:, comment_id:)
    envelope(channel, entry, COMMENT_EVENT, "ig:c:#{comment_id}").merge(
      data: {
        comment_id: comment_id,
        text: value[:text],
        from: { id: value.dig(:from, :id)&.to_s, username: value.dig(:from, :username) },
        media: { id: value.dig(:media, :id)&.to_s, media_product_type: value.dig(:media, :media_product_type) },
        parent_id: value[:parent_id].presence&.to_s,
        created_time: unix_seconds(value[:created_time])
      }
    )
  end

  def referral(channel:, entry:, messaging:, timestamp:)
    sender_id = messaging.dig(:sender, :id).to_s
    attributes = referral_attributes(messaging[:referral])

    envelope(channel, entry, REFERRAL_EVENT, "ig:r:#{sender_id}:#{timestamp}").merge(
      data: { sender_id: sender_id }.merge(attributes.symbolize_keys).merge(timestamp: timestamp)
    )
  end

  # `{ ref, source, type, ad_id, ads_context_data }` com as cinco chaves sempre
  # presentes (nil quando a Meta não manda). Também usado na entrada (mod 025).
  def referral_attributes(raw)
    source = raw.is_a?(Hash) ? raw.with_indifferent_access : {}
    REFERRAL_KEYS.index_with { |key| source[key].presence }.tap do |attributes|
      attributes['ad_id'] = attributes['ad_id']&.to_s
    end
  end

  # Milissegundos Unix, aceitando segundos, milissegundos ou ISO 8601
  # (o `time` da entrada vem em ms nos eventos de mensagem e em s nos de `changes`).
  def unix_milliseconds(raw)
    seconds_or_ms = numeric_time(raw)
    return if seconds_or_ms.nil?

    seconds_or_ms < SECONDS_MILLISECONDS_THRESHOLD ? seconds_or_ms * 1000 : seconds_or_ms
  end

  def unix_seconds(raw)
    milliseconds = unix_milliseconds(raw)
    milliseconds && (milliseconds / 1000)
  end

  def envelope(channel, entry, event, event_id)
    {
      version: VERSION,
      event: event,
      event_id: event_id,
      account_id: channel.account_id,
      inbox_id: channel.inbox.id,
      instagram_id: channel.instagram_id.to_s,
      entry_time: unix_milliseconds(entry[:time]),
      received_at: Time.current.utc.iso8601
    }
  end

  def numeric_time(raw)
    return raw.to_i if raw.is_a?(Numeric)
    return if raw.blank?
    return raw.to_i if raw.to_s.match?(/\A\d+\z/)

    (Time.iso8601(raw.to_s).to_f * 1000).to_i
  rescue ArgumentError
    nil
  end
end
