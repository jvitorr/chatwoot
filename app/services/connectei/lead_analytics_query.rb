# Agregação de leads (contatos com atividade) para o painel do ERP Connectei
# — ver modifications/019. Só o ERP consome este serviço; validações de
# contrato público (formato de data, teto de 730 dias, etc.) são
# responsabilidade do ERP — aqui a defesa é só contra chamada malformada.
#
# "Lead" = contato distinto (`contacts.id`) com pelo menos uma mensagem
# humana (não nota interna, não evento de sistema) num inbox da conta dentro
# da janela pedida. "Novo" vs. "recorrente" é decidido pelo primeiro
# `conversations.created_at` do contato — GLOBAL, em todos os inboxes da
# conta, nunca só nos inboxes filtrados (um lead que veio pelo Instagram e
# voltou pelo WhatsApp é recorrente mesmo filtrando só WhatsApp).
class Connectei::LeadAnalyticsQuery
  GRANULARITIES = %w[day week month].freeze
  DEFAULT_GRANULARITY = 'month'.freeze

  def initialize(account:, params:)
    @account = account
    @params = params
  end

  def perform
    {
      summary: summary,
      by_channel: by_channel,
      time_series: time_series
    }
  end

  private

  attr_reader :account, :params

  # ------------------------------------------------------------------ dados

  # contact_id → primeiro `conversations.created_at`, GLOBAL (sem filtro de
  # inbox) — base da classificação novo/recorrente.
  def first_contact_at_by_contact
    return @first_contact_at_by_contact if defined?(@first_contact_at_by_contact)

    ids = active_contact_ids
    @first_contact_at_by_contact = if ids.empty?
                                     {}
                                   else
                                     Conversation.where(account_id: account.id, contact_id: ids).group(:contact_id).minimum(:created_at)
                                   end
  end

  def classify(contact_id)
    first_at = first_contact_at_by_contact[contact_id]
    return :returning if first_at.nil?

    first_at.between?(start_at, end_at) ? :new : :returning
  end

  def split_new_returning(contact_ids)
    new_count = contact_ids.count { |id| classify(id) == :new }
    { total: contact_ids.size, new: new_count, returning: contact_ids.size - new_count }
  end

  # Mensagens "de interação real": humano dos dois lados (incoming/outgoing),
  # nunca nota interna nem evento de sistema (mudança de status etc.) —
  # diferente do que ConversationsQuery (mod. 012) chama de "atividade", que
  # inclui status change. Aqui o sinal é "o lead interagiu", não "a conversa
  # mudou".
  def base_messages
    Message.where(
      account_id: account.id,
      inbox_id: effective_inbox_ids,
      private: false,
      message_type: %w[incoming outgoing]
    )
  end

  def messages_in_range
    @messages_in_range ||= base_messages.where(created_at: start_at..end_at)
  end

  def active_contact_ids
    @active_contact_ids ||=
      messages_in_range.reorder(nil).joins(:conversation).distinct.pluck('conversations.contact_id')
  end

  # ------------------------------------------------------------- resultado

  def summary
    split_new_returning(active_contact_ids).then do |s|
      {
        total_leads: s[:total],
        new_leads: s[:new],
        returning_leads: s[:returning]
      }
    end
  end

  def by_channel
    effective_inbox_ids.map do |inbox_id|
      ids = messages_in_range
            .where(inbox_id: inbox_id)
            .reorder(nil)
            .joins(:conversation)
            .distinct
            .pluck('conversations.contact_id')
      split = split_new_returning(ids)
      inbox = inbox_by_id[inbox_id]

      {
        channel_id: inbox_id,
        channel_name: inbox&.name,
        channel_type: inbox&.channel_type,
        total_leads: split[:total],
        new_leads: split[:new],
        returning_leads: split[:returning]
      }
    end
  end

  # Bucket de tempo: uma consulta por bucket, sobre `messages_in_range` (já
  # recortada pela janela pedida) — o número de buckets é limitado pelo teto
  # de intervalo que o ERP aplica (day ≤ 90, week/month ≤ 730 dias / ~24-104
  # buckets), então isto não é caminho quente.
  def time_series
    buckets.map do |bucket|
      ids = messages_in_range
            .where(created_at: bucket[:start]..bucket[:end])
            .reorder(nil)
            .joins(:conversation)
            .distinct
            .pluck('conversations.contact_id')
      split = split_new_returning(ids)

      {
        bucket_start: bucket[:start].iso8601(3),
        bucket_end: bucket[:end].iso8601(3),
        total_leads: split[:total],
        new_leads: split[:new],
        returning_leads: split[:returning]
      }
    end
  end

  # ---------------------------------------------------------------- buckets

  def buckets
    return [] if start_at.nil? || end_at.nil?

    cursor = timezone.at(start_at).public_send("beginning_of_#{granularity}")
    result = []

    while cursor.utc <= end_at
      result << {
        start: [cursor.utc, start_at].max,
        end: [bucket_end(cursor).utc, end_at].min
      }
      cursor = next_cursor(cursor)
    end

    result
  end

  def bucket_end(cursor)
    case granularity
    when 'day' then cursor.end_of_day
    when 'week' then cursor.end_of_week
    else cursor.end_of_month
    end
  end

  def next_cursor(cursor)
    case granularity
    when 'day' then cursor + 1.day
    when 'week' then cursor + 1.week
    else cursor.next_month
    end
  end

  # ------------------------------------------------------------------ params

  def inbox_ids
    @inbox_ids ||= integer_list(params[:inbox_ids])
  end

  # Vazio ⇒ todos os inboxes da conta (o ERP já filtrou pelos canais que a
  # loja tem vinculados antes de chegar aqui).
  def effective_inbox_ids
    @effective_inbox_ids ||= inbox_ids.presence || account.inboxes.pluck(:id)
  end

  def inbox_by_id
    @inbox_by_id ||= Inbox.where(id: effective_inbox_ids).index_by(&:id)
  end

  def start_at
    @start_at ||= parse_time(params[:start_at])
  end

  def end_at
    @end_at ||= parse_time(params[:end_at])
  end

  def granularity
    @granularity ||= GRANULARITIES.include?(params[:granularity].to_s) ? params[:granularity].to_s : DEFAULT_GRANULARITY
  end

  def timezone
    @timezone ||= ActiveSupport::TimeZone[params[:timezone].to_s] || ActiveSupport::TimeZone['UTC']
  end

  def parse_time(value)
    return nil if value.blank?

    Time.iso8601(value.to_s).utc
  rescue ArgumentError
    nil
  end

  def integer_list(value)
    Array(value).flat_map { |item| item.to_s.split(',') }.map(&:strip).reject(&:empty?).map(&:to_i).uniq
  end
end
