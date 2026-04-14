class Voice::Provider::Twilio::ConferenceService
  pattr_initialize [:call!, { twilio_client: nil }]

  def ensure_conference_sid
    existing = call.meta['conference_sid']
    return existing if existing.present?

    sid = Voice::Conference::Name.for(call)
    call.update!(meta: call.meta.merge('conference_sid' => sid))
    merge_conversation_attributes('conference_sid' => sid)
    sid
  end

  def mark_agent_joined(user:)
    call.update!(accepted_by_agent_id: user.id)
    merge_conversation_attributes(
      'agent_joined' => true,
      'joined_at' => Time.current.to_i,
      'joined_by' => { id: user.id, name: user.name }
    )
  end

  def end_conference
    twilio_client
      .conferences
      .list(friendly_name: Voice::Conference::Name.for(call), status: 'in-progress')
      .each { |conf| twilio_client.conferences(conf.sid).update(status: 'completed') }
  end

  private

  delegate :conversation, to: :call

  def merge_conversation_attributes(attrs)
    current = conversation.additional_attributes || {}
    conversation.update!(additional_attributes: current.merge(attrs))
  end

  def twilio_client
    @twilio_client ||= begin
      channel = conversation.inbox.channel
      if channel.api_key_sid.present? && channel.try(:api_key_secret).present?
        ::Twilio::REST::Client.new(channel.api_key_sid, channel.api_key_secret, channel.account_sid)
      else
        ::Twilio::REST::Client.new(channel.account_sid, channel.auth_token)
      end
    end
  end
end
