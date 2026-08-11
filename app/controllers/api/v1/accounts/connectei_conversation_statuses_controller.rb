# Atualização de status de conversas em LOTE — ver modifications/017.
#
# Existe por causa da migração do ERP para o modo direto. Até ela, "aberta" e
# "fechada" viviam SÓ no ERP: fechar uma conversa lá nunca chegou aqui. Ao
# virar o modo, o painel passa a ler o status daqui — então tudo que o ERP
# fechou precisa ser aplicado antes, ou a loja reabre a caixa de entrada
# inteira no primeiro dia.
#
# Uma loja com anos de histórico tem milhares dessas. Uma chamada por conversa
# em `/toggle_status` são milhares de idas e voltas HTTP; aqui é uma só.
#
# O que este endpoint NÃO faz: pular o ActiveRecord. Cada conversa é salva pelo
# modelo, como no `toggle_status` oficial, para os invariantes do próprio
# Chatwoot continuarem de pé — `resolved_at`, mensagem de atividade, eventos de
# relatório. O ganho é o número de requisições, não atalho no domínio.
class Api::V1::Accounts::ConnecteiConversationStatusesController < Api::V1::Accounts::BaseController
  # Teto por requisição. Existe para o lote não segurar um worker por minutos
  # nem estourar o timeout do proxy no meio, deixando metade aplicada sem
  # ninguém saber quanto. Estourar é ERRO explícito, nunca corte silencioso: o
  # chamador fatia e sabe exatamente o que mandou.
  MAX_BATCH = 500

  VALID_STATUSES = Conversation.statuses.keys.freeze

  def create
    entries = Array(params[:conversations])

    return render_error('conversations is required and must not be empty') if entries.blank?
    return render_error("batch too large: #{entries.size} > #{MAX_BATCH}") if entries.size > MAX_BATCH

    render json: apply(entries)
  end

  private

  def apply(entries)
    result = { updated: 0, unchanged: 0, failed: [] }
    found = fetch_conversations(entries)

    entries.each { |entry| apply_entry(entry, found, result) }

    result
  end

  # Escopo da conta numa consulta só — um `find_by!` por item faria N SELECTs e
  # desfaria metade do ganho. Conversa de OUTRA conta simplesmente não aparece
  # aqui: o limite de inquilino é o mesmo do resto da API, não uma checagem
  # nova que eu possa errar.
  def fetch_conversations(entries)
    ids = entries.filter_map { |entry| entry[:id].presence && entry[:id].to_i }
    Current.account.conversations.where(display_id: ids).index_by(&:display_id)
  end

  def apply_entry(entry, found, result)
    display_id = entry[:id].to_i
    status = entry[:status].to_s

    return fail_entry(result, display_id, "invalid status: #{entry[:status]}") unless VALID_STATUSES.include?(status)

    conversation = found[display_id]
    return fail_entry(result, display_id, 'not found in this account') if conversation.nil?

    # Já está no alvo: não salva. Reescrever geraria mensagem de atividade e
    # evento de relatório a cada nova execução, e a migração é feita para poder
    # rodar de novo sem sujar o histórico da conversa.
    return result[:unchanged] += 1 if conversation.status == status

    save_status(conversation, status, display_id, result)
  end

  def save_status(conversation, status, display_id, result)
    conversation.status = status
    conversation.save!
    result[:updated] += 1
  rescue StandardError => e
    # Uma conversa que o modelo recusa não derruba as outras: o chamador recebe
    # a lista do que faltou e repete só isso.
    Rails.logger.warn("[Connectei] bulk status failed for #{display_id}: #{e.class} - #{e.message}")
    fail_entry(result, display_id, e.message)
  end

  def fail_entry(result, display_id, message)
    result[:failed] << { id: display_id, error: message }
  end

  def render_error(message)
    render json: { error: message }, status: :unprocessable_entity
  end
end
