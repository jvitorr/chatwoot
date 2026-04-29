class Voice::CallService
  pattr_initialize [:call!, :agent!, :sdp_answer]

  # WhatsApp accept: forward the browser-built SDP answer to Meta. Twilio
  # voice does not flow through this service.
  def accept
    raise ArgumentError, "Unsupported provider: #{call.provider}" unless call.whatsapp?
    raise Voice::CallErrors::CallFailed, 'sdp_answer is required' if sdp_answer.blank?

    call.with_lock { transition_to_in_progress! }
    Voice::CallMessageBuilder.update_status!(call: call, status: 'in_progress', agent: agent)
    update_conversation_call_status('in-progress')
    broadcast(:accepted, accepted_by_agent_id: agent.id)
    call
  end

  def reject
    call.reload
    return call if call.terminal? || call.in_progress?

    invoke_provider(:reject_call)
    finalize_call('failed')
    call
  end

  def terminate
    return call if call.terminal?

    invoke_provider(:terminate_call)
    finalize_call('completed')
    call
  end

  private

  def transition_to_in_progress!
    raise Voice::CallErrors::NotRinging, 'Call is not in ringing state' unless call.ringing?
    raise Voice::CallErrors::AlreadyAccepted, 'Call already accepted by another agent' if call.in_progress?

    forward_answer_to_meta!
    call.update!(status: 'in_progress', accepted_by_agent_id: agent.id, started_at: Time.current,
                 meta: (call.meta || {}).merge('sdp_answer' => sdp_answer))
    claim_conversation_for_agent
  end

  def forward_answer_to_meta!
    svc = call.inbox.channel.provider_service
    raise Voice::CallErrors::CallFailed, 'Meta pre_accept failed' unless svc.pre_accept_call(call.provider_call_id, sdp_answer)
    raise Voice::CallErrors::CallFailed, 'Meta accept failed' unless svc.accept_call(call.provider_call_id, sdp_answer)
  end

  # Auto-assignment on accept: take ownership of the conversation if it has
  # no assignee. If someone else already holds it, leave it (transfer via UI).
  def claim_conversation_for_agent
    call.conversation.update!(assignee: agent) if call.conversation.assignee_id.blank?
  end

  def invoke_provider(method)
    return unless call.whatsapp?

    success = call.inbox.channel.provider_service.public_send(method, call.provider_call_id)
    Rails.logger.error "[VOICE CALL] #{method} returned false for #{call.provider_call_id}" unless success
  rescue StandardError => e
    Rails.logger.error "[VOICE CALL] #{method} failed: #{e.message}"
  end

  def finalize_call(status)
    call.update!(status: status)
    Voice::CallMessageBuilder.update_status!(call: call, status: status)
    update_conversation_call_status(status)
    broadcast(:ended, status: status)
  end

  def update_conversation_call_status(mapped_status)
    conversation = call.conversation
    conversation.update!(
      additional_attributes: (conversation.additional_attributes || {}).merge('call_status' => mapped_status)
    )
  end

  def broadcast(event, extra = {})
    payload = {
      event: "voice_call.#{event}",
      data: { id: call.id, call_id: call.provider_call_id, provider: call.provider,
              conversation_id: call.conversation_id, account_id: call.account_id }.merge(extra)
    }
    ActionCable.server.broadcast("account_#{call.account_id}", payload)
  end
end
