class Api::V1::Accounts::VoiceCallsController < Api::V1::Accounts::BaseController
  before_action :set_call, only: %i[show accept reject terminate upload_recording]

  def show
    render json: call_payload(@call)
  end

  def accept
    call = Voice::CallService.new(
      call: @call,
      agent: current_user,
      sdp_answer: params[:sdp_answer]
    ).accept
    render json: call_payload(call)
  rescue Voice::CallErrors::NotRinging, Voice::CallErrors::AlreadyAccepted, Voice::CallErrors::CallFailed => e
    render json: { error: e.message }, status: :unprocessable_entity
  rescue StandardError => e
    Rails.logger.error "[VOICE CALL] accept failed: #{e.class} #{e.message}"
    render json: { error: 'Failed to accept call' }, status: :internal_server_error
  end

  def reject
    call = Voice::CallService.new(call: @call, agent: current_user).reject
    render json: { id: call.id, status: call.status }
  rescue StandardError => e
    Rails.logger.error "[VOICE CALL] reject failed: #{e.class} #{e.message}"
    render json: { error: 'Failed to reject call' }, status: :internal_server_error
  end

  def terminate
    call = Voice::CallService.new(call: @call, agent: current_user).terminate
    render json: { id: call.id, status: call.status }
  rescue StandardError => e
    Rails.logger.error "[VOICE CALL] terminate failed: #{e.class} #{e.message}"
    render json: { error: 'Failed to terminate call' }, status: :internal_server_error
  end

  # Browser-supplied recording, captured via MediaRecorder during the call.
  # Idempotent: subsequent uploads after the first audio attachment exists
  # silently no-op so the hangup-vs-pagehide race can't double-attach.
  def upload_recording
    return render json: { error: 'No recording file provided' }, status: :unprocessable_entity if params[:recording].blank?
    return render json: { id: @call.id, status: 'no_message' }, status: :unprocessable_entity if @call.message.blank?
    return render json: { id: @call.id, status: 'already_uploaded' } if @call.message.attachments.exists?(file_type: :audio)

    attach_recording!
    render json: { id: @call.id, status: 'uploaded' }
  rescue StandardError => e
    Rails.logger.error "[VOICE CALL] upload_recording failed: #{e.class} #{e.message}"
    render json: { error: 'Failed to upload recording' }, status: :internal_server_error
  end

  def active
    call = current_account.calls.active_for_agent(current_user.id).last
    if call
      elapsed = call.started_at ? (Time.current - call.started_at).to_i : 0
      render json: {
        id: call.id,
        call_id: call.provider_call_id,
        provider: call.provider,
        conversation_id: call.conversation_id,
        status: call.status,
        elapsed_seconds: elapsed
      }
    else
      render json: { call: nil }
    end
  end

  def initiate
    conversation = current_account.conversations.find_by!(display_id: params[:conversation_id])
    authorize conversation, :show?

    initiate_whatsapp(conversation)
  rescue Voice::CallErrors::NoCallPermission
    handle_no_call_permission(conversation)
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Conversation not found' }, status: :not_found
  rescue StandardError => e
    Rails.logger.error "[VOICE CALL] initiate failed: #{e.class} #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def initiate_whatsapp(conversation)
    error = validate_whatsapp_calling(conversation)
    return render json: { error: error }, status: :unprocessable_entity if error
    return render json: { error: 'sdp_offer is required' }, status: :unprocessable_entity if params[:sdp_offer].blank?

    contact_phone = conversation.contact&.phone_number
    raise ArgumentError, 'Contact phone number not available' if contact_phone.blank?

    call = create_whatsapp_outbound_call(conversation, contact_phone, params[:sdp_offer])
    message = Voice::CallMessageBuilder.create!(conversation: conversation, call: call, user: current_user)
    call.update!(message_id: message.id)
    render json: { status: 'calling', call_id: call.provider_call_id, id: call.id, message_id: message.id, provider: 'whatsapp' }
  end

  # Browser → Rails → Meta. The browser already opened its mic, built an
  # RTCPeerConnection, generated the offer, and waited for ICE gathering.
  # We just hand that offer to Meta. Meta returns the call_id immediately
  # (no SDP yet); the contact's phone rings; on pickup the connect webhook
  # delivers Meta's SDP answer and we relay it back via ActionCable.
  def create_whatsapp_outbound_call(conversation, contact_phone, sdp_offer)
    result = conversation.inbox.channel.provider_service.initiate_call(contact_phone.delete('+'), sdp_offer)
    provider_call_id = result.dig('calls', 0, 'id') || result['call_id']

    current_account.calls.create!(
      provider: :whatsapp,
      inbox: conversation.inbox,
      conversation: conversation,
      contact: conversation.contact,
      provider_call_id: provider_call_id,
      direction: :outgoing,
      status: 'ringing',
      accepted_by_agent_id: current_user.id,
      meta: { 'sdp_offer' => sdp_offer, 'ice_servers' => Call.default_ice_servers }
    )
  end

  def validate_whatsapp_calling(conversation)
    channel = conversation.inbox.channel
    return 'Calling is only supported on WhatsApp Cloud inboxes' unless channel.is_a?(Channel::Whatsapp) && channel.provider == 'whatsapp_cloud'
    return 'Calling is not enabled for this inbox' unless channel.provider_config['calling_enabled']

    nil
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

  def call_payload(call)
    {
      id: call.id,
      call_id: call.provider_call_id,
      provider: call.provider,
      status: call.status,
      direction: call.direction_label,
      conversation_id: call.conversation_id,
      inbox_id: call.inbox_id,
      message_id: call.message_id,
      accepted_by_agent_id: call.accepted_by_agent_id,
      elapsed_seconds: call.started_at ? (Time.current - call.started_at).to_i : 0,
      sdp_offer: call.meta&.dig('sdp_offer'),
      ice_servers: call.meta&.dig('ice_servers') || Call.default_ice_servers,
      caller: caller_info(call)
    }
  end

  def caller_info(call)
    contact = call.conversation&.contact
    return {} unless contact

    { name: contact.name, phone: contact.phone_number, avatar: contact.avatar_url }
  end

  def set_call
    @call = current_account.calls.find(params[:id])
    authorize @call.conversation, :show?
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Call not found' }, status: :not_found
  end

  def attach_recording!
    @call.message.attachments.create!(
      account_id: @call.account_id,
      file_type: :audio,
      file: params[:recording]
    )
  end
end
