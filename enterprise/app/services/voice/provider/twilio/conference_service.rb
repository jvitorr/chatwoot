class Voice::Provider::Twilio::ConferenceService
  pattr_initialize [:call!]

  def ensure_conference_sid
    return call.conference_sid if call.conference_sid.present?

    call.update!(conference_sid: call.default_conference_sid)
    call.conference_sid
  end

  # Surface the 409 collision to a second agent who clicks accept, but DON'T
  # claim accepted_by_agent here — the actual claim happens when Twilio's
  # participant-join webhook fires for this agent's leg (Voice::Conference::Manager).
  # If we claimed up-front and the browser's joinClientCall failed (device init
  # error, tab close, network drop), the call would stay ringing-but-claimed
  # and every other agent would 409 with no recovery path.
  def mark_agent_joined(user:)
    raise_already_accepted!(call.accepted_by_agent) if claimed_by_other_agent?(user)
    assign_conversation!(user)
  end

  def end_conference
    return if call.conference_sid.blank?

    client = call.inbox.channel.client
    client
      .conferences
      .list(friendly_name: call.conference_sid, status: 'in-progress')
      .each { |conf| client.conferences(conf.sid).update(status: 'completed') }
  end

  private

  def claimed_by_other_agent?(user)
    call.accepted_by_agent_id.present? && call.accepted_by_agent_id != user.id
  end

  def raise_already_accepted!(agent)
    raise CustomExceptions::CallAlreadyAccepted.new(agent_name: agent&.available_name || agent&.name)
  end

  # Existing assignments win — manual reassignment and pre-call assignment
  # (e.g., lock_to_single_conversation) shouldn't be stomped on pickup.
  def assign_conversation!(user)
    conversation = call.conversation
    return if conversation.assignee_id.present?

    Conversations::AssignmentService.new(conversation: conversation, assignee_id: user.id).perform
  end
end
