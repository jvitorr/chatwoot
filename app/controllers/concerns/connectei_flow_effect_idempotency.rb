# [FORK CONNECTEI] modifications/027b-eco-e-idempotencia.md
#
# `POST /api/v1/accounts/:account_id/conversations/:conversation_id/messages`
# idempotente pela marca do ERP: se a conversa já tem uma mensagem com o mesmo
# `content_attributes.flow_effect_key`, a resposta é 200 com ELA — nada é criado e
# nada é enviado de novo ao canal. Vale para todo canal (contrato fork↔ERP §3).
#
# POR QUÊ
# O ERP reenvia um efeito quando não sabe se o primeiro POST pegou (timeout de
# rede, worker reiniciado no meio). Sem isto, cada reenvio virava uma mensagem
# nova — e, no Instagram, um envio novo à Meta (no private reply, um erro de
# "já respondido" que derrubava o efeito certo).
#
# CONCORRÊNCIA
# Duas requisições com a mesma chave ao mesmo tempo: um advisory lock transacional
# em (conversa, chave) serializa as duas; a segunda espera o COMMIT da primeira e
# encontra a mensagem dela. Sem `flow_effect_key` nada muda: nem lock, nem consulta.
#
# A chave vale por conversa (é como o ERP a gera). Mensagem existente em estado
# `failed` também volta como está: para tentar de novo, o ERP usa uma chave nova.
module ConnecteiFlowEffectIdempotency
  extend ActiveSupport::Concern

  # Caracteres que o JSON nunca escapa: a chave aparece literal no texto gravado.
  LITERAL_JSON_KEY = %r{\A[0-9A-Za-z_:./@#=+-]+\z}

  included do
    # `if:` em vez de `only:` — o filtro mora no concern, e a ação, no controller.
    around_action :connectei_idempotent_message_create, if: -> { action_name == 'create' }
  end

  private

  def connectei_idempotent_message_create
    key = connectei_flow_effect_key
    return yield if key.blank?

    ActiveRecord::Base.transaction do
      connectei_lock_flow_effect!(key)
      existing = connectei_message_with_flow_effect_key(key)
      next yield if existing.nil?

      Rails.logger.info("[CONNECTEI][flow-effect] POST repetido conversation_id=#{@conversation.id} key=#{key}: devolvendo message_id=#{existing.id}")
      @message = existing
      render :create, status: :ok
    end
  end

  # `content_attributes` é `json` com `store … coder: JSON`: o banco guarda uma
  # STRING JSON contendo o objeto, então `->> 'flow_effect_key'` não enxerga a
  # chave. O pré-filtro é textual (barato: só as mensagens desta conversa) e a
  # igualdade exata é conferida no objeto já decodificado. Chave com caractere que
  # o JSON escapa (aspas, barra invertida, `<>&`, controle) não aparece literal no
  # texto gravado: aí o filtro textual é pulado e a conversa é varrida inteira.
  def connectei_message_with_flow_effect_key(key)
    scope = @conversation.messages.unscope(:order)
    scope = scope.where('messages.content_attributes::text LIKE ?', "%#{ActiveRecord::Base.sanitize_sql_like(key)}%") if key.match?(LITERAL_JSON_KEY)
    scope.find_each.find { |candidate| candidate.content_attributes['flow_effect_key'].to_s == key }
  end

  def connectei_lock_flow_effect!(key)
    lock_key = Digest::SHA256.digest("connectei:flow-effect:#{@conversation.id}:#{key}")[0, 8].unpack1('q>')
    ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql_array(['SELECT pg_advisory_xact_lock(?)', lock_key]))
  end

  # O ERP manda `content_attributes` como objeto JSON, como campos de formulário
  # (`content_attributes[flow_effect_key]`) ou como uma string JSON no multipart —
  # os mesmos formatos que o `Messages::MessageBuilder` aceita.
  def connectei_flow_effect_key
    raw = params[:content_attributes]
    attributes = case raw
                 when ActionController::Parameters then raw.to_unsafe_h
                 when String then connectei_parse_json(raw)
                 else raw
                 end
    attributes.is_a?(Hash) ? attributes.with_indifferent_access[:flow_effect_key].presence&.to_s : nil
  end

  def connectei_parse_json(raw)
    JSON.parse(raw)
  rescue JSON::ParserError
    nil
  end
end
