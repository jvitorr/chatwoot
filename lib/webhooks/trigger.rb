class Webhooks::Trigger
  SUPPORTED_ERROR_HANDLE_EVENTS = %w[message_created message_updated].freeze
  RETRYABLE_AGENT_BOT_STATUSES = [429, 500].freeze
  # [FORK CONNECTEI] modifications/006-webhook-inbox-api-timeout-retry.md
  RETRYABLE_API_INBOX_STATUSES = [429, 500, 502, 503, 504].freeze

  # [FORK CONNECTEI] modifications/006-webhook-inbox-api-timeout-retry.md
  # Falhas em que a requisição PODE ter sido recebida e processada pelo destino
  # (só a resposta não voltou). Marcar failed aqui produz falso negativo: no
  # inbox API a mensagem já pode ter sido entregue no WhatsApp pelo ERP.
  # EOFError está coberto por IOError (é subclasse).
  AMBIGUOUS_TRANSPORT_CAUSES = [Net::ReadTimeout, Errno::ECONNRESET, Errno::EPIPE, IOError].freeze
  AMBIGUOUS_MESSAGE_FRAGMENTS = [
    'Net::ReadTimeout',
    'Connection reset by peer',
    'Broken pipe',
    'end of file reached'
  ].freeze

  class RetryableError < StandardError
    attr_reader :status

    def initialize(status:, message:)
      @status = status
      super(message)
    end
  end

  def initialize(url, payload, webhook_type, secret: nil, delivery_id: nil)
    @url = url
    @payload = payload
    @webhook_type = webhook_type
    @secret = secret
    @delivery_id = delivery_id
  end

  def self.execute(url, payload, webhook_type, secret: nil, delivery_id: nil)
    new(url, payload, webhook_type, secret: secret, delivery_id: delivery_id).execute
  end

  def execute
    perform_request
  rescue StandardError => e
    # [FORK CONNECTEI] modifications/006: falhas transitorias do inbox API
    # tambem viram RetryableError (consumidas por ApiInbox::WebhookJob).
    raise RetryableError.new(status: http_status(e), message: e.message) if retryable_agent_bot_error?(e) || retryable_api_inbox_error?(e)

    handle_failure(e)
  end

  def handle_failure(error)
    handle_error(error)
    Rails.logger.warn "Exception: Invalid webhook URL #{@url} : #{error.message}"
  end

  private

  def perform_request
    body = @payload.to_json
    SafeFetch.fetch(
      @url,
      method: :post,
      body: body,
      headers: request_headers(body),
      open_timeout: webhook_timeout,
      read_timeout: webhook_timeout,
      validate_content_type: false
    ) { |_response| nil }
  end

  def request_headers(body)
    headers = { 'Content-Type' => 'application/json', 'Accept' => 'application/json' }
    headers['X-Chatwoot-Delivery'] = @delivery_id if @delivery_id.present?
    if @secret.present?
      ts = Time.now.to_i.to_s
      headers['X-Chatwoot-Timestamp'] = ts
      headers['X-Chatwoot-Signature'] = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', @secret, "#{ts}.#{body}")}"
    end
    headers
  end

  def handle_error(error)
    return unless SUPPORTED_ERROR_HANDLE_EVENTS.include?(@payload[:event])
    return unless message

    case @webhook_type
    when :agent_bot_webhook
      update_conversation_status(message)
    when :api_inbox_webhook
      update_message_status(error)
    end
  end

  def update_conversation_status(message)
    conversation = message.conversation
    return unless conversation&.pending?
    return if conversation&.account&.keep_pending_on_bot_failure

    conversation.open!
    create_agent_bot_error_activity(conversation)
  end

  def create_agent_bot_error_activity(conversation)
    content = I18n.t('conversations.activity.agent_bot.error_moved_to_open')
    Conversations::ActivityMessageJob.perform_later(conversation, activity_message_params(conversation, content))
  end

  def activity_message_params(conversation, content)
    {
      account_id: conversation.account_id,
      inbox_id: conversation.inbox_id,
      message_type: :activity,
      content: content
    }
  end

  def update_message_status(error)
    # [FORK CONNECTEI] modifications/006: timeout/reset de rede não é evidência
    # de falha de entrega; e source_id presente (WAID) é evidência de entrega.
    if ambiguous_delivery_error?(error) || message.source_id.present?
      record_delivery_unconfirmed(error)
    else
      Messages::StatusUpdateService.new(message, 'failed', error.message).perform
    end
  end

  def ambiguous_delivery_error?(error)
    exception_chain(error).any? do |current|
      AMBIGUOUS_TRANSPORT_CAUSES.any? { |klass| current.is_a?(klass) } ||
        AMBIGUOUS_MESSAGE_FRAGMENTS.any? { |fragment| current.message.to_s.include?(fragment) }
    end
  end

  def exception_chain(error)
    chain = []
    current = error
    while current && chain.length < 4
      chain << current
      current = current.cause
    end
    chain
  end

  def record_delivery_unconfirmed(error)
    attributes = message.content_attributes.merge(
      'delivery_unconfirmed' => true,
      'delivery_diagnostics' => {
        'error' => error.message,
        'event' => @payload[:event].to_s,
        'at' => Time.current.iso8601
      }
    )
    # update_columns de propósito: gravação puramente diagnóstica não deve
    # disparar MESSAGE_UPDATED (eco de webhook para o endpoint que acabou de
    # falhar) nem eventos de ActionCable.
    message.update_columns(content_attributes: attributes, updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    Rails.logger.warn "[Webhooks::Trigger] api_inbox delivery unconfirmed message_id=#{message.id} error=#{error.message}"
  end

  def message
    return if message_id.blank?

    if defined?(@message)
      @message
    else
      @message = Message.find_by(id: message_id)
    end
  end

  def message_id
    @payload[:id]
  end

  def webhook_timeout
    raw_timeout = GlobalConfig.get_value('WEBHOOK_TIMEOUT')
    timeout = raw_timeout.presence&.to_i

    timeout&.positive? ? timeout : 5
  end

  def retryable_agent_bot_error?(error)
    @webhook_type == :agent_bot_webhook && RETRYABLE_AGENT_BOT_STATUSES.include?(http_status(error))
  end

  # [FORK CONNECTEI] modifications/006: transporte (timeout/reset/refused) e
  # 429/5xx sao transitorios -> retry. 4xx e URL invalida/bloqueada falham na
  # hora (handle_failure aplica a classificacao ambiguo vs definitivo).
  def retryable_api_inbox_error?(error)
    @webhook_type == :api_inbox_webhook &&
      (transport_error?(error) || RETRYABLE_API_INBOX_STATUSES.include?(http_status(error)))
  end

  def transport_error?(error)
    return true if error.is_a?(SafeFetch::FetchError) || error.is_a?(Errno::ECONNREFUSED)

    AMBIGUOUS_TRANSPORT_CAUSES.any? { |klass| error.is_a?(klass) }
  end

  def http_status(error)
    return unless error.is_a?(SafeFetch::HttpError)

    error.message.to_s[/\A(\d{3})\b/, 1]&.to_i
  end
end
