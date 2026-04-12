class Whatsapp::CallService
  pattr_initialize [:call!, :agent!]

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

    provider = call.inbox.channel.provider_service
    success = provider.terminate_call(call.provider_call_id)
    Rails.logger.error "[WHATSAPP CALL] terminate_call API returned false for call #{call.provider_call_id}" unless success

    call.update!(status: 'completed')
    Whatsapp::CallMessageBuilder.update_status!(call: call, status: 'completed')
    update_conversation_call_status('completed')
    broadcast_call_ended
    call
  end

  private

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
