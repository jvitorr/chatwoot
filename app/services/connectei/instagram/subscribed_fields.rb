# [FORK CONNECTEI] modifications/024-repasse-de-eventos-instagram-ao-erp.md
#
# Campos do webhook que o canal Instagram assina (`POST /{ig_id}/subscribed_apps`)
# e a normalização dos escopos concedidos que o ERP informa (mod 003).
#
# `comments` só entra quando o canal tem `instagram_business_manage_comments` em
# `connectei_granted_scopes`. Pedir o campo sem o escopo concedido faz a Meta
# recusar a inscrição INTEIRA — e aí nem os DMs chegam. Como o escopo depende do
# App Review (Advanced Access), cada conta ganha o campo só quando reconecta com
# a permissão nova.
module Connectei::Instagram::SubscribedFields
  BASE_FIELDS = %w[messages message_reactions messaging_seen messaging_postbacks messaging_referral].freeze
  COMMENTS_FIELD = 'comments'.freeze
  COMMENTS_SCOPE = 'instagram_business_manage_comments'.freeze

  MAX_SCOPES = 50
  MAX_SCOPE_LENGTH = 100
  SCOPE_FORMAT = /\A[a-z0-9_.]+\z/i

  module_function

  def fields_for(channel)
    scopes = Array(channel.try(:connectei_granted_scopes))
    scopes.include?(COMMENTS_SCOPE) ? BASE_FIELDS + [COMMENTS_FIELD] : BASE_FIELDS.dup
  end

  # Aceita lista (`["a", "b"]`) ou texto separado por vírgula/espaço (`"a,b"`, o
  # formato do campo `permissions` que a Meta devolve no OAuth). Descarta o que
  # não parece nome de escopo em vez de falhar: escopo desconhecido não muda nada
  # aqui, e recusar o cadastro inteiro por isso deixaria a loja sem canal.
  def normalize_scopes(raw)
    values = raw.is_a?(String) ? raw.split(/[\s,]+/) : Array(raw)
    values.filter_map { |value| value.to_s.strip.presence }
          .select { |value| value.length <= MAX_SCOPE_LENGTH && value.match?(SCOPE_FORMAT) }
          .uniq
          .first(MAX_SCOPES)
  end
end
