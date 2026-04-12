class Api::V1::Accounts::WhatsappCallsController < Api::V1::Accounts::BaseController
  before_action :ensure_whatsapp_call_enabled
  before_action :set_call, only: [:show, :accept, :reject, :terminate, :upload_recording]

  def show
    render json: {
      id: @call.id,
      call_id: @call.provider_call_id,
      status: @call.status,
      direction: @call.direction_label,
      conversation_id: @call.conversation_id,
      inbox_id: @call.inbox_id,
      message_id: @call.message_id,
      sdp_offer: @call.ringing? ? @call.sdp_offer : nil,
      ice_servers: @call.ice_servers,
      caller: caller_info
    }
  end

  def accept
    sdp_answer = params[:sdp_answer]
    return render json: { error: 'sdp_answer is required' }, status: :unprocessable_entity if sdp_answer.blank?

    call = Whatsapp::CallService.new(call: @call, agent: current_user).pre_accept_and_accept(sdp_answer)
    render json: { id: call.id, status: call.status, message_id: call.message_id }
  rescue Whatsapp::CallErrors::NotRinging, Whatsapp::CallErrors::AlreadyAccepted => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] accept failed: #{e.message}"
    render json: { error: 'Failed to accept call' }, status: :internal_server_error
  end

  def reject
    call = Whatsapp::CallService.new(call: @call, agent: current_user).reject
    render json: { id: call.id, status: call.status }
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] reject failed: #{e.message}"
    render json: { error: 'Failed to reject call' }, status: :internal_server_error
  end

  def terminate
    call = Whatsapp::CallService.new(call: @call, agent: current_user).terminate
    render json: { id: call.id, status: call.status }
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] terminate failed: #{e.message}"
    render json: { error: 'Failed to terminate call' }, status: :internal_server_error
  end

  def upload_recording
    return render json: { error: 'No recording file provided' }, status: :unprocessable_entity if params[:recording].blank?
    return render json: { error: 'Call is not ended' }, status: :unprocessable_entity unless @call.terminal?

    attach_recording_and_enqueue_transcription
    render json: { id: @call.id, status: 'uploaded' }
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] upload_recording failed: #{e.message}"
    render json: { error: 'Failed to upload recording' }, status: :internal_server_error
  end

  def initiate
    conversation = current_account.conversations.find(params[:conversation_id])
    authorize conversation, :show?
    error = validate_whatsapp_calling(conversation)
    return render json: { error: error }, status: :unprocessable_entity if error

    call = create_outbound_call(conversation)
    message = Whatsapp::CallMessageBuilder.create!(conversation: conversation, call: call, user: current_user)
    call.update!(message_id: message.id)
    render json: { status: 'calling', call_id: call.provider_call_id, id: call.id, message_id: message.id }
  rescue Whatsapp::CallErrors::NoCallPermission
    handle_no_call_permission(conversation)
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Conversation not found' }, status: :not_found
  rescue StandardError => e
    Rails.logger.error "[WHATSAPP CALL] initiate failed: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def create_outbound_call(conversation)
    contact_phone = conversation.contact&.phone_number
    raise ArgumentError, 'Contact phone number not available' if contact_phone.blank?
    raise ArgumentError, 'sdp_offer is required' if params[:sdp_offer].blank?

    result = conversation.inbox.channel.provider_service.initiate_call(contact_phone.delete('+'), params[:sdp_offer])
    provider_call_id = result.dig('calls', 0, 'id') || result['call_id']

    current_account.calls.create!(
      provider: :whatsapp,
      inbox: conversation.inbox, conversation: conversation,
      provider_call_id: provider_call_id, direction: :outgoing, status: 'ringing',
      meta: { sdp_offer: params[:sdp_offer] }
    )
  end

  def handle_no_call_permission(conversation)
    last_requested = conversation.additional_attributes&.dig('call_permission_requested_at')

    return render json: { status: 'permission_pending' } if last_requested.present? && Time.zone.parse(last_requested) > 5.minutes.ago

    contact_phone = conversation.contact.phone_number.delete('+')
    result = conversation.inbox.channel.provider_service.send_call_permission_request(contact_phone)
    return render json: { error: 'Failed to send call permission request' }, status: :unprocessable_entity unless result

    attrs = (conversation.additional_attributes || {}).merge('call_permission_requested_at' => Time.current.iso8601)
    conversation.update!(additional_attributes: attrs)
    render json: { status: 'permission_requested' }
  end

  def validate_whatsapp_calling(conversation)
    channel = conversation.inbox.channel
    return 'Calling is only supported on WhatsApp Cloud inboxes' unless channel.is_a?(Channel::Whatsapp) && channel.provider == 'whatsapp_cloud'
    return 'Calling is not enabled for this inbox' unless channel.provider_config['calling_enabled']

    nil
  end

  def ensure_whatsapp_call_enabled
    render_payment_required('WhatsApp calling is not enabled for this account') unless current_account.feature_enabled?('whatsapp_call')
  end

  def set_call
    @call = current_account.calls.whatsapp.find(params[:id])
    authorize @call.conversation, :show?
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Call not found' }, status: :not_found
  end

  def attach_recording_and_enqueue_transcription
    @call.recording.attach(params[:recording])
    Whatsapp::CallMessageBuilder.update_recording_url!(call: @call)
    Whatsapp::CallTranscriptionJob.perform_later(@call.id)
  end

  def caller_info
    contact = @call.conversation&.contact
    return {} unless contact

    { name: contact.name, phone: contact.phone_number, avatar: contact.avatar_url }
  end
end
