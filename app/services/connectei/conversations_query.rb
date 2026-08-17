# Listagem de conversas do painel do ERP Connectei — ver modifications/012.
#
# Existe porque o `/conversations/filter` oficial não resolve, no banco, quatro
# coisas de que o painel precisa — e o cliente acabava fazendo cada uma em
# memória, sobre uma página de 25 itens (ou seja: errado assim que a operação
# cresce):
#
#   1. ordenação — o filter oficial é fixo em `last_activity_at DESC`;
#   2. busca — a filter API não aceita `content`/`name`/`phone_number` (422) e
#      não faz JOIN com contatos nem mensagens;
#   3. conversas fixadas no topo — conceito do ERP, não do provedor;
#   4. total do rodapé — o filter oficial dispara 3 COUNTs e ainda assim conta
#      linhas que o cliente esconde depois (ex.: grupos).
#
# Tudo aqui vira uma consulta só: filtros no WHERE, ordenação no ORDER BY,
# última mensagem por LATERAL e não-lidas por subconsulta correlacionada.
class Connectei::ConversationsQuery
  DEFAULT_PER_PAGE = 25
  MAX_PER_PAGE = 100
  MAX_DISPLAY_IDS = 100
  MAX_PINNED_IDS = 50

  SORT_COLUMNS = {
    'last_activity_at_desc' => 'conversations.last_activity_at DESC',
    'last_activity_at_asc' => 'conversations.last_activity_at ASC',
    'created_at_desc' => 'conversations.created_at DESC',
    'created_at_asc' => 'conversations.created_at ASC'
  }.freeze

  def initialize(account:, params:, user: nil, administrator: true)
    @account = account
    @params = params
    @user = user
    @administrator = administrator
  end

  def perform
    { conversations: paginated_relation, count: filtered_relation.count, page: page, per_page: per_page }
  end

  private

  attr_reader :account, :params, :user

  def administrator?
    @administrator
  end

  # ------------------------------------------------------------------ filtros

  def filtered_relation
    @filtered_relation ||= begin
      scope = account.conversations
      scope = scope.where(inbox_id: inbox_ids) if inbox_ids.present?
      scope = apply_visibility(scope)
      scope = apply_status(scope)
      scope = apply_assignee(scope)
      scope = apply_display_ids(scope)
      scope = apply_labels(scope)
      scope = apply_excluded_labels(scope)
      scope = apply_created_range(scope)
      scope = apply_activity_range(scope)
      apply_search(scope)
    end
  end

  # Agente sem permissão de ver tudo enxerga o próprio quadro e a fila sem dono
  # — mesma regra do painel, aplicada no banco e não na resposta.
  def apply_visibility(scope)
    return scope if administrator? || user.blank?

    scope.where(assignee_id: [user.id, nil])
  end

  def apply_status(scope)
    status = params[:status].to_s
    return scope if status.blank? || status == 'all'
    return scope unless Conversation.statuses.key?(status)

    scope.where(status: Conversation.statuses[status])
  end

  def apply_assignee(scope)
    return scope.where(assignee_id: nil) if ActiveModel::Type::Boolean.new.cast(params[:unassigned])
    return scope if assignee_ids.blank?

    scope.where(assignee_id: assignee_ids)
  end

  def apply_display_ids(scope)
    return scope if display_ids.blank?

    scope.where(display_id: display_ids)
  end

  # Semântica E: a conversa precisa ter TODAS as etiquetas pedidas.
  def apply_labels(scope)
    labels.reduce(scope) { |relation, label| relation.where("EXISTS (#{Connectei::ConversationSql.label_exists})", label) }
  end

  def apply_excluded_labels(scope)
    excluded_labels.reduce(scope) { |relation, label| relation.where("NOT EXISTS (#{Connectei::ConversationSql.label_exists})", label) }
  end

  # "Intervalo de criação do chat" — quando o lead entrou em contato pela
  # primeira vez, distinto de `apply_activity_range` (última interação).
  def apply_created_range(scope)
    scope = scope.where(created_at: created_from..) if created_from
    scope = scope.where(created_at: ..created_to) if created_to
    scope
  end

  # "Intervalo de interação do chat" — qualquer atividade (mensagem, mudança
  # de status) dentro da janela, não só a abertura da conversa.
  def apply_activity_range(scope)
    scope = scope.where(last_activity_at: activity_from..) if activity_from
    scope = scope.where(last_activity_at: ..activity_to) if activity_to
    scope
  end

  def apply_search(scope)
    return scope if search_term.blank?

    # A busca é por identidade do contato — nome, e-mail, telefone, identifier.
    # Conteúdo de mensagem não participa (ver ConversationSql#search_condition).
    scope.joins(:contact).where(
      Connectei::ConversationSql.search_condition,
      term: "%#{search_term}%"
    )
  end

  # --------------------------------------------------------------- resultado

  # Uma consulta entrega tudo o que o item da lista precisa: conversa, contato,
  # última mensagem (LATERAL) e não-lidas (subconsulta). Sem N+1.
  def paginated_relation
    filtered_relation
      .joins(:contact)
      .joins(Connectei::ConversationSql.last_message_join)
      .select(select_columns)
      .order(Arel.sql(order_clause))
      .page(page)
      .per(per_page)
  end

  def select_columns
    [
      Arel.sql('conversations.*'),
      Arel.sql('contacts.id AS connectei_contact_id'),
      Arel.sql('contacts.name AS connectei_contact_name'),
      Arel.sql('contacts.phone_number AS connectei_contact_phone'),
      Arel.sql('contacts.email AS connectei_contact_email'),
      Arel.sql('connectei_last_message.content AS connectei_last_message_content'),
      Arel.sql('connectei_last_message.message_type AS connectei_last_message_type'),
      Arel.sql('connectei_last_message.created_at AS connectei_last_message_created_at'),
      Arel.sql(Connectei::ConversationSql.unread_count_select)
    ]
  end

  def order_clause
    sort = SORT_COLUMNS[params[:sort_by].to_s] || SORT_COLUMNS['last_activity_at_desc']
    return sort if pinned_display_ids.blank?

    "#{Connectei::ConversationSql.pinned_first(pinned_display_ids)}, #{sort}"
  end

  # ------------------------------------------------------------------ params

  def inbox_ids
    @inbox_ids ||= integer_list(params[:inbox_ids])
  end

  def assignee_ids
    @assignee_ids ||= integer_list(params[:assignee_ids])
  end

  def display_ids
    @display_ids ||= integer_list(params[:display_ids]).first(MAX_DISPLAY_IDS)
  end

  def pinned_display_ids
    @pinned_display_ids ||= integer_list(params[:pinned_display_ids]).first(MAX_PINNED_IDS)
  end

  def labels
    @labels ||= string_list(params[:labels])
  end

  def excluded_labels
    @excluded_labels ||= string_list(params[:exclude_labels])
  end

  def search_term
    @search_term ||= params[:q].to_s.strip
  end

  # O controller já rejeitou (422) qualquer valor que não seja `YYYY-MM-DD`
  # válido — aqui só resolve o boundary do dia (`from` = início, `to` = fim),
  # já que o front manda data pura, sem hora.
  def created_from
    @created_from ||= parse_day_boundary(params[:created_from])&.beginning_of_day
  end

  def created_to
    @created_to ||= parse_day_boundary(params[:created_to])&.end_of_day
  end

  def activity_from
    @activity_from ||= parse_day_boundary(params[:last_activity_from])&.beginning_of_day
  end

  def activity_to
    @activity_to ||= parse_day_boundary(params[:last_activity_to])&.end_of_day
  end

  def parse_day_boundary(value)
    return nil if value.blank?

    Date.iso8601(value).in_time_zone
  end

  def page
    @page ||= [params[:page].to_i, 1].max
  end

  def per_page
    @per_page ||= (params[:per_page].presence&.to_i || DEFAULT_PER_PAGE).clamp(1, MAX_PER_PAGE)
  end

  def integer_list(value)
    Array(value).flat_map { |item| item.to_s.split(',') }.map(&:strip).reject(&:empty?).map(&:to_i).uniq
  end

  def string_list(value)
    Array(value).flat_map { |item| item.to_s.split(',') }.map(&:strip).reject(&:empty?).uniq
  end
end
