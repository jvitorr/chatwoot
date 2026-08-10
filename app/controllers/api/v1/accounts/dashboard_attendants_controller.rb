# Painel de atendimento do ERP Connectei — ver modifications/011.
#
# Substitui, numa única chamada, o que o ERP fazia varrendo a API: paginar
# `/conversations/filter` até 8 páginas para montar o quadro e disparar duas
# chamadas de contagem POR atendente. Aqui o agrupamento acontece no banco
# (`GROUP BY assignee_id` + `COUNT(*) FILTER`), e a fatia de conversas por
# atendente sai de uma window function — nada é cortado em memória.
#
# Custo: 3 queries fixas, independente do número de atendentes ou de conversas.
class Api::V1::Accounts::DashboardAttendantsController < Api::V1::Accounts::BaseController
  DEFAULT_CONVERSATIONS_PER_AGENT = 20
  MAX_CONVERSATIONS_PER_AGENT = 50

  before_action :validate_inbox_ids!

  def index
    render json: {
      meta: meta_payload,
      totals: totals_payload,
      agents: agents_payload,
      unassigned: unassigned_payload
    }
  end

  private

  # Escopo base. Multi-loja: uma conta do provedor pode atender várias lojas do
  # ERP, e o grão real de isolamento é o inbox — por isso `inbox_ids` é o
  # parâmetro que a loja passa. Sem ele, a conta inteira.
  def conversations
    @conversations ||= begin
      scope = Current.account.conversations
      scope = scope.where(inbox_id: requested_inbox_ids) if requested_inbox_ids.present?
      scope = scope.where(assignee_id: visible_assignee_ids) unless administrator?
      scope
    end
  end

  # Agente comum enxerga o próprio quadro e a fila sem dono (é o que ele pode
  # puxar); administrador enxerga a operação inteira. Nunca 401 — o painel de
  # um agente simplesmente vem menor.
  def administrator?
    Current.account_user&.administrator? || false
  end

  def visible_assignee_ids
    [Current.user&.id, nil]
  end

  # Uma query para todas as contagens: GROUP BY assignee_id com COUNT FILTER
  # por status (mesmo padrão já usado em ConversationFinder). O índice
  # (account_id, inbox_id, status, assignee_id) cobre exatamente este acesso.
  def counts_by_assignee
    @counts_by_assignee ||= conversations
                            .unscope(:order)
                            .group(:assignee_id)
                            .pluck(
                              Arel.sql('assignee_id'),
                              Arel.sql("COUNT(*) FILTER (WHERE status = #{Conversation.statuses[:open]})"),
                              Arel.sql("COUNT(*) FILTER (WHERE status = #{Conversation.statuses[:pending]})"),
                              Arel.sql("COUNT(*) FILTER (WHERE status = #{Conversation.statuses[:resolved]})"),
                              Arel.sql(
                                "COUNT(*) FILTER (WHERE status = #{Conversation.statuses[:open]} " \
                                'AND (first_reply_created_at IS NULL OR waiting_since IS NOT NULL))'
                              )
                            )
                            .to_h { |row| [row[0], { open: row[1], pending: row[2], resolved: row[3], unattended: row[4] }] }
  end

  # A fatia de conversas por atendente sai do banco já limitada: ROW_NUMBER
  # particionado por assignee. Sem isto, seria preciso trazer todas as abertas
  # e cortar em memória — exatamente o que este endpoint existe para evitar.
  def open_conversations_by_assignee
    @open_conversations_by_assignee ||= begin
      ranked = conversations.open.unscope(:order).select(
        Arel.sql('conversations.*'),
        Arel.sql('ROW_NUMBER() OVER (PARTITION BY conversations.assignee_id ORDER BY conversations.last_activity_at DESC) AS connectei_rank')
      )

      Conversation
        .select('*')
        .from(ranked, :conversations)
        .where('connectei_rank <= ?', conversations_per_agent)
        .includes(:contact)
        .order(Arel.sql('last_activity_at DESC'))
        .group_by(&:assignee_id)
    end
  end

  def agents_payload
    agent_ids = counts_by_assignee.keys.compact
    return [] if agent_ids.blank?

    users_by_id = Current.account.users.where(id: agent_ids).includes(:account_users).index_by(&:id)

    agent_ids.filter_map do |agent_id|
      user = users_by_id[agent_id]
      next if user.blank?

      {
        id: user.id,
        name: user.name,
        available_name: user.available_name,
        email: user.email,
        thumbnail: user.avatar_url,
        counts: counts_by_assignee[agent_id],
        conversations: serialize_conversations(open_conversations_by_assignee[agent_id])
      }
    end
  end

  def unassigned_payload
    counts = counts_by_assignee[nil] || { open: 0, pending: 0, resolved: 0, unattended: 0 }
    { counts: counts, conversations: serialize_conversations(open_conversations_by_assignee[nil]) }
  end

  def totals_payload
    counts_by_assignee.values.each_with_object({ open: 0, pending: 0, resolved: 0, unattended: 0 }) do |counts, totals|
      totals.each_key { |key| totals[key] += counts[key].to_i }
    end
  end

  def serialize_conversations(records)
    Array(records).map do |conversation|
      {
        id: conversation.display_id,
        inbox_id: conversation.inbox_id,
        status: conversation.status,
        last_activity_at: conversation.last_activity_at,
        created_at: conversation.created_at,
        waiting_since: conversation.waiting_since,
        # `cached_label_list` evita um JOIN com taggings só para exibir etiqueta.
        labels: conversation.cached_label_list.to_s.split(',').map(&:strip).reject(&:empty?),
        contact: contact_payload(conversation.contact)
      }
    end
  end

  def contact_payload(contact)
    return nil if contact.blank?

    { id: contact.id, name: contact.name, phone_number: contact.phone_number, email: contact.email }
  end

  def meta_payload
    {
      account_id: Current.account.id,
      inbox_ids: requested_inbox_ids,
      conversations_per_agent: conversations_per_agent,
      scope: administrator? ? 'account' : 'self',
      generated_at: Time.current
    }
  end

  def requested_inbox_ids
    @requested_inbox_ids ||= Array(params[:inbox_ids]).map { |id| id.to_s.strip }.reject(&:empty?).map(&:to_i).uniq
  end

  # Inbox de outra conta nunca deve virar resultado vazio silencioso: quem pediu
  # um canal que não é seu recebe erro explícito.
  def validate_inbox_ids!
    return if requested_inbox_ids.blank?

    unknown = requested_inbox_ids - Current.account.inboxes.where(id: requested_inbox_ids).pluck(:id)
    return if unknown.blank?

    render json: { error: "inbox_ids not found in this account: #{unknown.join(',')}" }, status: :unprocessable_entity
  end

  def conversations_per_agent
    @conversations_per_agent ||= begin
      requested = params[:conversations_per_agent].presence&.to_i || DEFAULT_CONVERSATIONS_PER_AGENT
      requested.clamp(1, MAX_CONVERSATIONS_PER_AGENT)
    end
  end
end
