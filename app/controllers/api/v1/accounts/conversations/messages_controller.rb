class Api::V1::Accounts::Conversations::MessagesController < Api::V1::Accounts::Conversations::BaseController
  before_action :ensure_api_inbox, only: :update

  def index
    @messages = message_finder.perform
  end

  def create
    user = Current.user || @resource
    mb = Messages::MessageBuilder.new(user, @conversation, params)
    @message = mb.perform
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  # [FORK CONNECTEI] modifications/007-source-id-no-update-de-mensagem.md
  # Aceita source_id (WAID) alem de status/external_error, para o ERP confirmar
  # a entrega apos o envio ao provider. Restrito a inbox API (ensure_api_inbox).
  def update
    return if source_id_conflict?

    apply_source_id
    if permitted_params[:status].present?
      Messages::StatusUpdateService.new(message, permitted_params[:status], permitted_params[:external_error]).perform
    end
    @message = message.reload
  end

  def destroy
    ActiveRecord::Base.transaction do
      message.update!(content: I18n.t('conversations.messages.deleted'), content_type: :text, content_attributes: { deleted: true })
      message.attachments.destroy_all
    end
  end

  def retry
    return if message.blank?

    service = Messages::StatusUpdateService.new(message, 'sent')
    service.perform
    message.update!(content_attributes: {})
    ::SendReplyJob.perform_later(message.id)
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  def translate
    return head :ok if already_translated_content_available?

    translated_content = Integrations::GoogleTranslate::ProcessorService.new(
      message: message,
      target_language: permitted_params[:target_language]
    ).perform

    if translated_content.present?
      translations = {}
      translations[permitted_params[:target_language]] = translated_content
      translations = message.translations.merge!(translations) if message.translations.present?
      message.update!(translations: translations)
    end

    render json: { content: translated_content }
  end

  private

  def message
    @message ||= @conversation.messages.find(permitted_params[:id])
  end

  def message_finder
    @message_finder ||= MessageFinder.new(@conversation, params)
  end

  def permitted_params
    # [FORK CONNECTEI] modifications/007: + :source_id
    params.permit(:id, :target_language, :status, :external_error, :source_id)
  end

  # [FORK CONNECTEI] modifications/007: source_id divergente do existente e um
  # bug do integrador — falhar alto em vez de sobrescrever evidencia de entrega.
  def source_id_conflict?
    new_source_id = permitted_params[:source_id]
    return false if new_source_id.blank?
    return false if message.source_id.blank? || message.source_id == new_source_id

    render json: { error: 'source_id already set with a different value' }, status: :unprocessable_entity
    true
  end

  def apply_source_id
    new_source_id = permitted_params[:source_id]
    return if new_source_id.blank? || message.source_id == new_source_id

    # WAID recebido = entrega confirmada: limpa o diagnostico de entrega
    # nao confirmada gravado pelo Webhooks::Trigger (modifications/006).
    message.update!(
      source_id: new_source_id,
      content_attributes: message.content_attributes.except('delivery_unconfirmed', 'delivery_diagnostics')
    )
  end

  def already_translated_content_available?
    message.translations.present? && message.translations[permitted_params[:target_language]].present?
  end

  # API inbox check
  def ensure_api_inbox
    # Only API inboxes can update messages
    render json: { error: 'Message status update is only allowed for API inboxes' }, status: :forbidden unless @conversation.inbox.api?
  end
end
