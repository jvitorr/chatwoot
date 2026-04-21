class Whatsapp::CallService
  pattr_initialize [:call!, :agent!]

  def accept(params = {})
    if media_server_enabled?
      accept_via_media_server
    else
      pre_accept_and_accept(params[:sdp_answer])
    end
  end

  def pre_accept_and_accept(sdp_answer)
    call.with_lock do
      ensure_ringing!
      ensure_not_already_taken!

      provider = call.inbox.channel.provider_service
      fixed_sdp = fix_sdp_setup(sdp_answer)

      # Step 1: pre_accept (with SDP answer - required by Meta)
      pre_response = provider.pre_accept_call(call.provider_call_id, fixed_sdp)
      raise Whatsapp::CallErrors::NotRinging, 'Meta pre_accept failed' unless pre_response

      # Step 2: accept with same SDP answer
      accept_response = provider.accept_call(call.provider_call_id, fixed_sdp)
      raise Whatsapp::CallErrors::NotRinging, 'Meta accept failed' unless accept_response

      call.update!(
        status: 'in_progress',
        accepted_by_agent_id: agent.id,
        started_at: Time.current
      )
    end

    Whatsapp::CallMessageBuilder.update_status!(call: call, status: 'in_progress', agent: agent)
    update_conversation_call_status('in-progress')
    broadcast_accepted
    call
  end

  def reject
    call.reload
    return call if call.terminal? || call.in_progress?

    provider = call.inbox.channel.provider_service
    success = provider.reject_call(call.provider_call_id)
    Rails.logger.error "[WHATSAPP CALL] reject_call API returned false for call #{call.provider_call_id}" unless success

    call.update!(status: 'failed')
    Whatsapp::CallMessageBuilder.update_status!(call: call, status: 'failed')
    update_conversation_call_status('failed')
    broadcast_call_ended
    call
  end

  def terminate
    return call if call.terminal?

    terminate_media_session if call.media_session_id.present?
    terminate_on_provider

    call.update!(status: 'completed')
    Whatsapp::CallMessageBuilder.update_status!(call: call, status: 'completed')
    update_conversation_call_status('completed')
    broadcast_call_ended
    call
  end

  def terminate_on_provider
    provider = call.inbox.channel.provider_service
    success = provider.terminate_call(call.provider_call_id)
    Rails.logger.error "[WHATSAPP CALL] terminate_call API returned false for call #{call.provider_call_id}" unless success
  end

  private

  def accept_via_media_server
    agent_offer = nil

    call.with_lock do
      ensure_ringing!
      ensure_not_already_taken!

      client = Whatsapp::MediaServerClient.new

      # Step 1: Create session on Go server with Meta's SDP
      session_response = client.create_session(
        call_id: call.provider_call_id,
        sdp_offer: call.sdp_offer,
        ice_servers: call.ice_servers,
        account_id: call.account_id
      )

      # Step 2: Send Go-generated SDP answer to Meta
      provider = call.inbox.channel.provider_service
      pre_response = provider.pre_accept_call(call.provider_call_id, session_response['meta_sdp_answer'])
      raise Whatsapp::CallErrors::NotRinging, 'Meta pre_accept failed' unless pre_response

      accept_response = provider.accept_call(call.provider_call_id, session_response['meta_sdp_answer'])
      raise Whatsapp::CallErrors::NotRinging, 'Meta accept failed' unless accept_response

      # Step 3: Generate agent offer (Peer B)
      agent_offer = client.generate_agent_offer(session_response['session_id'])

      # Step 4: Update call record
      call.update!(
        status: 'in_progress',
        accepted_by_agent_id: agent.id,
        started_at: Time.current,
        media_session_id: session_response['session_id']
      )
    end

    # Step 5: Broadcast events (outside lock)
    Whatsapp::CallMessageBuilder.update_status!(call: call, status: 'in_progress', agent: agent)
    update_conversation_call_status('in-progress')
    broadcast_agent_offer(agent_offer)
    broadcast_accepted
    call
  end

  def media_server_enabled?
    Call.media_server_enabled?
  end

  def terminate_media_session
    Whatsapp::MediaServerClient.new.terminate_session(call.media_session_id)
  rescue Whatsapp::MediaServerClient::ConnectionError, Whatsapp::MediaServerClient::SessionError => e
    Rails.logger.error "[WHATSAPP CALL] Failed to terminate media session: #{e.message}"
  end

  def ensure_ringing!
    raise Whatsapp::CallErrors::NotRinging, 'Call is not in ringing state' unless call.ringing?
  end

  def ensure_not_already_taken!
    raise Whatsapp::CallErrors::AlreadyAccepted, 'Call already accepted by another agent' if call.in_progress?
  end

  def fix_sdp_setup(sdp)
    sdp.gsub('a=setup:actpass', 'a=setup:active')
  end

  def update_conversation_call_status(mapped_status)
    conversation = call.conversation
    attrs = (conversation.additional_attributes || {}).merge('call_status' => mapped_status)
    conversation.update!(additional_attributes: attrs)
  end

  def broadcast_accepted
    payload = {
      event: 'whatsapp_call.accepted',
      data: {
        account_id: call.account_id,
        id: call.id,
        call_id: call.provider_call_id,
        accepted_by_agent_id: agent.id,
        conversation_id: call.conversation_id
      }
    }
    ActionCable.server.broadcast("account_#{call.account_id}", payload)
  end

  def broadcast_agent_offer(agent_offer)
    payload = {
      event: 'whatsapp_call.agent_offer',
      data: {
        account_id: call.account_id,
        id: call.id,
        call_id: call.provider_call_id,
        conversation_id: call.conversation_id,
        accepted_by_agent_id: agent.id,
        sdp_offer: agent_offer['sdp_offer'],
        ice_servers: agent_offer['ice_servers']
      }
    }
    ActionCable.server.broadcast("account_#{call.account_id}", payload)
  end

  def broadcast_call_ended
    payload = {
      event: 'whatsapp_call.ended',
      data: {
        account_id: call.account_id,
        id: call.id,
        call_id: call.provider_call_id,
        status: call.status,
        conversation_id: call.conversation_id
      }
    }
    ActionCable.server.broadcast("account_#{call.account_id}", payload)
  end
end
