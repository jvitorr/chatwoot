# Fragmentos SQL da listagem do painel Connectei — ver modifications/012.
#
# Ficam separados da montagem da query porque é aqui que mora a razão de o
# endpoint existir: cada fragmento substitui um pós-processamento que o cliente
# fazia em memória sobre uma página de 25 itens.
module Connectei::ConversationSql
  # `incoming` e `outgoing` — atividade/sistema não vira preview nem não-lida.
  CONTENT_MESSAGE_TYPES = [0, 1].freeze
  INCOMING_MESSAGE_TYPE = 0

  module_function

  def label_exists
    <<~SQL.squish
      SELECT 1 FROM taggings
      INNER JOIN tags ON tags.id = taggings.tag_id
      WHERE taggings.taggable_id = conversations.id
        AND taggings.taggable_type = 'Conversation'
        AND tags.name = ?
    SQL
  end

  # Busca por IDENTIDADE DO CONTATO — os mesmos quatro campos que o
  # `contacts_controller` do core usa, para o resultado bater com a busca de
  # contatos do próprio Chatwoot. `identifier` é onde mora o handle da rede
  # social (o JID no WhatsApp, o id da conta no Instagram/Facebook).
  #
  # Conteúdo de mensagem NÃO entra aqui, e a razão é concreta: mensagem de
  # grupo chega com o nome de quem enviou em negrito no começo do texto, então
  # procurar uma pessoa trazia todo grupo em que ela um dia falou — além de
  # qualquer conversa onde alguém mencionou o nome dela. Buscar "Amanda"
  # devolvia 12 conversas, das quais só 2 eram da Amanda.
  #
  # Se um dia a busca em conteúdo voltar, precisa ser um parâmetro próprio
  # (ex.: `q_content`), nunca misturada com a busca por pessoa.
  def search_condition
    <<~SQL.squish
      contacts.name ILIKE :term
      OR contacts.email ILIKE :term
      OR contacts.phone_number ILIKE :term
      OR contacts.identifier ILIKE :term
    SQL
  end

  # LATERAL traz a última mensagem de cada conversa na mesma passada — o
  # índice (conversation_id, account_id, message_type, created_at) já cobre.
  def last_message_join
    ActiveRecord::Base.sanitize_sql_array(
      [
        <<~SQL.squish,
          LEFT JOIN LATERAL (
            SELECT content, message_type, created_at
            FROM messages
            WHERE messages.conversation_id = conversations.id
              AND messages.private = false
              AND messages.message_type IN (?)
            ORDER BY messages.created_at DESC
            LIMIT 1
          ) connectei_last_message ON TRUE
        SQL
        CONTENT_MESSAGE_TYPES
      ]
    )
  end

  def unread_count_select
    ActiveRecord::Base.sanitize_sql_array(
      [
        <<~SQL.squish,
          (
            SELECT COUNT(*) FROM messages
            WHERE messages.conversation_id = conversations.id
              AND messages.message_type = ?
              AND messages.private = false
              AND messages.created_at > COALESCE(conversations.agent_last_seen_at, to_timestamp(0))
          ) AS connectei_unread_count
        SQL
        INCOMING_MESSAGE_TYPE
      ]
    )
  end

  # Fixadas primeiro é ordenação, não recorte — assim sobrevive à paginação.
  def pinned_first(display_ids)
    ActiveRecord::Base.sanitize_sql_array(
      ['CASE WHEN conversations.display_id IN (?) THEN 0 ELSE 1 END', display_ids]
    )
  end
end
