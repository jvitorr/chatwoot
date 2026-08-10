# Listagem de conversas do painel do ERP Connectei — ver modifications/012.
#
# Aditivo: não altera `/conversations/filter`, que segue servindo o dashboard
# do próprio Chatwoot. Aqui o contrato é o que o painel do ERP precisa, com
# tudo resolvido no banco (ver Connectei::ConversationsQuery).
class Api::V1::Accounts::ConnecteiConversationsController < Api::V1::Accounts::BaseController
  before_action :validate_inbox_ids!

  def filter
    result = Connectei::ConversationsQuery.new(
      account: Current.account,
      params: permitted_params,
      user: Current.user,
      administrator: administrator?
    ).perform

    render json: {
      meta: meta_for(result),
      payload: result[:conversations].map { |conversation| serialize(conversation) }
    }
  end

  private

  def administrator?
    Current.account_user&.administrator? || false
  end

  def meta_for(result)
    {
      all_count: result[:count],
      page: result[:page],
      per_page: result[:per_page],
      total_pages: (result[:count].to_f / result[:per_page]).ceil,
      scope: administrator? ? 'account' : 'self'
    }
  end

  def serialize(conversation)
    attributes = conversation.attributes

    {
      id: conversation.display_id,
      inbox_id: conversation.inbox_id,
      status: conversation.status,
      assignee_id: conversation.assignee_id,
      created_at: conversation.created_at,
      last_activity_at: conversation.last_activity_at,
      waiting_since: conversation.waiting_since,
      agent_last_seen_at: conversation.agent_last_seen_at,
      unread_count: attributes['connectei_unread_count'].to_i,
      labels: conversation.cached_label_list.to_s.split(',').map(&:strip).reject(&:empty?),
      contact: contact_for(attributes),
      last_message: last_message_for(attributes)
    }
  end

  def contact_for(attributes)
    {
      id: attributes['connectei_contact_id'],
      name: attributes['connectei_contact_name'],
      phone_number: attributes['connectei_contact_phone'],
      email: attributes['connectei_contact_email']
    }
  end

  def last_message_for(attributes)
    return nil if attributes['connectei_last_message_created_at'].blank?

    {
      content: attributes['connectei_last_message_content'],
      message_type: attributes['connectei_last_message_type'],
      created_at: attributes['connectei_last_message_created_at']
    }
  end

  # Canal de outra conta é erro explícito, nunca lista vazia silenciosa.
  def validate_inbox_ids!
    requested = Array(params[:inbox_ids]).flat_map { |id| id.to_s.split(',') }.map(&:strip).reject(&:empty?).map(&:to_i).uniq
    return if requested.blank?

    unknown = requested - Current.account.inboxes.where(id: requested).pluck(:id)
    return if unknown.blank?

    render json: { error: "inbox_ids not found in this account: #{unknown.join(',')}" }, status: :unprocessable_entity
  end

  def permitted_params
    params.permit(
      :status, :unassigned, :q, :sort_by, :page, :per_page,
      inbox_ids: [], assignee_ids: [], display_ids: [], pinned_display_ids: [], labels: [], exclude_labels: []
    )
  end
end
